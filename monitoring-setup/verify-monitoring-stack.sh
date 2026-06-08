#!/bin/bash
#
# End-to-end verification: RHACS metrics → Prometheus scrape → Perses resources.
# Run after monitoring-setup/install.sh or standalone.
#
# Optional env:
#   RHACS_NS / RHACS_NAMESPACE (default stackrox)
#   MONITORING_STACK_NAME (default sample-stackrox-monitoring-stack)
#   SCRAPE_CONFIG_NAME (default sample-stackrox-scrape-config)
#   MONITORING_DATA_WAIT_SEC — wait for scrape UP + RHACS series in Prometheus (default 180)
#   MONITORING_VERIFY_POLL_SEC — poll interval (default 15)
#   MONITORING_VERIFY_STRICT=1 — exit 1 on warnings (default 0: fail only critical checks)
#   MONITORING_VERIFY_SKIP_CLIENT_CERT=1 — skip client.crt /metrics check
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

_ACS_SETUP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${_ACS_SETUP_ROOT}/setup-rerun-hint.sh" 2>/dev/null || true
setup_rerun_register "${BASH_SOURCE[0]}" "$@" 2>/dev/null || true

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }
ok() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

RHACS_NS="${RHACS_NS:-${RHACS_NAMESPACE:-stackrox}}"
MONITORING_STACK_NAME="${MONITORING_STACK_NAME:-sample-stackrox-monitoring-stack}"
SCRAPE_CONFIG_NAME="${SCRAPE_CONFIG_NAME:-sample-stackrox-scrape-config}"
PROM_SVC="${MONITORING_STACK_NAME}-prometheus"
SCRAPE_JOB="${SCRAPE_JOB:-sample-stackrox-metrics}"
DATA_WAIT_SEC="${MONITORING_DATA_WAIT_SEC:-180}"
POLL_SEC="${MONITORING_VERIFY_POLL_SEC:-15}"

CRITICAL_FAIL=0
WARN_COUNT=0

load_rox_from_bashrc() {
  [ ! -f ~/.bashrc ] && return 0
  local var line
  for var in ROX_CENTRAL_ADDRESS ROX_API_TOKEN; do
    line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1) || true
    [ -z "$line" ] && continue
    if grep -qE '\$\(|`' <<< "$line"; then
      continue
    fi
    [[ "$line" =~ ^export[[:space:]]+ ]] || line="export $line"
    eval "$line" 2>/dev/null || true
  done
}

normalize_rox_central_address() {
  [ -n "${ROX_CENTRAL_ADDRESS:-}" ] || return 0
  ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS%/}"
  export ROX_CENTRAL_ADDRESS
}

get_prometheus_pod() {
  oc get pods -n "${RHACS_NS}" -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Query Prometheus HTTP API from inside the prometheus container.
prom_api() {
  local path="$1"
  local pod
  pod=$(get_prometheus_pod)
  [ -n "${pod}" ] || return 1
  oc exec -n "${RHACS_NS}" "${pod}" -c prometheus -- \
    wget -qO- "http://127.0.0.1:9090${path}" 2>/dev/null
}

prom_query_value() {
  local query="$1"
  local encoded json
  if command -v jq &>/dev/null; then
    encoded=$(printf '%s' "${query}" | jq -sRr @uri)
  else
    encoded="${query}"
  fi
  json=$(prom_api "/api/v1/query?query=${encoded}") || return 1
  if command -v jq &>/dev/null; then
    echo "${json}" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null
    return 0
  fi
  echo "${json}" | grep -o '"value":\[[^]]*\]' | tail -1
}

scrape_target_health() {
  local job="$1"
  local json
  json=$(prom_api "/api/v1/targets") || return 1
  if ! command -v jq &>/dev/null; then
    echo "${json}" | grep -A2 "${job}" | head -3
    return 0
  fi
  echo "${json}" | jq -r --arg job "${job}" '
    .data.activeTargets[]
    | select(.labels.job == $job)
    | "\(.health)|\(.lastError // "")"
  ' 2>/dev/null | head -1
}

wait_for_scrape_and_data() {
  local elapsed=0 health last_err val
  step "Waiting for Prometheus scrape + RHACS metrics (up to ${DATA_WAIT_SEC}s)..."
  while [ "${elapsed}" -lt "${DATA_WAIT_SEC}" ]; do
    health=""
    last_err=""
    if target_line=$(scrape_target_health "${SCRAPE_JOB}"); then
      health="${target_line%%|*}"
      last_err="${target_line#*|}"
    fi

    if [ "${health}" = "up" ]; then
      val=$(prom_query_value 'sum(rox_central_cfg_total_policies)' 2>/dev/null || true)
      if [ -n "${val}" ] && [ "${val}" != "0" ] && [ "${val}" != "null" ]; then
        ok "Scrape target ${SCRAPE_JOB} is UP; sum(rox_central_cfg_total_policies)=${val}"
        return 0
      fi
      log "  Target UP; waiting for RHACS series in TSDB (${elapsed}s/${DATA_WAIT_SEC}s)..."
    else
      log "  Target ${SCRAPE_JOB}: health=${health:-unknown} ${last_err:+($last_err)} (${elapsed}s/${DATA_WAIT_SEC}s)..."
    fi
    sleep "${POLL_SEC}"
    elapsed=$((elapsed + POLL_SEC))
  done
  return 1
}

step "Monitoring stack verification"
echo "=========================================="
echo ""

load_rox_from_bashrc
normalize_rox_central_address

# --- Cluster resources ---
step "Operator stack CRs and secrets"
if oc get monitoringstack "${MONITORING_STACK_NAME}" -n "${RHACS_NS}" &>/dev/null; then
  ok "MonitoringStack ${MONITORING_STACK_NAME}"
else
  fail "MonitoringStack ${MONITORING_STACK_NAME} missing"
  CRITICAL_FAIL=1
fi

if oc get scrapeconfig "${SCRAPE_CONFIG_NAME}" -n "${RHACS_NS}" &>/dev/null; then
  ok "ScrapeConfig ${SCRAPE_CONFIG_NAME}"
else
  fail "ScrapeConfig ${SCRAPE_CONFIG_NAME} missing"
  CRITICAL_FAIL=1
fi

if oc get secret sample-stackrox-prometheus-tls -n "${RHACS_NS}" &>/dev/null; then
  ok "Secret sample-stackrox-prometheus-tls"
else
  fail "Secret sample-stackrox-prometheus-tls missing (run 01-setup-certificates.sh)"
  CRITICAL_FAIL=1
fi

if oc get secret service-ca -n "${RHACS_NS}" &>/dev/null; then
  if oc get secret service-ca -n "${RHACS_NS}" -o json 2>/dev/null | jq -e '.data["ca.pem"]' &>/dev/null; then
    ok "Secret service-ca (key ca.pem)"
  else
    fail "Secret service-ca missing key ca.pem (ScrapeConfig TLS CA)"
    CRITICAL_FAIL=1
  fi
else
  fail "Secret service-ca missing in ${RHACS_NS}"
  CRITICAL_FAIL=1
fi

PROM_POD=$(get_prometheus_pod)
if [ -n "${PROM_POD}" ]; then
  ready=$(oc get pod "${PROM_POD}" -n "${RHACS_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "${ready}" = "True" ]; then
    ok "Prometheus pod ${PROM_POD} Ready"
  else
    fail "Prometheus pod ${PROM_POD} not Ready"
    CRITICAL_FAIL=1
  fi
else
  fail "No Prometheus pod (label app.kubernetes.io/name=prometheus)"
  CRITICAL_FAIL=1
fi

if oc get "svc/${PROM_SVC}" -n "${RHACS_NS}" &>/dev/null; then
  ok "Service ${PROM_SVC}"
else
  warn "Service ${PROM_SVC} not found"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

echo ""
step "Prometheus scrape configuration"
if [ -n "${PROM_POD}" ]; then
  if oc exec -n "${RHACS_NS}" "${PROM_POD}" -c prometheus -- sh -c \
    'grep -q "sample-stackrox-scrape-config\|central.stackrox" /etc/prometheus/config_out/prometheus.env.yaml 2>/dev/null'; then
    ok "Central scrape job present in Prometheus config"
  else
    fail "Central scrape job not found in Prometheus config"
    CRITICAL_FAIL=1
  fi
fi

echo ""
if [ "${CRITICAL_FAIL}" -eq 0 ]; then
  if ! wait_for_scrape_and_data; then
    fail "Scrape target not UP or no RHACS metrics in Prometheus after ${DATA_WAIT_SEC}s"
    fail "Check: oc port-forward -n ${RHACS_NS} svc/${PROM_SVC} 9090:9090 → http://localhost:9090/targets"
    CRITICAL_FAIL=1
  fi
else
  warn "Skipping Prometheus API checks (prerequisites failed)"
fi

if [ "${CRITICAL_FAIL}" -eq 0 ] && command -v jq &>/dev/null; then
  step "Prometheus sample queries (dashboard panels)"
  pol_val=$(prom_query_value 'sum(rox_central_cfg_total_policies{Enabled="true"})' 2>/dev/null || true)
  if [ -n "${pol_val}" ] && [ "${pol_val}" != "0" ]; then
    ok "sum(rox_central_cfg_total_policies{Enabled=\"true\"}) = ${pol_val}"
  else
    warn "No enabled-policy metric yet (dashboard may show empty policy panels)"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi

  viol_val=$(prom_query_value 'sum(rox_central_policy_violation_namespace_severity)' 2>/dev/null || true)
  if [ -n "${viol_val}" ] && [ "${viol_val}" != "0" ]; then
    ok "sum(rox_central_policy_violation_namespace_severity) = ${viol_val}"
  else
    warn "Policy violation metric is 0 or missing (no violations or still gathering)"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi

  clusters=$(prom_api "/api/v1/label/Cluster/values" 2>/dev/null | jq -r '.data[]? // empty' 2>/dev/null | tr '\n' ' ')
  if [ -n "${clusters}" ]; then
    ok "Prometheus Cluster label values: ${clusters}"
  else
    warn "No Cluster label values — Perses dashboard dropdowns may be empty"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
fi

echo ""
step "Perses / OpenShift console integration"
if oc get uiplugin monitoring -o jsonpath='{.spec.monitoring.perses.enabled}' 2>/dev/null | grep -q true; then
  ok "UIPlugin monitoring: perses.enabled=true"
else
  warn "UIPlugin monitoring missing or perses not enabled"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

if oc get persesdatasource sample-stackrox-datasource -n "${RHACS_NS}" &>/dev/null; then
  ok "PersesDatasource sample-stackrox-datasource"
else
  warn "PersesDatasource sample-stackrox-datasource missing"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

if oc get persesdashboard sample-stackrox-dashboard -n "${RHACS_NS}" &>/dev/null; then
  ok "PersesDashboard sample-stackrox-dashboard"
else
  warn "PersesDashboard sample-stackrox-dashboard missing"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

coo_ns="openshift-cluster-observability-operator"
if oc get namespace "${coo_ns}" -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null | grep -q true; then
  ok "Namespace ${coo_ns} has openshift.io/cluster-monitoring=true"
else
  warn "Label ${coo_ns} with: oc label namespace ${coo_ns} openshift.io/cluster-monitoring=true --overwrite"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ "${MONITORING_VERIFY_SKIP_CLIENT_CERT:-0}" != "1" ] && [ -f "${SCRIPT_DIR}/client.crt" ] && [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
  echo ""
  step "RHACS /metrics (client certificate)"
  rox_count=$(curl -sk --cert "${SCRIPT_DIR}/client.crt" --key "${SCRIPT_DIR}/client.key" \
    "${ROX_CENTRAL_ADDRESS}/metrics" 2>/dev/null | grep -c '^rox_' || true)
  if [ "${rox_count:-0}" -gt 0 ]; then
    ok "Central /metrics exposes ${rox_count} rox_* lines"
  else
    warn "Central /metrics returned no rox_* lines (auth or metrics export)"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
fi

echo ""
echo "=========================================="
if [ "${CRITICAL_FAIL}" -eq 0 ] && [ "${WARN_COUNT}" -eq 0 ]; then
  log "✓ Monitoring stack verification passed"
  log "Console: Observe → Dashboards → RHACS Prometheus Datasource → Advanced Cluster Security / Overview"
  exit 0
fi

if [ "${CRITICAL_FAIL}" -eq 0 ]; then
  warn "Verification completed with ${WARN_COUNT} warning(s) — Prometheus pipeline OK; check Perses/console if dashboard is empty"
  log "Rerun: bash ${SCRIPT_DIR}/verify-monitoring-stack.sh"
  [ "${MONITORING_VERIFY_STRICT:-0}" = "1" ] && exit 1
  exit 0
fi

error "Verification failed (${WARN_COUNT} warning(s))"
log "Rerun: bash ${SCRIPT_DIR}/verify-monitoring-stack.sh"
log "Or full install: bash ${SCRIPT_DIR}/install.sh"
exit 1
