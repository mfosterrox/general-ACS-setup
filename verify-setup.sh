#!/usr/bin/env bash
#
# Verify ACS Central setup (basic-setup scripts).
#
# Usage:
#   source ~/.bashrc
#   ./verify-setup.sh
#
# Requires: ROX_API_TOKEN in ~/.bashrc or environment
#
# Skip section:
#   VERIFY_SKIP_BASIC=1 ./verify-setup.sh
#   SKIP_BASIC_SETUP=1 ./verify-setup.sh
#   VERIFY_SKIP_MONITORING=1 ./verify-setup.sh
#   SKIP_MONITORING_SETUP=1 ./verify-setup.sh
#
# Exit: 0 = no failures (warnings allowed); 1 = one or more checks failed.
# --- end help ---

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
print_ok() { echo -e "  ${GREEN}✓${NC} $*"; }
print_fail() { echo -e "  ${RED}✗${NC} $*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${REPO_ROOT}/setup-rerun-hint.sh" ]; then
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/setup-rerun-hint.sh"
    setup_rerun_register "${BASH_SOURCE[0]}" "$@"
fi

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
FAILURES=0
WARNINGS=0
FAIL_BASIC=0
FAIL_MONITORING=0

usage() {
    sed -n '2,/^# --- end help ---$/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^--- end help ---$/d'
}

export_bashrc_vars() {
    local vars=(ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE RHACS_ROUTE_NAME)
    [ ! -f ~/.bashrc ] && return 0

    for var in "${vars[@]}"; do
        local line
        line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            [[ "$line" =~ ^export[[:space:]]+ ]] || line="export $line"
            eval "$line" 2>/dev/null || true
        fi
    done
}

skip_section() {
    local vv="$1"
    local iv="$2"
    if [ "${!vv:-0}" = "1" ] || [ "${!iv:-0}" = "1" ]; then
        print_info "Skipping basic-setup (${vv}=1 or ${iv}=1)"
        return 0
    fi
    return 1
}

get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo ""
}

verify_basic() {
    print_step "basic-setup"
    local failed=0

    if ! oc get deployment central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_fail "Deployment 'central' not found in ${RHACS_NAMESPACE}"
        return 1
    fi
    print_ok "Deployment central exists"

    local ready desired
    ready=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then
        print_ok "Central readyReplicas=${ready} (desired ${desired})"
    else
        print_fail "Central not ready (readyReplicas=${ready}, desired ${desired})"
        failed=1
    fi

    if oc get route central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_ok "Route central exists"
    else
        print_warn "Route central not found (non-standard install?)"
        WARNINGS=$((WARNINGS + 1))
    fi

    if oc get securedcluster -n "${RHACS_NAMESPACE}" -o name &>/dev/null; then
        print_ok "SecuredCluster CR present"
    else
        print_warn "No SecuredCluster in ${RHACS_NAMESPACE}"
        WARNINGS=$((WARNINGS + 1))
    fi

    local plugin_name="${RHACS_CONSOLE_PLUGIN_NAME:-advanced-cluster-security}"
    if oc get consoleplugin "${plugin_name}" &>/dev/null; then
        print_ok "ConsolePlugin CR '${plugin_name}' exists"
        local enabled_plugins
        enabled_plugins=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
        if echo "${enabled_plugins}" | tr ' ' '\n' | grep -qx "${plugin_name}"; then
            print_ok "RHACS Console security plugin enabled in OpenShift Console"
        else
            print_warn "ConsolePlugin exists but '${plugin_name}' not in consoles.operator.openshift.io spec.plugins"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        print_warn "ConsolePlugin '${plugin_name}' not found (requires RHACS 4.10+ on channel stable)"
        WARNINGS=$((WARNINGS + 1))
    fi

    if oc get ds collector -n "${RHACS_NAMESPACE}" &>/dev/null; then
        local collector_networks
        collector_networks=$(oc get ds collector -n "${RHACS_NAMESPACE}" -o json 2>/dev/null | jq -r '
            .spec.template.spec.containers[]
            | select(.name == "collector")
            | .env[]?
            | select(.name == "ROX_NON_AGGREGATED_NETWORKS")
            | .value
        ' 2>/dev/null | head -1 || echo "")
        if [ -n "${collector_networks}" ]; then
            print_ok "Collector ROX_NON_AGGREGATED_NETWORKS=${collector_networks}"
        else
            print_warn "Collector ROX_NON_AGGREGATED_NETWORKS not set (network graph may miss non-RFC1918 CIDRs)"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    if oc get csv -n openshift-compliance -o name 2>/dev/null | grep -q compliance-operator; then
        print_ok "Compliance Operator CSV present in openshift-compliance"
    elif oc get deployment compliance-operator -n openshift-compliance &>/dev/null; then
        print_ok "Compliance Operator deployment present"
    else
        print_warn "Compliance Operator not found in openshift-compliance"
        WARNINGS=$((WARNINGS + 1))
    fi

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_fail "ROX_API_TOKEN unset — required for API verification"
        return 1
    fi

    local base
    base=$(get_central_url)
    if [ -z "${base}" ]; then
        print_fail "Could not determine Central URL"
        return 1
    fi

    local auth_status
    auth_status=$(curl -k -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${ROX_API_TOKEN}" \
        "${base}/v1/auth/status" 2>/dev/null || echo "000")
    if [ "${auth_status}" = "200" ]; then
        print_ok "RHACS API auth/status OK"
    else
        print_fail "RHACS API auth/status returned ${auth_status}"
        failed=1
    fi

    local config_json
    config_json=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "${base}/v1/config" 2>/dev/null || echo "")
    if echo "${config_json}" | jq -e '.config' &>/dev/null; then
        print_ok "RHACS config API reachable"
    else
        print_warn "Could not read RHACS config via API"
        WARNINGS=$((WARNINGS + 1))
    fi

    local schedules_json
    schedules_json=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" \
        "${base}/v2/compliance/scan/configurations" 2>/dev/null || echo "")
    if echo "${schedules_json}" | jq -e '.configurations' &>/dev/null; then
        local count
        count=$(echo "${schedules_json}" | jq '.configurations | length' 2>/dev/null || echo "0")
        if [ "${count:-0}" -ge 1 ] 2>/dev/null; then
            print_ok "Compliance scan configurations present (${count})"
        else
            print_warn "No compliance scan configurations found"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        print_warn "Could not list compliance scan configurations via API"
        WARNINGS=$((WARNINGS + 1))
    fi

    return "${failed}"
}

verify_monitoring() {
    print_step "monitoring-setup"
    local failed=0
    local ms_name="sample-stackrox-monitoring-stack"
    local scrape_name="sample-stackrox-scrape-config"
    local prom_sts default_sts
    default_sts="${ms_name}-prometheus"
    prom_sts=$(oc get sts -n "${RHACS_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -F "${ms_name}" | grep -i prometheus | head -1)
    if [ -z "${prom_sts}" ]; then
        prom_sts=$(oc get sts -n "${RHACS_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i prometheus | head -1)
    fi
    if [ -z "${prom_sts}" ]; then
        prom_sts="${default_sts}"
    fi

    if oc get monitoringstack "${ms_name}" -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_ok "MonitoringStack ${ms_name} exists in ${RHACS_NAMESPACE}"
    else
        print_fail "MonitoringStack not found (expected name ${ms_name})"
        failed=1
    fi

    if oc get scrapeconfig "${scrape_name}" -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_ok "ScrapeConfig ${scrape_name} exists in ${RHACS_NAMESPACE}"
    else
        print_fail "ScrapeConfig not found (expected name ${scrape_name})"
        failed=1
    fi

    if oc get "statefulset/${prom_sts}" -n "${RHACS_NAMESPACE}" &>/dev/null; then
        local ready desired
        ready=$(oc get "statefulset/${prom_sts}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired=$(oc get "statefulset/${prom_sts}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "${desired:-0}" -ge 1 ] 2>/dev/null && [ "${ready:-0}" -ge "${desired}" ] 2>/dev/null; then
            print_ok "Prometheus StatefulSet ${prom_sts} ready (readyReplicas=${ready}, desired=${desired})"
        else
            print_warn "Prometheus StatefulSet ${prom_sts} not fully ready (readyReplicas=${ready:-?}, desired=${desired:-?})"
            WARNINGS=$((WARNINGS + 1))
        fi
    elif oc get pods -n "${RHACS_NAMESPACE}" -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | grep -q .; then
        print_ok "Prometheus pod(s) present (label app.kubernetes.io/name=prometheus)"
    else
        print_warn "No Prometheus workload found — COO may still be reconciling"
        WARNINGS=$((WARNINGS + 1))
    fi

    if [ -n "${ROX_API_TOKEN:-}" ]; then
        local base providers
        base=$(get_central_url)
        if [ -n "${base}" ]; then
            providers=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "${base}/v1/authProviders" 2>/dev/null || echo "")
            if echo "${providers}" | jq -e '.authProviders[] | select(.name=="Monitoring")' &>/dev/null; then
                print_ok "RHACS auth provider 'Monitoring' exists"
            else
                print_warn "Auth provider 'Monitoring' not found (monitoring-setup/03 may not have completed)"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        print_warn "ROX_API_TOKEN unset — skipping Monitoring auth provider API check"
        WARNINGS=$((WARNINGS + 1))
    fi

    return "${failed}"
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    echo ""
    print_step "ACS Central Setup — verify"
    echo ""

    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found"
        setup_rerun_hint_print
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into a cluster. Run: oc login"
        setup_rerun_hint_print
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_error "jq is required for API checks"
        setup_rerun_hint_print
        exit 1
    fi

    export_bashrc_vars || true

    if skip_section "VERIFY_SKIP_BASIC" "SKIP_BASIC_SETUP"; then
        :
    else
        verify_basic || {
            FAILURES=$((FAILURES + 1))
            FAIL_BASIC=1
        }
    fi

    echo ""
    if skip_section "VERIFY_SKIP_MONITORING" "SKIP_MONITORING_SETUP"; then
        :
    else
        verify_monitoring || {
            FAILURES=$((FAILURES + 1))
            FAIL_MONITORING=1
        }
    fi

    echo ""
    print_step "Summary"
    if [ "${FAILURES}" -eq 0 ]; then
        print_ok "No failed checks (${WARNINGS} warning(s))"
        exit 0
    fi
    print_fail "${FAILURES} section(s) had failures — review messages above"
    if [ "${FAIL_BASIC}" = "1" ]; then
        print_info "To rerun setup: cd \"${REPO_ROOT}\" && bash install.sh"
    fi
    print_info "To rerun verifier: cd \"${REPO_ROOT}\" && bash verify-setup.sh"
    exit 1
}

main "$@"
