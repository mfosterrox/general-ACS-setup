#!/usr/bin/env bash
#
# ACS Central Setup — orchestrates basic-setup for all environments.
#
# Usage:
#   source ~/.bashrc
#   ./install.sh
#
# Prerequisites:
#   - oc (logged in), jq
#   - ROX_API_TOKEN and ROX_CENTRAL_ADDRESS in ~/.bashrc (or environment)
#
# Options:
#   -h, --help      Show this help
#
# Optional skip flags (export before running):
#   SKIP_BASIC_SETUP=1 — do not run basic-setup/install.sh
#   SKIP_MONITORING_SETUP=1 — do not run monitoring-setup/install.sh
#   SKIP_DEMO_APPS=1 — do not run demo-apps/install.sh
#   SKIP_PARASOL_INSURANCE=1 — skip only the Parasol Insurance workload
#
# After install: ./verify-setup.sh
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/.setup-logs}"
mkdir -p "${LOG_DIR}"

if [ -f "${REPO_ROOT}/setup-rerun-hint.sh" ]; then
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/setup-rerun-hint.sh"
    setup_rerun_register "${BASH_SOURCE[0]}" "$@"
fi

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

validate_api_token() {
    local central_url="${ROX_CENTRAL_ADDRESS:-}"
    local token="${ROX_API_TOKEN:-}"
    [ -z "${central_url}" ] || [ -z "${token}" ] && return 1

    local http_code
    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        "${central_url}/v1/auth/status" 2>/dev/null || echo "000")
    [ "${http_code}" = "200" ]
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1 (use -h for help)"
                exit 1
                ;;
            *)
                print_error "Unexpected argument: $1 (this script takes no positional arguments)"
                exit 1
                ;;
        esac
    done

    print_step "ACS Central Setup"
    echo ""

    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found"
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into a cluster. Run: oc login"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_error "jq is required. Install jq and retry."
        exit 1
    fi

    print_info "Loading variables from ~/.bashrc..."
    export_bashrc_vars || true

    RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
    export RHACS_NAMESPACE

    if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
        print_info "ROX_CENTRAL_ADDRESS not set; attempting discovery from cluster..."
        ROX_CENTRAL_ADDRESS=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || true)
        export ROX_CENTRAL_ADDRESS
    fi

    if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
        print_error "ROX_CENTRAL_ADDRESS is required. Set it in ~/.bashrc or ensure route 'central' exists in ${RHACS_NAMESPACE}"
        exit 1
    fi

    if [ -z "${ROX_API_TOKEN:-}" ] || [ ${#ROX_API_TOKEN} -lt 20 ]; then
        print_error "ROX_API_TOKEN is required in ~/.bashrc (minimum 20 characters)"
        print_error "Add: export ROX_API_TOKEN=\"<your-admin-api-token>\""
        exit 1
    fi

    if ! validate_api_token; then
        print_error "ROX_API_TOKEN validation failed against ${ROX_CENTRAL_ADDRESS}"
        exit 1
    fi
    print_info "✓ ROX_API_TOKEN validated"

    export GRPC_ENFORCE_ALPN_ENABLED="${GRPC_ENFORCE_ALPN_ENABLED:-false}"
    export RHACS_DEFAULT_VERSION="${RHACS_DEFAULT_VERSION:-4.10}"
    export RHACS_VERSION="${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}"
    export RHACS_OPERATOR_CHANNEL="${RHACS_OPERATOR_CHANNEL:-stable}"
    export RHACS_CONSOLE_PLUGIN_NAME="${RHACS_CONSOLE_PLUGIN_NAME:-advanced-cluster-security}"
    export RHACS_ENSURE_CONSOLE_PLUGIN="${RHACS_ENSURE_CONSOLE_PLUGIN:-1}"
    export ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE RHACS_ROUTE_NAME

    echo ""
    print_step "Setup (logs under ${LOG_DIR})..."
    echo ""

    if [ "${SKIP_BASIC_SETUP:-0}" != "1" ]; then
        print_step "Running basic-setup"
        local basic_log="${LOG_DIR}/basic-setup.log"
        print_info "Streaming output here and to ${basic_log}"
        set +e
        (
            cd "${REPO_ROOT}"
            exec bash "${REPO_ROOT}/basic-setup/install.sh"
        ) 2>&1 | tee "${basic_log}"
        local basic_ec="${PIPESTATUS[0]}"
        set -e
        if [ "${basic_ec}" -ne 0 ]; then
            print_error "✗ basic-setup failed (exit ${basic_ec}); see ${basic_log}"
            print_info "To rerun: cd \"${REPO_ROOT}\" && bash basic-setup/install.sh"
            exit 1
        fi
        print_info "✓ basic-setup completed (log: ${basic_log})"
    else
        print_info "Skipping basic-setup (SKIP_BASIC_SETUP=1)"
    fi

    if [ "${SKIP_MONITORING_SETUP:-0}" != "1" ]; then
        print_step "Running monitoring-setup"
        local monitoring_log="${LOG_DIR}/monitoring-setup.log"
        print_info "Streaming output here and to ${monitoring_log}"
        set +e
        (
            cd "${REPO_ROOT}"
            exec bash "${REPO_ROOT}/monitoring-setup/install.sh"
        ) 2>&1 | tee "${monitoring_log}"
        local monitoring_ec="${PIPESTATUS[0]}"
        set -e
        if [ "${monitoring_ec}" -ne 0 ]; then
            print_error "✗ monitoring-setup failed (exit ${monitoring_ec}); see ${monitoring_log}"
            print_info "To rerun: cd \"${REPO_ROOT}\" && bash monitoring-setup/install.sh"
            exit 1
        fi
        print_info "✓ monitoring-setup completed (log: ${monitoring_log})"
    else
        print_info "Skipping monitoring-setup (SKIP_MONITORING_SETUP=1)"
    fi

    if [ "${SKIP_DEMO_APPS:-0}" != "1" ]; then
        print_step "Running demo-apps"
        local demo_log="${LOG_DIR}/demo-apps.log"
        print_info "Streaming output here and to ${demo_log}"
        set +e
        (
            cd "${REPO_ROOT}"
            exec bash "${REPO_ROOT}/demo-apps/install.sh"
        ) 2>&1 | tee "${demo_log}"
        local demo_ec="${PIPESTATUS[0]}"
        set -e
        if [ "${demo_ec}" -ne 0 ]; then
            print_error "✗ demo-apps failed (exit ${demo_ec}); see ${demo_log}"
            print_info "To rerun: cd \"${REPO_ROOT}\" && bash demo-apps/install.sh"
            exit 1
        fi
        print_info "✓ demo-apps completed (log: ${demo_log})"
    else
        print_info "Skipping demo-apps (SKIP_DEMO_APPS=1)"
    fi

    echo ""
    print_info "======================================"
    print_info "ACS Central Setup finished"
    print_info "======================================"
    print_info "Central URL: ${ROX_CENTRAL_ADDRESS}"
    print_info "Next step:   ./verify-setup.sh"
    print_info ""
}

main "$@"
