#!/bin/bash
#
# ACS Central Setup Script
#
# Usage:
#   ./install.sh
#
# Prerequisites (in ~/.bashrc or environment):
#   ROX_API_TOKEN       - Admin-scoped API token for RHACS Central
#   ROX_CENTRAL_ADDRESS - Full URL to RHACS Central (auto-detected from cluster if missing)
#
# The script checks for required variables in this order:
#   1. Current environment variables
#   2. Variables defined in ~/.bashrc
#   3. Auto-detection from cluster (ROX_CENTRAL_ADDRESS, RHACS_NAMESPACE)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SCRIPT_DIR}"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${PROJECT_ROOT}/setup-rerun-hint.sh" ]; then
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/setup-rerun-hint.sh"
    setup_rerun_register "${BASH_SOURCE[0]}" "$@"
fi

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

get_rox_endpoint() {
    local url="${ROX_CENTRAL_ADDRESS:-}"
    echo "${url#https://}"
}

# Validate a downloaded roxctl without relying on the `file` utility (not always installed).
validate_roxctl_binary() {
    local bin_path="$1"
    [ -s "${bin_path}" ] || return 1
    chmod +x "${bin_path}"
    "${bin_path}" version >/dev/null 2>&1
}

try_download_roxctl() {
    local url="$1"
    local dest="$2"
    local use_insecure="${3:-false}"
    local -a curl_opts=(-L -f -s -S --connect-timeout 30 --max-time 300 -o "${dest}")

    if [ "${use_insecure}" = "true" ]; then
        curl_opts=(-k "${curl_opts[@]}")
    fi

    rm -f "${dest}"
    if curl "${curl_opts[@]}" "${url}" 2>/dev/null && validate_roxctl_binary "${dest}"; then
        return 0
    fi

    rm -f "${dest}"
    return 1
}

install_roxctl() {
    print_step "Installing roxctl CLI"
    echo "================================================================"

    if command -v roxctl >/dev/null 2>&1; then
        if roxctl version >/dev/null 2>&1; then
            local version
            version=$(roxctl version 2>/dev/null | grep "roxctl version" || echo "installed")
            print_info "✓ roxctl already installed and working: ${version}"
            return 0
        else
            print_warn "roxctl exists but appears corrupted, reinstalling..."
            local roxctl_path
            roxctl_path=$(which roxctl)
            if [ -w "${roxctl_path}" ]; then
                rm -f "${roxctl_path}"
            elif [ -f ~/.local/bin/roxctl ]; then
                rm -f ~/.local/bin/roxctl
            fi
        fi
    fi

    print_info "Downloading roxctl..."

    local os arch temp_dir download_success
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) print_error "Unsupported architecture: ${arch}"; setup_rerun_hint_print; exit 1 ;;
    esac

    temp_dir=$(mktemp -d)
    download_success=false

    print_info "Attempting download from Red Hat mirror..."
    local mirror_url="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
    if try_download_roxctl "${mirror_url}" "${temp_dir}/roxctl"; then
        print_info "✓ Successfully downloaded from Red Hat mirror"
        download_success=true
    else
        print_warn "Failed to download or validate roxctl from Red Hat mirror"
    fi

    if [ "$download_success" = false ]; then
        print_info "Attempting download from RHACS Central..."
        local central_base="${ROX_CENTRAL_ADDRESS:-}"
        if [ -z "${central_base}" ]; then
            local central_route
            central_route=$(oc get route central -n "${RHACS_NAMESPACE:-stackrox}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
            if [ -n "${central_route}" ]; then
                central_base="https://${central_route}"
            fi
        fi

        if [ -n "${central_base}" ]; then
            local roxctl_url="${central_base%/}/api/cli/download/roxctl-${os}"
            print_info "Downloading from: ${roxctl_url}"

            if try_download_roxctl "${roxctl_url}" "${temp_dir}/roxctl" "true"; then
                print_info "✓ Successfully downloaded from RHACS Central"
                download_success=true
            else
                print_warn "Failed to download or validate roxctl from RHACS Central"
            fi
        else
            print_warn "RHACS Central URL not available for roxctl download"
        fi
    fi

    if [ "$download_success" = false ]; then
        print_error "Failed to download roxctl from all sources"
        rm -rf "${temp_dir}"
        setup_rerun_hint_print
        print_error "Please install roxctl manually:"
        print_error "  curl -L -o /tmp/roxctl https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
        print_error "  chmod +x /tmp/roxctl"
        print_error "  /tmp/roxctl version"
        print_error "  sudo mv /tmp/roxctl /usr/local/bin/roxctl"
        exit 1
    fi

    if [ -w "/usr/local/bin" ]; then
        mv "${temp_dir}/roxctl" /usr/local/bin/roxctl
        print_info "✓ roxctl installed to /usr/local/bin/roxctl"
    else
        mkdir -p ~/.local/bin
        mv "${temp_dir}/roxctl" ~/.local/bin/roxctl
        print_info "✓ roxctl installed to ~/.local/bin/roxctl"

        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            export PATH="$HOME/.local/bin:$PATH"
            print_info "Added ~/.local/bin to PATH for this session"
            if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc 2>/dev/null; then
                print_info "Persisting ~/.local/bin in ~/.bashrc"
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
            fi
        fi
    fi

    rm -rf "${temp_dir}"

    if command -v roxctl >/dev/null 2>&1; then
        local version
        version=$(roxctl version 2>/dev/null | grep "roxctl version" || echo "installed")
        print_info "✓ roxctl successfully installed: ${version}"
    elif [ -x "$HOME/.local/bin/roxctl" ]; then
        export PATH="$HOME/.local/bin:$PATH"
        local version
        version=$(roxctl version 2>/dev/null | grep "roxctl version" || echo "installed")
        print_info "✓ roxctl successfully installed: ${version}"
    else
        print_warn "roxctl installed but not in current PATH"
        print_info "Please run: source ~/.bashrc"
    fi

    echo ""
}

check_variable() {
    local var_name=$1
    local description=$2

    if grep -q "^export ${var_name}=" ~/.bashrc 2>/dev/null || grep -q "^${var_name}=" ~/.bashrc 2>/dev/null; then
        print_info "Found ${var_name} in ~/.bashrc"
        return 0
    elif [ -n "${!var_name:-}" ]; then
        print_info "Found ${var_name} in current environment"
        return 0
    else
        print_error "${var_name} not found in ~/.bashrc or environment"
        print_warn "Description: ${description}"
        return 1
    fi
}

add_bashrc_vars_from_cluster() {
    local ns="${RHACS_NAMESPACE:-stackrox}"
    local route="${RHACS_ROUTE_NAME:-central}"

    touch ~/.bashrc

    if ! grep -qE "^(export[[:space:]]+)?ROX_CENTRAL_ADDRESS=" ~/.bashrc 2>/dev/null; then
        local url
        url=$(oc get route "${route}" -n "${ns}" -o jsonpath='https://{.spec.host}' 2>/dev/null) || true
        if [ -n "${url}" ]; then
            echo "export ROX_CENTRAL_ADDRESS=\"${url}\"" >> ~/.bashrc
            print_info "Added ROX_CENTRAL_ADDRESS to ~/.bashrc"
        fi
    fi

    if ! grep -qE "^(export[[:space:]]+)?RHACS_NAMESPACE=" ~/.bashrc 2>/dev/null; then
        echo "export RHACS_NAMESPACE=\"${ns}\"" >> ~/.bashrc
        print_info "Added RHACS_NAMESPACE to ~/.bashrc"
    fi

    if ! grep -qE "^(export[[:space:]]+)?RHACS_ROUTE_NAME=" ~/.bashrc 2>/dev/null; then
        echo "export RHACS_ROUTE_NAME=\"${route}\"" >> ~/.bashrc
        print_info "Added RHACS_ROUTE_NAME to ~/.bashrc"
    fi
}

export_rhacs_setup_defaults() {
    export RHACS_DEFAULT_VERSION="${RHACS_DEFAULT_VERSION:-4.10}"
    export RHACS_VERSION="${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}"
    export RHACS_OPERATOR_CHANNEL="${RHACS_OPERATOR_CHANNEL:-stable}"
    export RHACS_AUTO_OPERATOR_CHANNEL="${RHACS_AUTO_OPERATOR_CHANNEL:-1}"
    export RHACS_USE_LIVE_CATALOG="${RHACS_USE_LIVE_CATALOG:-1}"
    export RHACS_FIX_ARGOCD_CATALOG_DRIFT="${RHACS_FIX_ARGOCD_CATALOG_DRIFT:-1}"
    export RHACS_OPERATOR_NAMESPACE="${RHACS_OPERATOR_NAMESPACE:-openshift-operators}"
    export RHACS_SUBSCRIPTION_SEARCH_NAMESPACES="${RHACS_SUBSCRIPTION_SEARCH_NAMESPACES:-openshift-operators ${RHACS_NAMESPACE:-stackrox} rhacs-operator}"
    export RHACS_CONSOLE_PLUGIN_NAME="${RHACS_CONSOLE_PLUGIN_NAME:-advanced-cluster-security}"
    export RHACS_ENSURE_CONSOLE_PLUGIN="${RHACS_ENSURE_CONSOLE_PLUGIN:-1}"
}

export_bashrc_vars() {
    local vars=(ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE RHACS_ROUTE_NAME KUBECONFIG GUID CLOUDUSER)
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

# Deprecated fallback: only used when ALLOW_PASSWORD_TOKEN_GEN=1
generate_api_token() {
    local central_url="${ROX_CENTRAL_ADDRESS:-}"
    local password="${ROX_PASSWORD:-}"

    if [ -z "${central_url}" ] || [ -z "${password}" ]; then
        return 1
    fi

    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"

    local response
    response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -u "admin:${password}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"install-script-'$(date +%s)'","roles":["Admin"]}' 2>/dev/null)

    local http_code body token
    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')

    if [ "${http_code}" != "200" ]; then
        return 1
    fi

    token=$(echo "${body}" | jq -r '.token' 2>/dev/null)
    if [ -z "${token}" ] || [ "${token}" = "null" ] || [ ${#token} -lt 20 ]; then
        return 1
    fi

    printf "%s" "${token}"
    return 0
}

validate_api_token() {
    local central_url="${ROX_CENTRAL_ADDRESS:-}"
    local token="${ROX_API_TOKEN:-}"

    if [ -z "${central_url}" ] || [ -z "${token}" ]; then
        return 1
    fi

    local http_code
    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        "${central_url}/v1/auth/status" 2>/dev/null || echo "000")

    if [ "${http_code}" = "200" ]; then
        return 0
    fi
    return 1
}

main() {
    print_info "Starting ACS Central Setup"
    print_info "=========================="
    echo "" >&2

    print_info "Loading variables from ~/.bashrc..."
    export_bashrc_vars || true

    if oc whoami &>/dev/null; then
        print_info "Cluster accessible - populating missing variables from RHACS installation..."
        trap - ERR
        set +e
        add_bashrc_vars_from_cluster || true
        set -euo pipefail
        setup_rerun_restore_trap
        export_bashrc_vars || true
    fi

    print_info "Checking for required variables and credentials..."
    echo ""

    local missing_vars=0

    print_info "Checking ROX_CENTRAL_ADDRESS..."
    if ! check_variable "ROX_CENTRAL_ADDRESS" "RHACS Central URL for API access and roxctl CLI"; then
        missing_vars=$((missing_vars + 1))
    fi

    print_info "Checking ROX_API_TOKEN..."
    if [ -n "${ROX_API_TOKEN:-}" ] && [ "${#ROX_API_TOKEN}" -ge 20 ]; then
        print_info "✓ ROX_API_TOKEN is set"
    else
        if [ "${ALLOW_PASSWORD_TOKEN_GEN:-0}" = "1" ] && [ -n "${ROX_PASSWORD:-}" ]; then
            print_warn "ROX_API_TOKEN not set; ALLOW_PASSWORD_TOKEN_GEN=1 — attempting token generation..."
            local token
            token=$(generate_api_token) || true
            if [ -n "${token}" ] && [ ${#token} -ge 20 ]; then
                export ROX_API_TOKEN="${token}"
                print_info "✓ API token generated via deprecated password fallback"
            else
                print_error "Failed to generate ROX_API_TOKEN from ROX_PASSWORD"
                missing_vars=$((missing_vars + 1))
            fi
        else
            print_error "ROX_API_TOKEN not found or too short (minimum 20 characters)"
            print_error "Add export ROX_API_TOKEN=\"<token>\" to ~/.bashrc before running setup"
            missing_vars=$((missing_vars + 1))
        fi
    fi

    if ! check_variable "RHACS_NAMESPACE" "Namespace where RHACS is installed (default: stackrox)"; then
        print_warn "RHACS_NAMESPACE not set - will use default: stackrox"
        export RHACS_NAMESPACE="stackrox"
    fi
    if ! check_variable "RHACS_ROUTE_NAME" "Name of the RHACS route (default: central)"; then
        print_warn "RHACS_ROUTE_NAME not set - will use default: central"
        export RHACS_ROUTE_NAME="central"
    fi

    export_rhacs_setup_defaults
    print_info "RHACS upgrade defaults: version=${RHACS_VERSION}, operator channel=${RHACS_OPERATOR_CHANNEL}, console plugin=${RHACS_CONSOLE_PLUGIN_NAME}"

    echo ""

    if [ "${missing_vars}" -gt 0 ]; then
        print_error ""
        print_error "Missing ${missing_vars} required variable(s)"
        print_error "Please add the missing variables to ~/.bashrc or export them in your environment"
        print_error ""
        print_error "Required variables:"
        print_error "  - ROX_CENTRAL_ADDRESS"
        print_error "  - ROX_API_TOKEN"
        print_error ""
        setup_rerun_hint_print
        exit 1
    fi

    print_info "Validating ROX_API_TOKEN against RHACS Central..."
    if ! validate_api_token; then
        print_error "ROX_API_TOKEN validation failed (auth/status did not return 200)"
        print_error "Verify the token is valid and has sufficient permissions"
        print_error "Test: curl -k -H \"Authorization: Bearer \$ROX_API_TOKEN\" \"\$ROX_CENTRAL_ADDRESS/v1/auth/status\""
        setup_rerun_hint_print
        exit 1
    fi
    print_info "✓ ROX_API_TOKEN validated"
    print_info ""

    print_info "Configuring gRPC ALPN fix for roxctl..."
    if [ -f ~/.bashrc ] && ! grep -q "GRPC_ENFORCE_ALPN_ENABLED" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo "# Fix for gRPC ALPN enforcement issues with roxctl (https://github.com/grpc/grpc-go/issues/7769)" >> ~/.bashrc
        echo "export GRPC_ENFORCE_ALPN_ENABLED=false" >> ~/.bashrc
        print_info "✓ Added GRPC_ENFORCE_ALPN_ENABLED=false to ~/.bashrc"
    else
        print_info "✓ GRPC_ENFORCE_ALPN_ENABLED already in ~/.bashrc"
    fi
    export GRPC_ENFORCE_ALPN_ENABLED=false
    print_info ""

    if [ ! -d "${SETUP_DIR}" ]; then
        print_error "Setup directory not found: ${SETUP_DIR}"
        setup_rerun_hint_print
        exit 1
    fi

    export_bashrc_vars || true
    export_rhacs_setup_defaults

    print_info "Verifying cluster connectivity..."
    if ! oc whoami &>/dev/null; then
        print_warn "Cannot connect to OpenShift cluster. Some verification steps may fail."
        print_warn "Please ensure KUBECONFIG is set if you need cluster access."
    else
        print_info "Successfully connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    fi
    print_info ""

    install_roxctl

    print_info "Running setup scripts..."
    print_info "========================="

    for script in "${SETUP_DIR}"/[0-9][0-9]-*.sh; do
        if [ -f "${script}" ]; then
            local script_name
            script_name=$(basename "${script}")

            print_info "Executing: ${script_name}"
            if bash "${script}"; then
                print_info "✓ Successfully completed: ${script_name}"
            else
                print_error "✗ Failed: ${script_name}"
                print_info "To rerun: bash \"${script}\""
                exit 1
            fi
            print_info ""
        fi
    done

    print_info ""
    print_info "======================================"
    print_info "ACS Central Setup Complete!"
    print_info "======================================"
    print_info ""
    print_info "Setup Summary:"
    print_info "=============="
    print_info "  ✓ roxctl CLI installed"
    print_info "  ✓ ROX_API_TOKEN validated"
    print_info "  ✓ RHACS installation verified"
    print_info "  ✓ Collector network CIDRs configured"
    print_info "  ✓ Compliance Operator installed"
    print_info "  ✓ RHACS settings configured"
    print_info "  ✓ Compliance scan schedules created"
    print_info ""
    print_info "RHACS Central Access:"
    print_info "====================="
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        print_info "  URL: ${ROX_CENTRAL_ADDRESS}"
    fi
    if [ -n "${RHACS_VERSION:-}" ]; then
        print_info "  Version: ${RHACS_VERSION}"
    fi
    print_info ""
}

main "$@"
