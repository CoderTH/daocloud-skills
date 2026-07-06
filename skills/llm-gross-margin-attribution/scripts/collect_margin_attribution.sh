#!/bin/sh
set -eu

HOST=""
CURRENT_START=""
CURRENT_END=""
BASELINE_START=""
BASELINE_END=""
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  collect_margin_attribution.sh \
    --hostname <dce-host> \
    --current-start <RFC3339> --current-end <RFC3339> \
    --baseline-start <RFC3339> --baseline-end <RFC3339> \
    [--output-dir <dir>]

Collects live DCE JSON evidence only. It does not parse JSON and does not need
extra interpreters, JSON parsers, package installs, or third-party libraries.
EOF
}

need_value() {
  [ "$#" -ge 2 ] || { echo "$1 requires an argument" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname) need_value "$@"; HOST="$2"; shift 2 ;;
    --current-start) need_value "$@"; CURRENT_START="$2"; shift 2 ;;
    --current-end) need_value "$@"; CURRENT_END="$2"; shift 2 ;;
    --baseline-start) need_value "$@"; BASELINE_START="$2"; shift 2 ;;
    --baseline-end) need_value "$@"; BASELINE_END="$2"; shift 2 ;;
    --output-dir) need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$CURRENT_START" ] || { echo "--current-start required" >&2; exit 2; }
[ -n "$CURRENT_END" ] || { echo "--current-end required" >&2; exit 2; }
[ -n "$BASELINE_START" ] || { echo "--baseline-start required" >&2; exit 2; }
[ -n "$BASELINE_END" ] || { echo "--baseline-end required" >&2; exit 2; }

if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-margin-evidence-XXXXXX")"
fi
mkdir -p "$OUTPUT_DIR"
TRACE="$OUTPUT_DIR/trace.tsv"
: > "$TRACE"

if [ -n "$HOST" ]; then
  export DCE_HOST="$HOST"
fi

run_dce() {
  name="$1"
  shift
  out="$OUTPUT_DIR/$name.json"
  err="$OUTPUT_DIR/$name.err"
  cmd="dce $*"
  if dce "$@" >"$out" 2>"$err"; then
    printf '%s\t%s\t%s\n' "$name" "ok" "$cmd" >> "$TRACE"
  else
    printf '%s\t%s\t%s\n' "$name" "failed" "$cmd" >> "$TRACE"
  fi
}

date_part() {
  printf '%s\n' "$1" | sed 's/T.*//'
}

current_date="$(date_part "$CURRENT_START")"
baseline_date="$(date_part "$BASELINE_START")"

run_dce auth_status auth status
run_dce workspaces global-management workspace list-workspaces --page 1 --page-size 200 -o json
run_dce model_serving llm-studio modelservingmanagement list-model-serving --page.page-size -1 -o json
run_dce maas_models llm-studio maasservice list-maas-models -o json
run_dce cost_config_search search "analysis-center cost mock config" --json
run_dce cost_command_catalog commands --include-hidden --json
run_dce current_usage llm-studio apikeymanagement get-api-key-usage-statistics2 --start-time "$CURRENT_START" --end-time "$CURRENT_END" --period TIME_PERIOD_DAY -o json
run_dce baseline_usage llm-studio apikeymanagement get-api-key-usage-statistics2 --start-time "$BASELINE_START" --end-time "$BASELINE_END" --period TIME_PERIOD_DAY -o json
run_dce current_bills billing-center bill list-bills --billing-time-start "$current_date" --billing-time-end "$current_date" --page 1 --page-size 200 -o json
run_dce baseline_bills billing-center bill list-bills --billing-time-start "$baseline_date" --billing-time-end "$baseline_date" --page 1 --page-size 200 -o json

cat > "$OUTPUT_DIR/README.md" <<EOF
# LLM Gross Margin Evidence

- Host: ${HOST:-default}
- Current: $CURRENT_START ~ $CURRENT_END
- Baseline: $BASELINE_START ~ $BASELINE_END
- Trace: $TRACE

Read the JSON files in this directory, then compute:

1. Revenue from Billing Center bill rows.
2. Token/cache data from API key usage statistics or workspace token endpoints.
3. Model cost from Crane cost config or MaaS model-cost JSON.
4. Ranked margin impact: model cost, tenant mix, cache hit rate, residual.

Use cost_config_search.json and cost_command_catalog.json to find the generated
command for the internal Hydra analysis-center cost config endpoint. Do not
expose the concrete API path in user-facing output. If that endpoint is not
available and MaaS model cost does not cover the model, mark cost attribution
incomplete. Do not infer missing values.
EOF

printf 'Evidence directory: %s\n' "$OUTPUT_DIR"
printf 'Trace: %s\n' "$TRACE"
