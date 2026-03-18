# Qualys Container Security — Image Fetcher

Enterprise-grade CLI tool that pulls **every container image record** from a Qualys CSAPI gateway with automatic pagination, full rate-limit handling, resume capability, and structured reporting.

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Shell](https://img.shields.io/badge/shell-bash%204%2B-green)
![License](https://img.shields.io/badge/license-Apache%202.0-orange)

> **Copyright (c) 2026 Qualys, Inc. All rights reserved.**

---

## Features

| Feature | Description |
|---|---|
| **Unlimited Pagination** | Follows the API's `Link` header until every page is fetched — no artificial caps |
| **Idempotent & Resumable** | Saves state after every page; re-run the same command to resume from where it stopped |
| **Rate-Limit Aware** | Reads `X-RateLimit-Remaining`, `X-RateLimit-Limit`, `X-RateLimit-Window-Sec`; proactively throttles before hitting the ceiling; honours `Retry-After` on 429s |
| **Exponential Back-off** | Retries transient failures (5xx, timeouts, connection errors) with configurable back-off up to 120s |
| **Data Integrity** | Validates every page as well-formed JSON with a `data` array; verifies final image count matches |
| **Atomic Writes** | Final output is assembled to a temp file and atomically moved into place |
| **Flexible Output** | JSON array (default) or JSON Lines (`--jsonl`) |
| **Fully Customizable** | Every parameter configurable via CLI flags **or** environment variables |
| **Lock File** | Prevents two instances from writing to the same output directory |
| **Structured Reports** | Generates `summary.txt`, `summary.json`, and a timestamped log file |
| **Proxy Support** | Pass arbitrary curl arguments (e.g. `--proxy`) via `-C` |
| **Dry Run** | Preview configuration without making any API calls |

---

## Prerequisites

- **bash** 4.0+
- **curl**
- **jq**

```bash
# Ubuntu / Debian
sudo apt-get install -y curl jq

# RHEL / CentOS / Amazon Linux
sudo yum install -y curl jq

# macOS
brew install curl jq
```

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/Qualys/qualys-image-fetcher.git
cd qualys-image-fetcher

# 2. Make executable
chmod +x qualys_image_fetcher.sh

# 3. Set your token (never put tokens in command history)
export QUALYS_ACCESS_TOKEN="eyJhbGciOi..."

# 4. Run
./qualys_image_fetcher.sh -g "https://gateway.qg2.apps.qualys.com"
```

Default behaviour: **50 images per page**, images in use in the **last 30 days**.

---

## Usage

```
./qualys_image_fetcher.sh -g <gateway_url> [options]
./qualys_image_fetcher.sh -t <token> -g <gateway_url> [options]
```

### Required

| Flag | Description |
|---|---|
| `-g GATEWAY` | Gateway base URL (see [Supported Gateways](#supported-gateways)) |

### Authentication

| Flag | Description | Default |
|---|---|---|
| `-t TOKEN` | Bearer token | `$QUALYS_ACCESS_TOKEN` env var |

### Query Options

| Flag | Description | Default | Valid Range |
|---|---|---|---|
| `-l LIMIT` | Results per page | `50` | 1–250 |
| `-d DAYS` | Images in use in the last N days | `30` | 1+ |
| `-f FILTER` | Raw URL-encoded filter (overrides `-d`) | auto-built from `-d` | — |
| `-e ENDPOINT` | API endpoint path | `/csapi/v1.3/images/snow` | — |

### Output Options

| Flag | Description | Default |
|---|---|---|
| `-o OUTPUT_DIR` | Output directory | `./qualys_output` |
| `--jsonl` | Output as JSON Lines instead of JSON array | `json` |

### Reliability Options

| Flag | Description | Default |
|---|---|---|
| `-r RETRIES` | Max retries per page | `5` |
| `-T SECONDS` | Curl connect timeout | `30` |
| `-M SECONDS` | Curl max request time | `300` |
| `-C ARGS` | Extra curl arguments (e.g. `"--proxy http://proxy:8080"`) | — |

### Rate Limiting Options

| Flag | Description | Default |
|---|---|---|
| `--rl-floor N` | Start throttling below N remaining calls | `10` |
| `--rl-pause N` | Seconds to pause when throttling | `3` |
| `--rl-buffer N` | Extra seconds buffer after window reset | `5` |

### Behaviour Flags

| Flag | Description |
|---|---|
| `-F`, `--force` | Force fresh run, ignore saved state |
| `-v`, `--verbose` | Verbose / debug output |
| `-q`, `--quiet` | Suppress progress output (log file still written) |
| `--dry-run` | Show configuration without making API calls |
| `--no-color` | Disable coloured terminal output |
| `-h`, `--help` | Show help |

---

## Environment Variables

Every flag can also be set via an environment variable with a `QUALYS_` prefix. CLI flags take precedence over env vars.

| Variable | Equivalent Flag | Default |
|---|---|---|
| `QUALYS_ACCESS_TOKEN` | `-t` | — |
| `QUALYS_GATEWAY` | `-g` | — |
| `QUALYS_LIMIT` | `-l` | `50` |
| `QUALYS_DAYS` | `-d` | `30` |
| `QUALYS_FILTER` | `-f` | auto-built |
| `QUALYS_ENDPOINT` | `-e` | `/csapi/v1.3/images/snow` |
| `QUALYS_OUTPUT_DIR` | `-o` | `./qualys_output` |
| `QUALYS_OUTPUT_FORMAT` | `--jsonl` | `json` |
| `QUALYS_RETRIES` | `-r` | `5` |
| `QUALYS_RETRY_DELAY` | — | `3` (back-off base) |
| `QUALYS_RETRY_DELAY_MAX` | — | `120` (back-off ceiling) |
| `QUALYS_CONNECT_TIMEOUT` | `-T` | `30` |
| `QUALYS_REQUEST_TIMEOUT` | `-M` | `300` |
| `QUALYS_CURL_EXTRA` | `-C` | — |
| `QUALYS_RL_FLOOR` | `--rl-floor` | `10` |
| `QUALYS_RL_PAUSE` | `--rl-pause` | `3` |
| `QUALYS_RL_BUFFER` | `--rl-buffer` | `5` |
| `QUALYS_VERBOSE` | `-v` | `false` |

---

## Examples

```bash
# Default: 50/page, last 30 days
./qualys_image_fetcher.sh -g "https://gateway.qg2.apps.qualys.com"

# 200/page, last 7 days, verbose
./qualys_image_fetcher.sh -g "https://gateway.qg2.apps.qualys.com" -l 200 -d 7 -v

# Force fresh run (ignore cached state)
./qualys_image_fetcher.sh -g "https://gateway.qg2.apps.qualys.com" -F

# Output as JSON Lines
./qualys_image_fetcher.sh -g "https://gateway.qg2.apps.qualys.com" --jsonl

# Via corporate proxy
./qualys_image_fetcher.sh -g "https://gateway.qg1.apps.qualys.eu" \
    -C "--proxy http://proxy.corp.com:8080"

# Dry run — preview what would be fetched
./qualys_image_fetcher.sh -g "https://gateway.qg2.apps.qualys.com" --dry-run

# Quiet mode (for cron / CI pipelines)
./qualys_image_fetcher.sh -g "https://gateway.qg2.apps.qualys.com" -q

# Everything via env vars
export QUALYS_ACCESS_TOKEN="eyJ..."
export QUALYS_GATEWAY="https://gateway.qg2.apps.qualys.com"
export QUALYS_LIMIT=100
export QUALYS_DAYS=14
./qualys_image_fetcher.sh
```

---

## Output Structure

After a successful run:

```
qualys_output/
├── all_images.json            # Final combined output (all images)
├── summary.json               # Machine-readable run summary
├── summary.txt                # Human-readable run summary
├── fetch_20260318_214500.log  # Detailed log with timestamps
├── pages/
│   ├── page_000001.json       # Raw API response — page 1
│   ├── page_000002.json       # Raw API response — page 2
│   └── ...                    # One file per page (enables resume)
└── .fetch_state.json          # Resume state (auto-managed, do not edit)
```

### `summary.json`

```json
{
  "version": "1.0.0",
  "timestamp": "2026-03-18T21:45:00+00:00",
  "gateway": "https://gateway.qg2.apps.qualys.com",
  "endpoint": "/csapi/v1.3/images/snow",
  "filter": "imagesInUse:%60%5Bnow-30d%20...%20now%5D%60",
  "filter_days": 30,
  "limit": 50,
  "output_format": "json",
  "status": "SUCCESS",
  "total_images": 1247,
  "pages": 25,
  "duration_seconds": 38,
  "api_calls": 25,
  "retries": 0,
  "output_file": "./qualys_output/all_images.json",
  "file_size": "42M"
}
```

---

## Supported Gateways

Each Qualys customer is assigned a single gateway based on their subscription region.

| Region | Gateway URL |
|---|---|
| US | `https://gateway.qg1.apps.qualys.com` |
| US | `https://gateway.qg2.apps.qualys.com` |
| US | `https://gateway.qg3.apps.qualys.com` |
| US | `https://gateway.qg4.apps.qualys.com` |
| EU | `https://gateway.qg1.apps.qualys.eu` |
| EU | `https://gateway.qg2.apps.qualys.eu` |
| Canada | `https://gateway.qg1.apps.qualys.ca` |
| India | `https://gateway.qg1.apps.qualys.in` |
| Australia | `https://gateway.qg1.apps.qualys.com.au` |
| UAE | `https://gateway.qg1.apps.qualys.ae` |
| UK | `https://gateway.qg1.apps.qualys.co.uk` |
| Italy | `https://gateway.qg3.apps.qualys.it` |
| KSA | `https://gateway.qg1.apps.qualysksa.com` |
| US Gov | `https://gateway.gov1.qualys.us` |

---

## How It Works

### Pagination

The Qualys CSAPI uses cursor-based pagination via the HTTP `Link` header:

```
Link: <https://gateway.../images/snow?limit=50&paginationQuery=...>;rel=next
```

The script follows this link until no `Link` header is returned, meaning all data has been fetched. There is **no artificial page limit** — it runs until complete.

### Rate Limiting

The API returns rate-limit metadata in response headers:

| Header | Meaning |
|---|---|
| `X-RateLimit-Limit` | Max calls allowed per window |
| `X-RateLimit-Remaining` | Calls left in current window |
| `X-RateLimit-Window-Sec` | Window duration in seconds |

The script reads these after every request and:

1. **Proactively throttles** when `Remaining` drops below the floor (default: 10)
2. **Waits for full window reset** when `Remaining` hits 0
3. **Honours `Retry-After`** on HTTP 429 responses
4. Uses the **longer** of `Retry-After` and window reset time

### Idempotency & Resume

After every successful page, the script writes `.fetch_state.json` tracking progress. On re-run:

- **Same parameters** → resumes from the last successful page
- **Different parameters** → detects mismatch, starts fresh automatically
- **`-F` / `--force`** → clears state and starts fresh
- **Already complete** → shows cached summary, no API calls

### Data Integrity

1. Every page response is validated as proper JSON with a `data` array
2. Invalid pages are saved as `page_NNNNNN_BAD.json` for debugging
3. The final output is assembled from per-page files with a count verification
4. Assembly uses atomic write (temp file → `mv`) to prevent partial output files

---

## CI/CD Integration

### Cron Job

```bash
# /etc/cron.d/qualys-fetch
0 2 * * * root QUALYS_ACCESS_TOKEN="$(cat /etc/qualys/token)" \
    /opt/qualys-image-fetcher/qualys_image_fetcher.sh \
    -g "https://gateway.qg2.apps.qualys.com" \
    -o /var/data/qualys/$(date +\%Y\%m\%d) -q -F
```

### GitHub Actions

```yaml
- name: Fetch Qualys Images
  run: |
    ./qualys_image_fetcher.sh \
      -g "${{ secrets.QUALYS_GATEWAY }}" \
      -t "${{ secrets.QUALYS_TOKEN }}" \
      -o ./qualys-data \
      --no-color -q -F

- name: Upload Results
  uses: actions/upload-artifact@v4
  with:
    name: qualys-images
    path: ./qualys-data/
```

### Docker

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y curl jq && rm -rf /var/lib/apt/lists/*
COPY qualys_image_fetcher.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/qualys_image_fetcher.sh
ENTRYPOINT ["qualys_image_fetcher.sh"]
```

```bash
docker build -t qualys-image-fetcher .
docker run --rm \
    -e QUALYS_ACCESS_TOKEN="$QUALYS_ACCESS_TOKEN" \
    -v $(pwd)/output:/output \
    qualys-image-fetcher -g "https://gateway.qg2.apps.qualys.com" -o /output
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Authentication failed (HTTP 401)` | Token expired | Generate a new token |
| `Authentication failed (HTTP 403)` | Insufficient permissions | Verify token scope includes CSAPI access |
| `Endpoint not found (HTTP 404)` | Wrong gateway or endpoint | Double-check `-g` URL and `-e` path |
| `Bad request (HTTP 400)` | Malformed filter | Use `-d 30` instead of raw `-f`; check encoding |
| `Connection failed` | Network / DNS / firewall | Check connectivity; try `-C "--proxy ..."` |
| `Rate limited (429)` | Too many requests | Handled automatically; reduce `-l` for fewer calls |
| `Another instance is running` | Lock file present | Wait for it, or `rm ./qualys_output/.fetch.lock` if stale |
| `ALREADY COMPLETE` | Idempotency — previous run succeeded | Use `-F` to force fresh fetch |
| `Count mismatch` | Assembly integrity warning | Inspect per-page files in `pages/` |
| `Missing tools: jq` | jq not installed | `sudo apt-get install -y jq` |
| `--help shows escape codes` | Piped to file/tool | Expected — use `--no-color` for clean output |

---

## Security

- **Never hardcode tokens** in scripts, command history, or source control. Use `export QUALYS_ACCESS_TOKEN` or read from a secrets manager (Vault, AWS Secrets Manager, etc.).
- The token is transmitted via the `Authorization` header over **HTTPS only** — it is never logged to the log file or state file.
- The `.fetch_state.json` file does **not** store the token.
- Use `--quiet` in CI/CD to suppress console output that could leak to build logs.
- The script validates that the gateway URL starts with `https://` and rejects plain HTTP.

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

Please ensure your changes pass `shellcheck qualys_image_fetcher.sh` before submitting.

---

## License

Copyright (c) 2026 Qualys, Inc. All rights reserved.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
