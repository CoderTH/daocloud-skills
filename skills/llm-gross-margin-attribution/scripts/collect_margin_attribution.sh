#!/bin/sh
set -eu

HOST=""
CURRENT_START=""
CURRENT_END=""
BASELINE_START=""
BASELINE_END=""
WORKSPACE_IDS=""
BILLING_USERNAMES=""
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  collect_margin_attribution.sh \
    --hostname <dce-host> \
    --current-start <RFC3339> --current-end <RFC3339> \
    --baseline-start <RFC3339> --baseline-end <RFC3339> \
    [--workspace-ids <id[,id...]>] \
    [--billing-usernames <username[,username,...]>] \
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
    --workspace-ids) need_value "$@"; WORKSPACE_IDS="$2"; shift 2 ;;
    --billing-usernames) need_value "$@"; BILLING_USERNAMES="$2"; shift 2 ;;
    --output-dir) need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$CURRENT_START" ] || { echo "--current-start required" >&2; exit 2; }
[ -n "$CURRENT_END" ] || { echo "--current-end required" >&2; exit 2; }
[ -n "$BASELINE_START" ] || { echo "--baseline-start required" >&2; exit 2; }
[ -n "$BASELINE_END" ] || { echo "--baseline-end required" >&2; exit 2; }

date_part() {
  printf '%s\n' "$1" | sed 's/T.*//'
}

to_unix() {
  value="$1"
  normalized="$(printf '%s\n' "$value" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')"
  if epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null)"; then
    printf '%s\n' "$epoch"
    return 0
  fi
  date -d "$value" '+%s'
}

if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-margin-evidence-XXXXXX")"
fi
mkdir -p "$OUTPUT_DIR"
TRACE="$OUTPUT_DIR/trace.tsv"
: > "$TRACE"

if [ -n "$HOST" ]; then
  export DCE_HOST="$HOST"
fi

current_date="$(date_part "$CURRENT_START")"
baseline_date="$(date_part "$BASELINE_START")"
current_start_unix="$(to_unix "$CURRENT_START")"
current_end_unix="$(to_unix "$CURRENT_END")"
baseline_start_unix="$(to_unix "$BASELINE_START")"
baseline_end_unix="$(to_unix "$BASELINE_END")"

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

run_dce auth_status auth status
run_dce workspaces global-management workspace list-workspaces --page 1 --page-size 200 -o json

if [ -z "$WORKSPACE_IDS" ]; then
  workspace_table="$OUTPUT_DIR/workspaces.table"
  workspace_table_err="$OUTPUT_DIR/workspaces.table.err"
  if dce global-management workspace list-workspaces --page 1 --page-size 200 >"$workspace_table" 2>"$workspace_table_err"; then
    printf '%s\t%s\t%s\n' "workspaces_table" "ok" "dce global-management workspace list-workspaces --page 1 --page-size 200" >> "$TRACE"
    WORKSPACE_IDS="$(awk 'NR > 1 && $2 ~ /^[0-9]+$/ {if (ids != "") ids = ids ","; ids = ids $2} END {print ids}' "$workspace_table")"
  else
    printf '%s\t%s\t%s\n' "workspaces_table" "failed" "dce global-management workspace list-workspaces --page 1 --page-size 200" >> "$TRACE"
  fi
fi

run_dce model_serving llm-studio modelservingmanagement list-model-serving --page.page-size -1 -o json
run_dce maas_models llm-studio maasservice list-maas-models -o json
run_dce cost_config_search search "analysis-center cost mock config" --json
run_dce cost_command_catalog commands --include-hidden --json
run_dce current_usage llm-studio apikeymanagement get-api-key-usage-statistics2 --start-time "$CURRENT_START" --end-time "$CURRENT_END" --period TIME_PERIOD_DAY -o json
run_dce baseline_usage llm-studio apikeymanagement get-api-key-usage-statistics2 --start-time "$BASELINE_START" --end-time "$BASELINE_END" --period TIME_PERIOD_DAY -o json
# Prefer LLM Studio workspace user-usage rows for the user candidate set. The
# endpoint is workspace-mode only on some installations, so keep failures as
# evidence and let the analysis stage fall back to query-bills identities.
if [ -n "$WORKSPACE_IDS" ]; then
  old_ifs="$IFS"
  IFS=,
  for workspace_id in $WORKSPACE_IDS; do
    [ -n "$workspace_id" ] || continue
    run_dce "current_ws_users_$workspace_id" llm-studio wsdashboardmanagement list-ws-user-token-usage \
      --workspace "$workspace_id" \
      --start-time "$CURRENT_START" --end-time "$CURRENT_END" \
      --page.page 1 --page.page-size -1 -o json
    run_dce "baseline_ws_users_$workspace_id" llm-studio wsdashboardmanagement list-ws-user-token-usage \
      --workspace "$workspace_id" \
      --start-time "$BASELINE_START" --end-time "$BASELINE_END" \
      --page.page 1 --page.page-size -1 -o json
  done
  IFS="$old_ifs"
fi

# Leopard requires either username or workspace-id. Query each discovered
# username separately so productName aggregation is attributable to a user.
if [ -n "$BILLING_USERNAMES" ]; then
  old_ifs="$IFS"
  IFS=,
  for username in $BILLING_USERNAMES; do
    [ -n "$username" ] || continue
    safe_username="$(printf '%s' "$username" | sed 's/[^A-Za-z0-9_.-]/_/g')"
    run_dce "current_bill_aggregation_user_$safe_username" billing-center bill get-account-bill-aggregation \
      --username "$username" \
      --start-time "$current_start_unix" --end-time "$current_end_unix" -o json
    run_dce "baseline_bill_aggregation_user_$safe_username" billing-center bill get-account-bill-aggregation \
      --username "$username" \
      --start-time "$baseline_start_unix" --end-time "$baseline_end_unix" -o json
  done
  IFS="$old_ifs"
else
  printf '%s\n' '{"items":[]}' > "$OUTPUT_DIR/current_bill_aggregation.json"
  printf '%s\n' '{"items":[]}' > "$OUTPUT_DIR/baseline_bill_aggregation.json"
  printf '%s\t%s\t%s\n' "bill_aggregation_by_user" "skipped" "billing usernames unavailable; inspect LLM Studio user-usage evidence or query-bills identities" >> "$TRACE"
fi

printf '%s\n' '{"items":[]}' > "$OUTPUT_DIR/current_bill_aggregation.json"
printf '%s\n' '{"items":[]}' > "$OUTPUT_DIR/baseline_bill_aggregation.json"
printf '%s\t%s\t%s\n' "bill_aggregation_account_reconciliation" "skipped" "sum per-user aggregation files instead" >> "$TRACE"
run_dce current_bills billing-center bill query-bills \
  --set-str "start=$current_date" \
  --set-str "end=$current_date" \
  --set page=1 \
  --set pageSize=200 \
  -o json
run_dce baseline_bills billing-center bill query-bills \
  --set-str "start=$baseline_date" \
  --set-str "end=$baseline_date" \
  --set page=1 \
  --set pageSize=200 \
  -o json

cat > "$OUTPUT_DIR/README.md" <<EOF
# LLM Gross Margin Evidence

- Host: ${HOST:-default}
- Current: $CURRENT_START ~ $CURRENT_END
- Baseline: $BASELINE_START ~ $BASELINE_END
- Workspace IDs: $WORKSPACE_IDS
- Billing usernames: $BILLING_USERNAMES
- Trace: $TRACE

Read the JSON files in this directory, then compute:

1. Discover active users from current_ws_users_*.json and
   baseline_ws_users_*.json when the LLM Studio workspace-mode API succeeds.
   Then use current_bill_aggregation_user_*.json and
   baseline_bill_aggregation_user_*.json for per-user revenue grouped by
   productName and sum those files for the account total.
   current_bill_aggregation.json and baseline_bill_aggregation.json are empty
   placeholders because no username-free aggregation is valid.
   If the workspace user API is unavailable, use userId/username from
   current_bills.json and baseline_bills.json as the documented fallback.
2. Token/cache data from API key usage statistics or workspace token endpoints.
3. Model cost from Crane cost config or MaaS model-cost JSON.
4. Ranked margin impact: model cost, workspace/tenant/user mix, cache hit
   rate, residual. Use workspace identity when present; otherwise fall back to
   user identity, and treat missing workspace identity as unbound billing.

Use cost_config_search.json and cost_command_catalog.json to find the generated
command for the internal Hydra analysis-center cost config endpoint. Do not
expose the concrete API path in user-facing output. If that endpoint is not
available and MaaS model cost does not cover the model, mark cost attribution
incomplete. Do not infer missing values.
EOF

printf 'Evidence directory: %s\n' "$OUTPUT_DIR"
printf 'Trace: %s\n' "$TRACE"
