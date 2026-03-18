#!/bin/bash
#===============================================================================
#  qualys_image_fetcher.sh
#  Qualys Container Security — Image Fetcher  v1.0.0
#
#  Copyright (c) 2026 Qualys, Inc. All rights reserved.
#  Author: Aman
#
#  Pulls every container image record from a Qualys CSAPI gateway with
#  automatic pagination, full rate-limit handling, resume/idempotency,
#  data-integrity verification, and structured reporting.
#
#  See README.md or run with -h / --help for full documentation.
#===============================================================================

set -euo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

# ─── Configurable defaults (all overridable via flags or env vars) ────────────
LIMIT="${QUALYS_LIMIT:-50}"                             # 1–250
DAYS="${QUALYS_DAYS:-30}"                               # images in use last N days
FILTER="${QUALYS_FILTER:-}"                             # raw filter (overrides -d)
ENDPOINT="${QUALYS_ENDPOINT:-/csapi/v1.3/images/snow}"
RETRY_COUNT="${QUALYS_RETRIES:-5}"
RETRY_DELAY_BASE="${QUALYS_RETRY_DELAY:-3}"             # exponential back-off base
RETRY_DELAY_MAX="${QUALYS_RETRY_DELAY_MAX:-120}"        # back-off ceiling
OUTPUT_DIR="${QUALYS_OUTPUT_DIR:-./qualys_output}"
OUTPUT_FORMAT="${QUALYS_OUTPUT_FORMAT:-json}"            # json | jsonl
VERBOSE="${QUALYS_VERBOSE:-false}"
FORCE=false
TOKEN="${QUALYS_ACCESS_TOKEN:-}"
GATEWAY="${QUALYS_GATEWAY:-}"
CONNECT_TIMEOUT="${QUALYS_CONNECT_TIMEOUT:-30}"
REQUEST_TIMEOUT="${QUALYS_REQUEST_TIMEOUT:-300}"
RATE_LIMIT_FLOOR="${QUALYS_RL_FLOOR:-10}"
RATE_LIMIT_PAUSE="${QUALYS_RL_PAUSE:-3}"
RATE_LIMIT_WINDOW_BUFFER="${QUALYS_RL_BUFFER:-5}"
CURL_EXTRA_ARGS="${QUALYS_CURL_EXTRA:-}"                # e.g. "--proxy http://..."
QUIET=false
DRY_RUN=false

# ─── Colours (disabled when stdout is not a tty or --no-color is set) ─────────
NO_COLOR=false
init_colors() {
    if [ -t 1 ] && ! $NO_COLOR; then
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
    else
        RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
    fi
}

# ─── Runtime state ────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE=""
PAGES_DIR=""
STATE_FILE=""
LOCK_FILE=""
TOTAL_API_CALLS=0
TOTAL_RETRIES=0
RL_REMAINING=""; RL_LIMIT_HDR=""; RL_WINDOW=""

# ─── Handle long options before getopts ───────────────────────────────────────
# getopts only supports short options, so we pre-process long options here
# and convert them into short flags or set variables directly.
ARGS=()
SKIP_NEXT=false
ALL_ARGS=("$@")
for i in "${!ALL_ARGS[@]}"; do
    if $SKIP_NEXT; then SKIP_NEXT=false; continue; fi
    arg="${ALL_ARGS[$i]}"
    next="${ALL_ARGS[$((i+1))]:-}"
    case "$arg" in
        --help)        ARGS+=("-h") ;;
        --force)       FORCE=true ;;
        --verbose)     VERBOSE=true ;;
        --quiet)       QUIET=true ;;
        --dry-run)     DRY_RUN=true ;;
        --no-color)    NO_COLOR=true ;;
        --jsonl)       OUTPUT_FORMAT="jsonl" ;;
        --rl-floor=*)  RATE_LIMIT_FLOOR="${arg#*=}" ;;
        --rl-floor)    RATE_LIMIT_FLOOR="$next"; SKIP_NEXT=true ;;
        --rl-pause=*)  RATE_LIMIT_PAUSE="${arg#*=}" ;;
        --rl-pause)    RATE_LIMIT_PAUSE="$next"; SKIP_NEXT=true ;;
        --rl-buffer=*) RATE_LIMIT_WINDOW_BUFFER="${arg#*=}" ;;
        --rl-buffer)   RATE_LIMIT_WINDOW_BUFFER="$next"; SKIP_NEXT=true ;;
        *)             ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

init_colors

# ─── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    echo -e ""
    echo -e "${BOLD}Qualys Container Security — Image Fetcher v${VERSION}${NC}"
    echo -e "${DIM}Copyright (c) 2026 Qualys, Inc. All rights reserved.${NC}"
    echo -e ""
    echo -e "${BOLD}USAGE${NC}"
    echo -e "  ${SCRIPT_NAME} -g <gateway_url>                          ${DIM}# token from \$QUALYS_ACCESS_TOKEN${NC}"
    echo -e "  ${SCRIPT_NAME} -t <token> -g <gateway_url> [options]"
    echo -e ""
    echo -e "${BOLD}REQUIRED${NC}"
    echo -e "  -g GATEWAY           Gateway base URL"
    echo -e ""
    echo -e "${BOLD}AUTHENTICATION${NC}"
    echo -e "  -t TOKEN             Bearer token                      ${DIM}(default: \$QUALYS_ACCESS_TOKEN)${NC}"
    echo -e ""
    echo -e "${BOLD}QUERY OPTIONS${NC}"
    echo -e "  -l LIMIT             Results per page, 1–250           ${DIM}(default: 50)${NC}"
    echo -e "  -d DAYS              Images in use in the last N days  ${DIM}(default: 30)${NC}"
    echo -e "  -f FILTER            Raw URL-encoded filter            ${DIM}(overrides -d)${NC}"
    echo -e "  -e ENDPOINT          API endpoint path                 ${DIM}(default: /csapi/v1.3/images/snow)${NC}"
    echo -e ""
    echo -e "${BOLD}OUTPUT OPTIONS${NC}"
    echo -e "  -o OUTPUT_DIR        Output directory                  ${DIM}(default: ./qualys_output)${NC}"
    echo -e "  --jsonl              Output as JSON Lines (.jsonl)     ${DIM}(default: json)${NC}"
    echo -e ""
    echo -e "${BOLD}RELIABILITY OPTIONS${NC}"
    echo -e "  -r RETRIES           Max retries per page              ${DIM}(default: 5)${NC}"
    echo -e "  -T SECONDS           Curl connect timeout              ${DIM}(default: 30)${NC}"
    echo -e "  -M SECONDS           Curl max request time             ${DIM}(default: 300)${NC}"
    echo -e "  -C CURL_ARGS         Extra curl arguments              ${DIM}(e.g. \"--proxy http://...\")${NC}"
    echo -e ""
    echo -e "${BOLD}RATE LIMITING OPTIONS${NC}"
    echo -e "  --rl-floor N         Start throttling below N calls    ${DIM}(default: 10)${NC}"
    echo -e "  --rl-pause N         Seconds to pause when throttling  ${DIM}(default: 3)${NC}"
    echo -e "  --rl-buffer N        Extra seconds after window reset  ${DIM}(default: 5)${NC}"
    echo -e ""
    echo -e "${BOLD}BEHAVIOUR FLAGS${NC}"
    echo -e "  -F, --force          Force fresh run, ignore saved state"
    echo -e "  -v, --verbose        Verbose / debug output"
    echo -e "  -q, --quiet          Suppress progress (log file still written)"
    echo -e "  --dry-run            Show config without making API calls"
    echo -e "  --no-color           Disable coloured output"
    echo -e "  -h, --help           Show this help"
    echo -e ""
    echo -e "${BOLD}ENVIRONMENT VARIABLES${NC}"
    echo -e "  All flags can also be set via env vars with a QUALYS_ prefix:"
    echo -e "  QUALYS_ACCESS_TOKEN, QUALYS_GATEWAY, QUALYS_LIMIT, QUALYS_DAYS,"
    echo -e "  QUALYS_FILTER, QUALYS_ENDPOINT, QUALYS_OUTPUT_DIR, QUALYS_OUTPUT_FORMAT,"
    echo -e "  QUALYS_RETRIES, QUALYS_RETRY_DELAY, QUALYS_RETRY_DELAY_MAX,"
    echo -e "  QUALYS_CONNECT_TIMEOUT, QUALYS_REQUEST_TIMEOUT, QUALYS_CURL_EXTRA,"
    echo -e "  QUALYS_RL_FLOOR, QUALYS_RL_PAUSE, QUALYS_RL_BUFFER, QUALYS_VERBOSE"
    echo -e ""
    echo -e "${BOLD}SUPPORTED GATEWAYS${NC}"
    echo -e "  US   https://gateway.qg{1-4}.apps.qualys.com"
    echo -e "  EU   https://gateway.qg{1-2}.apps.qualys.eu"
    echo -e "  CA   https://gateway.qg1.apps.qualys.ca"
    echo -e "  IN   https://gateway.qg1.apps.qualys.in"
    echo -e "  AU   https://gateway.qg1.apps.qualys.com.au"
    echo -e "  AE   https://gateway.qg1.apps.qualys.ae"
    echo -e "  UK   https://gateway.qg1.apps.qualys.co.uk"
    echo -e "  IT   https://gateway.qg3.apps.qualys.it"
    echo -e "  KSA  https://gateway.qg1.apps.qualysksa.com"
    echo -e "  GOV  https://gateway.gov1.qualys.us"
    echo -e ""
    echo -e "${BOLD}IDEMPOTENCY${NC}"
    echo -e "  Re-running with the same -o resumes from the last successful page."
    echo -e "  Use -F / --force to ignore saved state and fetch fresh."
    echo -e ""
    echo -e "${BOLD}EXAMPLES${NC}"
    echo -e "  # Default: 50/page, last 30 days"
    echo -e "  ${SCRIPT_NAME} -g https://gateway.qg2.apps.qualys.com"
    echo -e ""
    echo -e "  # 200/page, last 7 days, verbose"
    echo -e "  ${SCRIPT_NAME} -g https://gateway.qg2.apps.qualys.com -l 200 -d 7 -v"
    echo -e ""
    echo -e "  # Force fresh, JSONL output, via proxy"
    echo -e "  ${SCRIPT_NAME} -g https://gateway.qg1.apps.qualys.eu -F --jsonl -C \"--proxy http://proxy:8080\""
    echo -e ""
    exit 0
}

log() {
    local level="$1"; shift
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")

    if ! $QUIET; then
        case "$level" in
            INFO)  echo -e "${BLUE}[INFO]${NC}  ${ts}  $*" ;;
            OK)    echo -e "${GREEN}[ OK ]${NC}  ${ts}  $*" ;;
            WARN)  echo -e "${YELLOW}[WARN]${NC}  ${ts}  $*" ;;
            ERROR) echo -e "${RED}[ERR ]${NC}  ${ts}  $*" ;;
            DEBUG) $VERBOSE && echo -e "${CYAN}[DBG ]${NC}  ${ts}  $*" || true ;;
        esac
    fi

    if [ -n "$LOG_FILE" ]; then
        printf "[%-5s] %s  %s\n" "$level" "$ts" "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    fi
}

die() { log ERROR "$@"; exit 1; }

check_dependencies() {
    local missing=()
    for cmd in curl jq mktemp; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required tools: ${missing[*]}.  Install:  sudo apt-get install -y ${missing[*]}"
    fi
    log DEBUG "Dependencies OK: curl $(curl --version | head -1 | awk '{print $2}'), jq $(jq --version 2>&1)"
}

# ─── Input validation ─────────────────────────────────────────────────────────
validate_inputs() {
    # Limit: 1–250
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 250 ]; then
        die "Limit must be between 1 and 250. Got: '${LIMIT}'"
    fi

    # Days: positive integer
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ]; then
        die "Days must be a positive integer. Got: '${DAYS}'"
    fi

    # Retry count: positive integer
    if ! [[ "$RETRY_COUNT" =~ ^[0-9]+$ ]] || [ "$RETRY_COUNT" -lt 1 ]; then
        die "Retries must be a positive integer. Got: '${RETRY_COUNT}'"
    fi

    # Timeouts: non-negative integers
    if ! [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]]; then
        die "Connect timeout must be a number. Got: '${CONNECT_TIMEOUT}'"
    fi
    if ! [[ "$REQUEST_TIMEOUT" =~ ^[0-9]+$ ]]; then
        die "Request timeout must be a number. Got: '${REQUEST_TIMEOUT}'"
    fi

    # Rate-limit params: non-negative integers
    if ! [[ "$RATE_LIMIT_FLOOR" =~ ^[0-9]+$ ]]; then
        die "--rl-floor must be a number. Got: '${RATE_LIMIT_FLOOR}'"
    fi
    if ! [[ "$RATE_LIMIT_PAUSE" =~ ^[0-9]+$ ]]; then
        die "--rl-pause must be a number. Got: '${RATE_LIMIT_PAUSE}'"
    fi
    if ! [[ "$RATE_LIMIT_WINDOW_BUFFER" =~ ^[0-9]+$ ]]; then
        die "--rl-buffer must be a number. Got: '${RATE_LIMIT_WINDOW_BUFFER}'"
    fi

    # Gateway URL format
    if [[ ! "$GATEWAY" =~ ^https:// ]]; then
        die "Gateway must start with https://. Got: '${GATEWAY}'"
    fi

    # Output format
    if [ "$OUTPUT_FORMAT" != "json" ] && [ "$OUTPUT_FORMAT" != "jsonl" ]; then
        die "Output format must be 'json' or 'jsonl'. Got: '${OUTPUT_FORMAT}'"
    fi
}

build_filter() {
    if [ -z "$FILTER" ]; then
        FILTER="imagesInUse:%60%5Bnow-${DAYS}d%20...%20now%5D%60"
    fi
}

# ─── Locking (prevents concurrent writes to the same output dir) ─────────────
acquire_lock() {
    LOCK_FILE="${OUTPUT_DIR}/.fetch.lock"
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            die "Another instance (PID ${lock_pid}) is running against ${OUTPUT_DIR}. Use a different -o or wait."
        else
            log WARN "Stale lock file found (PID ${lock_pid}). Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() { [ -n "${LOCK_FILE:-}" ] && rm -f "$LOCK_FILE"; }
trap release_lock EXIT

# ─── State management (resume / idempotency) ─────────────────────────────────

save_state() {
    # Args: $1=next_url (empty="done"), $2=page, $3=count
    jq -n \
        --arg next_url "$1" \
        --argjson page  "$2" \
        --argjson count "$3" \
        --arg gateway   "$GATEWAY" \
        --arg endpoint  "$ENDPOINT" \
        --arg filter    "$FILTER" \
        --argjson limit "$LIMIT" \
        --arg updated   "$(date -Iseconds)" \
        '{gateway:$gateway, endpoint:$endpoint, filter:$filter, limit:$limit,
          last_completed_page:$page, images_so_far:$count,
          next_url:$next_url, updated_at:$updated}' \
        > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

load_state() {
    # Force flag: clear everything, start fresh
    if $FORCE; then
        log INFO "Force mode (-F): clearing saved state."
        rm -f "$STATE_FILE"
        rm -f "${PAGES_DIR}"/page_*.json 2>/dev/null || true
        rm -f "${OUTPUT_DIR}/all_images.json" "${OUTPUT_DIR}/all_images.jsonl" 2>/dev/null || true
        return 1
    fi

    [ ! -f "$STATE_FILE" ] && return 1

    local s_gw s_ep s_fl s_lm s_next s_pg s_ct
    s_gw=$(jq  -r '.gateway'              "$STATE_FILE" 2>/dev/null || true)
    s_ep=$(jq  -r '.endpoint'             "$STATE_FILE" 2>/dev/null || true)
    s_fl=$(jq  -r '.filter'               "$STATE_FILE" 2>/dev/null || true)
    s_lm=$(jq  -r '.limit'                "$STATE_FILE" 2>/dev/null || true)
    s_next=$(jq -r '.next_url'            "$STATE_FILE" 2>/dev/null || true)
    s_pg=$(jq  -r '.last_completed_page'  "$STATE_FILE" 2>/dev/null || true)
    s_ct=$(jq  -r '.images_so_far'        "$STATE_FILE" 2>/dev/null || true)

    # If run parameters changed, discard state
    if [ "$s_gw" != "$GATEWAY" ] || [ "$s_ep" != "$ENDPOINT" ] || \
       [ "$s_fl" != "$FILTER" ]  || [ "$s_lm" != "$LIMIT" ]; then
        log WARN "Parameters changed since last run. Starting fresh."
        rm -f "$STATE_FILE"
        rm -f "${PAGES_DIR}"/page_*.json 2>/dev/null || true
        return 1
    fi

    # Already completed
    if [ -z "$s_next" ] || [ "$s_next" = "" ] || [ "$s_next" = "null" ]; then
        RESUME_DONE=true; RESUME_COUNT=$s_ct; RESUME_PAGE=$s_pg; return 0
    fi

    # Partial — resume from here
    RESUME_DONE=false; RESUME_NEXT_URL="$s_next"
    RESUME_PAGE=$s_pg; RESUME_COUNT=$s_ct; return 0
}

# ─── Rate-limit helpers ──────────────────────────────────────────────────────

parse_rate_limit_headers() {
    local hdr="$1"
    RL_REMAINING=$(grep -i 'x-ratelimit-remaining'  "$hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r\n' || true)
    RL_LIMIT_HDR=$(grep -i 'x-ratelimit-limit'      "$hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r\n' || true)
    RL_WINDOW=$(grep    -i 'x-ratelimit-window-sec'  "$hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r\n' || true)
}

# Called after every successful response — proactively throttles
handle_rate_limit() {
    parse_rate_limit_headers "$1"
    [ -z "$RL_REMAINING" ] && return 0

    log DEBUG "Rate limit: ${RL_REMAINING}/${RL_LIMIT_HDR} remaining (window ${RL_WINDOW}s)"

    if [ "$RL_REMAINING" -le 0 ] 2>/dev/null; then
        local wait=${RL_WINDOW:-60}
        wait=$((wait + RATE_LIMIT_WINDOW_BUFFER))
        echo ""
        log WARN "Rate limit exhausted (0/${RL_LIMIT_HDR}). Waiting ${wait}s for window reset..."
        sleep "$wait"
    elif [ "$RL_REMAINING" -lt "$RATE_LIMIT_FLOOR" ] 2>/dev/null; then
        echo ""
        log WARN "Rate limit low (${RL_REMAINING}/${RL_LIMIT_HDR}). Pausing ${RATE_LIMIT_PAUSE}s..."
        sleep "$RATE_LIMIT_PAUSE"
    fi
}

# Computes wait time for a 429 response
compute_429_wait() {
    local hdr="$1"
    local ra window wait=0
    ra=$(grep     -i 'retry-after'            "$hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r\n' || true)
    window=$(grep -i 'x-ratelimit-window-sec' "$hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r\n' || true)

    if [ -n "$ra" ] && [ "$ra" -gt 0 ] 2>/dev/null; then
        wait=$ra
    elif [ -n "$window" ] && [ "$window" -gt 0 ] 2>/dev/null; then
        wait=$((window + RATE_LIMIT_WINDOW_BUFFER))
    fi
    [ "$wait" -lt "$RETRY_DELAY_BASE" ] && wait=$RETRY_DELAY_BASE
    echo "$wait"
}

# ─── Fetch one page with exponential back-off ────────────────────────────────
fetch_page() {
    local url="$1" out_body="$2" out_headers="$3"
    local attempt=0 http_code="" delay=$RETRY_DELAY_BASE

    while true; do
        attempt=$((attempt + 1))
        TOTAL_API_CALLS=$((TOTAL_API_CALLS + 1))

        # shellcheck disable=SC2086  # CURL_EXTRA_ARGS intentionally word-split
        http_code=$(curl -s -w "%{http_code}" \
            -o "$out_body" -D "$out_headers" \
            -H "Accept: application/json" \
            -H "Authorization: Bearer ${TOKEN}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$REQUEST_TIMEOUT" \
            $CURL_EXTRA_ARGS \
            "$url" 2>/dev/null) || http_code="000"

        # ── Success
        [ "$http_code" = "200" ] && return 0

        # ── Non-retryable (return 1 so caller can save state before exiting)
        case "$http_code" in
            401|403)
                log ERROR "Authentication failed (HTTP ${http_code}). Token may be expired or invalid."
                return 1
                ;;
            404)
                log ERROR "Endpoint not found (HTTP 404). Verify gateway URL and endpoint path."
                return 1
                ;;
            400)
                log ERROR "Bad request (HTTP 400). Check filter syntax. Try using -d instead of -f."
                return 1
                ;;
        esac

        # ── Max retries exhausted
        if [ "$attempt" -ge "$RETRY_COUNT" ]; then
            log ERROR "Failed after ${RETRY_COUNT} attempts. Last HTTP: ${http_code}"
            return 1
        fi

        TOTAL_RETRIES=$((TOTAL_RETRIES + 1))

        # ── Retryable: 429, 5xx, connection failure
        if [ "$http_code" = "429" ]; then
            delay=$(compute_429_wait "$out_headers")
            log WARN "Rate limited (429). Waiting ${delay}s  [attempt ${attempt}/${RETRY_COUNT}]"
        elif [ "$http_code" = "000" ]; then
            log WARN "Connection failed. Waiting ${delay}s  [attempt ${attempt}/${RETRY_COUNT}]"
        else
            log WARN "HTTP ${http_code}. Waiting ${delay}s  [attempt ${attempt}/${RETRY_COUNT}]"
        fi

        sleep "$delay"

        # Exponential back-off with cap (skip for 429 — already computed optimal wait)
        if [ "$http_code" != "429" ]; then
            delay=$((delay * 2))
            [ "$delay" -gt "$RETRY_DELAY_MAX" ] && delay=$RETRY_DELAY_MAX
        fi
    done
}

# ─── Validate a fetched page ─────────────────────────────────────────────────
validate_page() {
    local file="$1"
    if ! jq empty "$file" 2>/dev/null; then
        log ERROR "Page response is not valid JSON."
        return 1
    fi
    if ! jq -e '.data | type == "array"' "$file" >/dev/null 2>&1; then
        log ERROR "Page JSON does not contain a 'data' array."
        return 1
    fi
    return 0
}

# ─── Main pagination loop ────────────────────────────────────────────────────
fetch_all_images() {
    local next_url="${GATEWAY}${ENDPOINT}?filter=${FILTER}&limit=${LIMIT}"
    local page=0 total_count=0 failed=false
    local start_time; start_time=$(date +%s)
    local tmp_body; tmp_body=$(mktemp)
    local tmp_headers; tmp_headers=$(mktemp)

    # ── Resume handling
    RESUME_DONE=false; RESUME_NEXT_URL=""; RESUME_PAGE=0; RESUME_COUNT=0

    if load_state; then
        if $RESUME_DONE; then
            print_summary "$RESUME_COUNT" "$RESUME_PAGE" 0 "ALREADY COMPLETE" 0 0
            rm -f "$tmp_body" "$tmp_headers"
            log INFO "Use ${BOLD}-F${NC} / ${BOLD}--force${NC} to fetch fresh data."
            return 0
        fi
        page=$RESUME_PAGE; total_count=$RESUME_COUNT; next_url="$RESUME_NEXT_URL"
        log OK "Resuming from page $((page + 1)) (${total_count} images already fetched)"
    fi

    # ── Config display
    echo ""
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log INFO "${BOLD}Gateway   :${NC}  ${GATEWAY}"
    log INFO "${BOLD}Endpoint  :${NC}  ${ENDPOINT}"
    log INFO "${BOLD}Filter    :${NC}  imagesInUse last ${DAYS} days"
    log INFO "${BOLD}Limit     :${NC}  ${LIMIT}/page"
    log INFO "${BOLD}Output    :${NC}  ${OUTPUT_DIR}/  (format: ${OUTPUT_FORMAT})"
    log INFO "${BOLD}Retries   :${NC}  ${RETRY_COUNT} per page (backoff: ${RETRY_DELAY_BASE}s–${RETRY_DELAY_MAX}s)"
    log INFO "${BOLD}Timeouts  :${NC}  connect ${CONNECT_TIMEOUT}s / request ${REQUEST_TIMEOUT}s"
    log INFO "${BOLD}RL Floor  :${NC}  throttle below ${RATE_LIMIT_FLOOR} remaining calls"
    [ -n "$CURL_EXTRA_ARGS" ] && log INFO "${BOLD}Curl args :${NC}  ${CURL_EXTRA_ARGS}"
    [ "$page" -gt 0 ] && log INFO "${BOLD}Resumed   :${NC}  from page $((page + 1)), ${total_count} images cached"
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # ── Dry run
    if $DRY_RUN; then
        log INFO "DRY RUN — first URL would be:"
        log INFO "  ${next_url}"
        log INFO "No API calls made. Remove --dry-run to execute."
        rm -f "$tmp_body" "$tmp_headers"
        return 0
    fi

    # ── Pagination loop (runs until the API returns no more pages) ────────
    while [ -n "$next_url" ]; do
        page=$((page + 1))
        log DEBUG "Fetching page ${page}: ${next_url}"

        # Fetch
        if ! fetch_page "$next_url" "$tmp_body" "$tmp_headers"; then
            failed=true
            log ERROR "Unrecoverable error on page ${page}. State saved — re-run to resume."
            save_state "$next_url" "$((page - 1))" "$total_count"
            break
        fi

        # Validate
        if ! validate_page "$tmp_body"; then
            failed=true
            log ERROR "Invalid response on page ${page}. State saved — re-run to resume."
            save_state "$next_url" "$((page - 1))" "$total_count"
            cp "$tmp_body" "${PAGES_DIR}/page_$(printf '%06d' $page)_BAD.json"
            break
        fi

        # Count images
        local page_count
        page_count=$(jq '.data | length' "$tmp_body")
        total_count=$((total_count + page_count))

        # Persist page to disk (enables resume)
        cp "$tmp_body" "${PAGES_DIR}/page_$(printf '%06d' $page).json"

        # Rate-limit info for progress display
        parse_rate_limit_headers "$tmp_headers"
        local rl_info=""
        if [ -n "$RL_REMAINING" ]; then
            rl_info="  │ API: ${RL_REMAINING}/${RL_LIMIT_HDR} (${RL_WINDOW}s)"
        fi

        # Progress line
        if ! $QUIET; then
            printf "\r  ${GREEN}✓${NC} Page %-6s│ This page: %-6s│ Total: %-10s${rl_info}      " \
                   "$page" "$page_count" "$total_count"
        fi

        # Rate-limit handling (proactive throttle)
        handle_rate_limit "$tmp_headers"

        # Next page URL from Link header
        next_url=$(grep -i '^link:' "$tmp_headers" 2>/dev/null | grep -oP '<\K[^>]+' || true)

        # Save state after every successful page
        save_state "${next_url}" "$page" "$total_count"
    done

    $QUIET || { echo ""; echo ""; }

    rm -f "$tmp_body" "$tmp_headers"

    # ── Assemble final output
    if ! $failed; then
        log INFO "Assembling final output..."
        assemble_output "$total_count"
    fi

    local end_time duration
    end_time=$(date +%s); duration=$((end_time - start_time))

    local status="SUCCESS"
    $failed && status="FAILED (partial — re-run to resume)"

    print_summary "$total_count" "$page" "$duration" "$status" "$TOTAL_API_CALLS" "$TOTAL_RETRIES"

    $failed && exit 1
    return 0
}

# ─── Assemble per-page files into one verified output ─────────────────────────
assemble_output() {
    local expected_count="$1"
    local ext="json"
    [ "$OUTPUT_FORMAT" = "jsonl" ] && ext="jsonl"
    local combined="${OUTPUT_DIR}/all_images.${ext}"
    local combined_tmp="${combined}.assembling"
    local assembled_count=0

    if [ "$OUTPUT_FORMAT" = "jsonl" ]; then
        # JSONL: one JSON object per line, no wrapping array
        > "$combined_tmp"
        for pf in "${PAGES_DIR}"/page_*.json; do
            [ -f "$pf" ] || continue
            [[ "$pf" == *"_BAD.json" ]] && continue
            local pc
            pc=$(jq '.data | length' "$pf" 2>/dev/null || echo 0)
            if [ "$pc" -gt 0 ]; then
                jq -c '.data[]' "$pf" >> "$combined_tmp"
                assembled_count=$((assembled_count + pc))
            fi
        done
    else
        # JSON array
        echo "[" > "$combined_tmp"
        local first=true
        for pf in "${PAGES_DIR}"/page_*.json; do
            [ -f "$pf" ] || continue
            [[ "$pf" == *"_BAD.json" ]] && continue
            local pc
            pc=$(jq '.data | length' "$pf" 2>/dev/null || echo 0)
            if [ "$pc" -gt 0 ]; then
                $first && first=false || echo "," >> "$combined_tmp"
                jq -c '.data[]' "$pf" | paste -sd ',' >> "$combined_tmp"
                assembled_count=$((assembled_count + pc))
            fi
        done
        echo "]" >> "$combined_tmp"

        # Validate assembled JSON
        if ! jq empty "$combined_tmp" 2>/dev/null; then
            log ERROR "Assembled JSON is invalid. Per-page files preserved in ${PAGES_DIR}/."
            rm -f "$combined_tmp"
            return 1
        fi
    fi

    # Integrity check
    if [ "$assembled_count" -ne "$expected_count" ]; then
        log WARN "Count mismatch: expected ${expected_count}, assembled ${assembled_count}. Pages kept for review."
    fi

    # Atomic write
    mv "$combined_tmp" "$combined"

    local file_size
    file_size=$(du -h "$combined" | awk '{print $1}')
    log OK "Output: ${combined}  (${assembled_count} images, ${file_size})"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    local total="$1" pages="$2" duration="$3" status="$4"
    local api_calls="$5" retries="$6"

    local ext="json"; [ "$OUTPUT_FORMAT" = "jsonl" ] && ext="jsonl"
    local combined="${OUTPUT_DIR}/all_images.${ext}"
    local file_size="—"
    [ -f "$combined" ] && file_size=$(du -h "$combined" | awk '{print $1}')

    local sc="${GREEN}"
    [[ "$status" == FAILED* ]]  && sc="${RED}"
    [[ "$status" == ALREADY* ]] && sc="${YELLOW}"

    echo ""
    echo -e "${BOLD}FETCH SUMMARY${NC}"
    echo -e "─────────────────────────────────────────────────────"
    echo -e "  Gateway           ${GATEWAY}"
    echo -e "  Status            ${sc}${status}${NC}"
    echo -e "  ${BOLD}Total Images      ${total}${NC}"
    echo -e "  Pages Fetched     ${pages}"
    echo -e "  Limit             ${LIMIT}/page"
    echo -e "  Filter            last ${DAYS} days"
    echo -e "  Duration          ${duration}s"
    echo -e "  API Calls         ${api_calls}  (retries: ${retries})"
    echo -e "  Output Format     ${OUTPUT_FORMAT}"
    echo -e "  Output File       ${combined} (${file_size})"
    echo -e "  Pages Dir         ${PAGES_DIR}/"
    echo -e "  Log File          ${LOG_FILE}"
    echo -e "─────────────────────────────────────────────────────"
    echo ""

    # ── Plain-text summary file
    cat > "${OUTPUT_DIR}/summary.txt" <<EOTXT
QUALYS IMAGE FETCH — SUMMARY
========================================
Version        : ${VERSION}
Timestamp      : $(date -Iseconds)
Gateway        : ${GATEWAY}
Endpoint       : ${ENDPOINT}
Filter         : ${FILTER}
Filter Days    : ${DAYS}
Limit          : ${LIMIT}/page
Output Format  : ${OUTPUT_FORMAT}
Status         : ${status}
Total Images   : ${total}
Pages          : ${pages}
Duration       : ${duration}s
API Calls      : ${api_calls}
Retries        : ${retries}
Output         : ${combined} (${file_size})
EOTXT

    # ── Machine-readable JSON summary
    jq -n \
        --arg version    "$VERSION" \
        --arg timestamp  "$(date -Iseconds)" \
        --arg gateway    "$GATEWAY" \
        --arg endpoint   "$ENDPOINT" \
        --arg filter     "$FILTER" \
        --argjson days   "$DAYS" \
        --argjson limit  "$LIMIT" \
        --arg format     "$OUTPUT_FORMAT" \
        --arg status     "$status" \
        --argjson images "$total" \
        --argjson pages  "$pages" \
        --argjson dur    "$duration" \
        --argjson calls  "$api_calls" \
        --argjson ret    "$retries" \
        --arg output     "$combined" \
        --arg size       "$file_size" \
        '{version:$version, timestamp:$timestamp, gateway:$gateway,
          endpoint:$endpoint, filter:$filter, filter_days:$days, limit:$limit,
          output_format:$format, status:$status, total_images:$images,
          pages:$pages, duration_seconds:$dur, api_calls:$calls, retries:$ret,
          output_file:$output, file_size:$size}' \
        > "${OUTPUT_DIR}/summary.json"
}

# ─── Argument parsing (short flags via getopts) ──────────────────────────────
while getopts "t:g:f:l:d:e:o:r:T:M:C:Fvqh" opt; do
    case "$opt" in
        t) TOKEN="$OPTARG" ;;
        g) GATEWAY="$OPTARG" ;;
        f) FILTER="$OPTARG" ;;
        l) LIMIT="$OPTARG" ;;
        d) DAYS="$OPTARG" ;;
        e) ENDPOINT="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        r) RETRY_COUNT="$OPTARG" ;;
        T) CONNECT_TIMEOUT="$OPTARG" ;;
        M) REQUEST_TIMEOUT="$OPTARG" ;;
        C) CURL_EXTRA_ARGS="$OPTARG" ;;
        F) FORCE=true ;;
        v) VERBOSE=true ;;
        q) QUIET=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─── Validate & Setup ────────────────────────────────────────────────────────

check_dependencies

[ -z "$GATEWAY" ] && die "No gateway specified. Use -g <url> or set \$QUALYS_GATEWAY.  Run with -h for help."
[ -z "$TOKEN" ]   && die "No token. Use -t <token> or:  export QUALYS_ACCESS_TOKEN=\"your_token\""

# Strip trailing slash from gateway
GATEWAY="${GATEWAY%/}"

validate_inputs
build_filter

# Create output structure
mkdir -p "$OUTPUT_DIR"
PAGES_DIR="${OUTPUT_DIR}/pages"
mkdir -p "$PAGES_DIR"
STATE_FILE="${OUTPUT_DIR}/.fetch_state.json"
LOG_FILE="${OUTPUT_DIR}/fetch_${TIMESTAMP}.log"
touch "$LOG_FILE"

# ─── Go ───────────────────────────────────────────────────────────────────────

acquire_lock

$QUIET || {
    echo ""
    echo -e "${BOLD}Qualys Image Fetcher v${VERSION}${NC}"
    echo -e "${DIM}Copyright (c) 2026 Qualys, Inc.${NC}"
    echo ""
}

fetch_all_images

log OK "All done."
