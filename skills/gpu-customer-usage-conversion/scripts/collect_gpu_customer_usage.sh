#!/bin/sh
set -eu

HOST=""
START_DATE=""
END_DATE=""
OUTPUT_DIR=""
CLUSTERS=""
WORKSPACES=""

usage() {
  cat <<'EOF'
Usage:
  collect_gpu_customer_usage.sh \
    --hostname <dce-host> \
    --start <YYYY-MM-DD> \
    --end <YYYY-MM-DD> \
    [--cluster <cluster>]... \
    [--workspace <workspace-id>]... \
    [--output-dir <dir>]

Collects live read-only DCE JSON evidence for judging whether GPU resources
have converted into customer usage. The script does not parse JSON, mutate
resources, recalculate bills, or require non-POSIX dependencies.
EOF
}

need_value() {
  [ "$#" -ge 2 ] || { echo "$1 requires an argument" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname) need_value "$@"; HOST="$2"; shift 2 ;;
    --start) need_value "$@"; START_DATE="$2"; shift 2 ;;
    --end) need_value "$@"; END_DATE="$2"; shift 2 ;;
    --cluster) need_value "$@"; CLUSTERS="${CLUSTERS}
$2"; shift 2 ;;
    --workspace) need_value "$@"; WORKSPACES="${WORKSPACES}
$2"; shift 2 ;;
    --output-dir) need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$START_DATE" ] || { echo "--start required" >&2; exit 2; }
[ -n "$END_DATE" ] || { echo "--end required" >&2; exit 2; }

if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpu-customer-usage-evidence-XXXXXX")"
fi
mkdir -p "$OUTPUT_DIR"
TRACE="$OUTPUT_DIR/trace.tsv"
: > "$TRACE"

if [ -n "$HOST" ]; then
  export DCE_HOST="$HOST"
fi

START_RFC3339="${START_DATE}T00:00:00+08:00"
END_RFC3339="${END_DATE}T23:59:59+08:00"
START_UNIX="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "${START_DATE} 00:00:00 +0800" '+%s' 2>/dev/null || date -d "${START_DATE} 00:00:00 +0800" '+%s')"
END_UNIX="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "${END_DATE} 23:59:59 +0800" '+%s' 2>/dev/null || date -d "${END_DATE} 23:59:59 +0800" '+%s')"

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

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
run_dce product_versions global-management about list-g-product-versions -o json
run_dce workspaces global-management workspace list-workspaces --page 1 --page-size 200 -o json
run_dce clusters container-management cluster list-clusters --page 1 --page-size 200 -o json
run_dce model_serving llm-studio modelservingmanagement list-model-serving --page.page-size -1 -o json
run_dce api_key_usage llm-studio apikeymanagement get-api-key-usage-statistics2 --start-time "$START_RFC3339" --end-time "$END_RFC3339" --period TIME_PERIOD_DAY -o json
run_dce workspace_report operations-management report list-workspaces --start "$START_DATE" --end "$END_DATE" --page 1 --page-size 200 -o json
run_dce namespace_report operations-management report list-namespaces --start "$START_DATE" --end "$END_DATE" --page 1 --page-size 200 -o json
run_dce pod_report operations-management report list-pods --start "$START_DATE" --end "$END_DATE" --page 1 --page-size 200 -o json

printf '%s\n' "$CLUSTERS" | while IFS= read -r cluster; do
  [ -n "$cluster" ] || continue
  safe="$(safe_name "$cluster")"
  run_dce "gpu_devices_$safe" container-management devices list-gpu-devices --cluster "$cluster" -o json
done

printf '%s\n' "$WORKSPACES" | while IFS= read -r ws; do
  [ -n "$ws" ] || continue
  safe="$(safe_name "$ws")"
  run_dce "shared_resources_ws_$safe" global-management workspace list-shared-resources-by-workspace --workspace-id "$ws" -o json
  run_dce "ws_dashboard_summary_$safe" llm-studio wsdashboardmanagement get-ws-dashboard-summary --workspace "$ws" --start-time "$START_RFC3339" --end-time "$END_RFC3339" -o json
  run_dce "ws_user_token_usage_$safe" llm-studio wsdashboardmanagement list-ws-user-token-usage --workspace "$ws" --start-time "$START_RFC3339" --end-time "$END_RFC3339" --page.page-size -1 -o json
  run_dce "ws_instance_token_usage_$safe" llm-studio wsdashboardmanagement list-ws-instance-token-usage --workspace "$ws" --start-time "$START_RFC3339" --end-time "$END_RFC3339" --page.page-size -1 -o json
  run_dce "llm_queues_ws_$safe" llm-studio queuemanagement list-queues2 --workspace "$ws" --page.page-size -1 -o json
  run_dce "ai_lab_queues_ws_$safe" ai-lab queuemanagement list-queues2 --workspace "$ws" --page.page-size -1 -o json
  run_dce "billing_ws_$safe" billing-center bill get-account-bill-aggregation --workspace-id "$ws" --start-time "$START_UNIX" --end-time "$END_UNIX" -o json
done

cat > "$OUTPUT_DIR/README.md" <<EOF
# GPU Customer Usage Evidence

- Host: ${HOST:-default}
- Window: $START_DATE ~ $END_DATE
- LLM Studio time window: $START_RFC3339 ~ $END_RFC3339
- Billing Unix window: $START_UNIX ~ $END_UNIX
- Trace: $TRACE

Read the JSON files in this directory, then judge whether GPU resources have
converted into customer usage by connecting:

1. GPU supply and utilization from cluster/device/report JSON.
2. Workspace/customer carrier data from workspace/shared-resource/queue JSON.
3. Usage from API-key, workspace dashboard, user-token, instance-token, and pod
   report JSON.
4. Billing from Billing Center aggregation JSON. Keep voucher/credit usage
   separate from cash revenue.

If no --cluster was provided, inspect clusters.json and rerun with each GPU
cluster. If no --workspace was provided, inspect workspaces.json and rerun with
workspace ids that need usage and billing evidence.
EOF

printf 'Evidence directory: %s\n' "$OUTPUT_DIR"
printf 'Trace: %s\n' "$TRACE"
