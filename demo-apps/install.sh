#!/bin/bash
#
# Deploy optional demo workloads for ACS environments.
#
# Usage:
#   bash demo-apps/install.sh
#
# Skip:
#   SKIP_DEMO_APPS=1 or SKIP_PARASOL_INSURANCE=1
#
# Overrides:
#   PARASOL_IMAGE          (default: quay.io/jfalkner1/parasol-insurance:latest)
#   PARASOL_NAMESPACE      (default: parasol-insurance)
#   PARASOL_CONTAINER_PORT (default: 9090)
#   PARASOL_CREATE_ROUTE   (default: 1)
#

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ACS_SETUP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${_ACS_SETUP_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

PARASOL_IMAGE="${PARASOL_IMAGE:-quay.io/jfalkner1/parasol-insurance:latest}"
PARASOL_NAMESPACE="${PARASOL_NAMESPACE:-parasol-insurance}"
PARASOL_CONTAINER_PORT="${PARASOL_CONTAINER_PORT:-9090}"
PARASOL_CREATE_ROUTE="${PARASOL_CREATE_ROUTE:-1}"

deploy_parasol_insurance() {
    local manifest_dir="${SCRIPT_DIR}/parasol-insurance"
    local manifest="${manifest_dir}/k8s.yaml"

    if [ ! -f "${manifest}" ]; then
        error "Manifest not found: ${manifest}"
        return 1
    fi

    step "Deploying Parasol Insurance (${PARASOL_IMAGE})..."

    oc apply -f "${manifest}"

    oc set image "deployment/parasol-insurance" \
        "parasol-insurance=${PARASOL_IMAGE}" \
        -n "${PARASOL_NAMESPACE}" >/dev/null

    if [ "${PARASOL_CONTAINER_PORT}" != "9090" ]; then
        oc patch deployment parasol-insurance -n "${PARASOL_NAMESPACE}" --type=json -p="[
            {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/ports/0/containerPort\",\"value\":${PARASOL_CONTAINER_PORT}},
            {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/httpGet/port\",\"value\":\"http\"},
            {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/httpGet/port\",\"value\":\"http\"}
        ]" >/dev/null 2>&1 || warn "Could not patch container port to ${PARASOL_CONTAINER_PORT}"
    fi

    if [ "${PARASOL_CREATE_ROUTE}" != "1" ]; then
        oc delete route parasol-insurance -n "${PARASOL_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    fi

    log "Waiting for deployment rollout..."
    if ! oc rollout status deployment/parasol-insurance -n "${PARASOL_NAMESPACE}" --timeout=300s; then
        error "Parasol Insurance deployment did not become ready"
        oc get pods -n "${PARASOL_NAMESPACE}" -o wide 2>/dev/null || true
        return 1
    fi

    log "✓ Parasol Insurance is ready in namespace ${PARASOL_NAMESPACE}"

    if oc get route parasol-insurance -n "${PARASOL_NAMESPACE}" &>/dev/null; then
        local url
        url=$(oc get route parasol-insurance -n "${PARASOL_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
        if [ -n "${url}" ]; then
            log "Route: ${url}"
        fi
    fi

    return 0
}

main() {
    if [ "${SKIP_DEMO_APPS:-0}" = "1" ] || [ "${SKIP_PARASOL_INSURANCE:-0}" = "1" ]; then
        log "Skipping demo apps (SKIP_DEMO_APPS=${SKIP_DEMO_APPS:-0}, SKIP_PARASOL_INSURANCE=${SKIP_PARASOL_INSURANCE:-0})"
        exit 0
    fi

    if ! oc whoami &>/dev/null; then
        error "Not logged into a cluster (oc whoami failed)"
        exit 1
    fi

    echo ""
    log "Demo Applications"
    log "================="
    echo ""

    deploy_parasol_insurance

    echo ""
    log "Check status:"
    log "  oc get pods,route -n ${PARASOL_NAMESPACE}"
    echo ""
}

main "$@"
