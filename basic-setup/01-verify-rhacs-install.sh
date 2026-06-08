#!/bin/bash

set -euo pipefail

_ACS_SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${_ACS_SETUP_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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

# Default values if not set
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
RHACS_ROUTE_NAME="${RHACS_ROUTE_NAME:-central}"
RHACS_OPERATOR_NAMESPACE="${RHACS_OPERATOR_NAMESPACE:-openshift-operators}"

# Default target: RHACS 4.10. Channel auto-resolves (stable, then rhacs-X.Y, then latest).
# Override: RHACS_VERSION, RHACS_OPERATOR_CHANNEL (with RHACS_AUTO_OPERATOR_CHANNEL=0), RHACS_SKIP_VERSION_UPDATE=1
export RHACS_DEFAULT_VERSION="${RHACS_DEFAULT_VERSION:-4.10}"
export RHACS_VERSION="${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}"
export RHACS_OPERATOR_CHANNEL="${RHACS_OPERATOR_CHANNEL:-stable}"
export RHACS_AUTO_OPERATOR_CHANNEL="${RHACS_AUTO_OPERATOR_CHANNEL:-1}"
export RHACS_USE_LIVE_CATALOG="${RHACS_USE_LIVE_CATALOG:-1}"
export RHACS_FIX_ARGOCD_CATALOG_DRIFT="${RHACS_FIX_ARGOCD_CATALOG_DRIFT:-1}"
RHACS_RESOLVED_OPERATOR_CHANNEL=""
RHACS_VERSION_UPGRADE_SKIPPED=0

# OpenShift Console security plugin (4.10+; RHACS docs require OCP 4.19+).
export RHACS_CONSOLE_PLUGIN_NAME="${RHACS_CONSOLE_PLUGIN_NAME:-advanced-cluster-security}"
export RHACS_ENSURE_CONSOLE_PLUGIN="${RHACS_ENSURE_CONSOLE_PLUGIN:-1}"
export RHACS_CONSOLE_PLUGIN_WAIT_SEC="${RHACS_CONSOLE_PLUGIN_WAIT_SEC:-600}"
export RHACS_CONSOLE_ROLLOUT_WAIT_SEC="${RHACS_CONSOLE_ROLLOUT_WAIT_SEC:-300}"
export RHACS_CONSOLE_PLUGIN_MIN_OCP="${RHACS_CONSOLE_PLUGIN_MIN_OCP:-4.19}"

# Namespaces to search for the RHACS OLM subscription (AllNamespaces installs use openshift-operators)
RHACS_SUBSCRIPTION_SEARCH_NAMESPACES="${RHACS_SUBSCRIPTION_SEARCH_NAMESPACES:-openshift-operators ${RHACS_NAMESPACE} rhacs-operator}"

# Function to check if a resource exists
check_resource_exists() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-}
    
    if [ -n "${namespace}" ]; then
        oc get "${resource_type}" "${resource_name}" -n "${namespace}" &>/dev/null
    else
        oc get "${resource_type}" "${resource_name}" &>/dev/null
    fi
}

# Get RHACS version from central deployment label app.kubernetes.io/version (e.g. Helm-managed installs).
get_version_from_deployment_label() {
    oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo ""
}

# Function to get current image tag from deployment (e.g. 4.9.3 or 4.10.0)
get_current_image_tag() {
    oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':[^:]+$' | sed 's/^://'
}

# Function to get installed RHACS version.
# Prefers deployment label; falls back to image tag (operator-managed installs often don't set the label).
get_installed_version() {
    local label_version
    label_version=$(get_version_from_deployment_label)
    if [ -n "${label_version}" ]; then
        echo "${label_version}"
        return
    fi
    # Fallback: image tag reflects actual running version (e.g. 4.10.0, 4.9.3, 4.10)
    local image_tag
    image_tag=$(get_current_image_tag)
    if [ -n "${image_tag}" ] && [[ "${image_tag}" =~ ^[0-9]+\.[0-9]+ ]]; then
        echo "${image_tag}"
    else
        echo ""
    fi
}

# Parse a version from an OLM CSV name (e.g. rhacs-operator.v4.10.2 -> 4.10.2).
version_from_csv_name() {
    local csv_name="$1"
    if [[ "${csv_name}" =~ v([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# List channels advertised for rhacs-operator in the openshift-marketplace catalog.
list_rhacs_operator_channels() {
    oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>/dev/null \
        | jq -r '.status.channels[].name' 2>/dev/null | sort -u | tr '\n' ' '
}

# Human-readable channel -> CSV listing from the cluster OperatorHub catalog.
list_rhacs_catalog_channel_details() {
    oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>/dev/null \
        | jq -r '.status.channels[] | "\(.name) -> \(.currentCSV)"' 2>/dev/null | sort -u
}

# Subscription catalog source (e.g. redhat-operators vs redhat-operators-snapshot).
get_rhacs_subscription_catalog_source() {
    local sub_name sub_ns
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)
    [ -n "${sub_name}" ] || return 1
    oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" \
        -o jsonpath='{.spec.source}{" "}{.spec.sourceNamespace}' 2>/dev/null
}

# Diagnose why RHACS 4.10 may be missing from the console channel list.
diagnose_rhacs_operator_catalog() {
    local target_mm sub_source sub_source_ns approval disable_defaults catalog_max
    target_mm=$(extract_major_minor "${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}")

    print_step "RHACS operator catalog diagnostics"
    print_info "Cluster OpenShift version: $(get_openshift_cluster_version 2>/dev/null || echo unknown)"
    print_info "Target RHACS version: ${target_mm}"

    print_info "Packagemanifest channels (what OperatorHub can offer):"
    local channel_lines=0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        print_info "  ${line}"
        channel_lines=$((channel_lines + 1))
    done < <(list_rhacs_catalog_channel_details)
    if [ "${channel_lines}" -eq 0 ]; then
        print_warn "  rhacs-operator not found in openshift-marketplace packagemanifest"
    fi

    sub_source=$(get_rhacs_subscription_catalog_source 2>/dev/null || echo "")
    if [ -n "${sub_source}" ]; then
        sub_source_ns="${sub_source#* }"
        sub_source="${sub_source%% *}"
        print_info "Subscription catalog source: ${sub_source} (namespace ${sub_source_ns})"
        if [[ "${sub_source}" == *snapshot* ]]; then
            print_warn "Subscription uses a SNAPSHOT catalog (${sub_source}) — channels are frozen and often stop at 4.9.x"
            print_warn "Switch to the live catalog to see RHACS 4.10 in the console:"
            print_info "  oc patch subscription rhacs-operator -n openshift-operators --type=merge -p '{\"spec\":{\"source\":\"redhat-operators\",\"sourceNamespace\":\"openshift-marketplace\",\"channel\":\"stable\"}}'"
            print_info "  Or set RHACS_USE_LIVE_CATALOG=1 and rerun this script to apply automatically"
        fi
    fi

    local sub_name sub_ns argocd_app
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)
    if [ -n "${sub_name}" ]; then
        argocd_app=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" \
            -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || echo "")
        if [ -n "${argocd_app}" ]; then
            argocd_app="${argocd_app%%:*}"
            print_warn "Subscription is managed by Argo CD (app: ${argocd_app}) — manual oc patch will be reverted on sync"
            print_info "  Update the Subscription in Git (source: redhat-operators), then sync app ${argocd_app}"
            print_info "  Or pause sync: argocd app set ${argocd_app} --sync-policy none"
            print_info "  Or ignore drift: argocd app set ${argocd_app} --sync-option IgnoreExtraneous=true (and add ignoreDifferences for spec.source)"
        fi
    fi

    approval=$(oc get subscriptions.operators.coreos.com "$(get_rhacs_subscription_name)" \
        -n "$(get_rhacs_subscription_namespace)" -o jsonpath='{.spec.installPlanApproval}' 2>/dev/null || echo "")
    if [ "${approval}" = "Manual" ]; then
        print_warn "Subscription installPlanApproval=Manual — approve updates in Console: Installed Operators → RHACS → Subscription → InstallPlan"
        print_info "  Or set Automatic: oc patch subscription rhacs-operator -n openshift-operators --type=merge -p '{\"spec\":{\"installPlanApproval\":\"Automatic\"}}'"
    fi

    if oc get operatorhub cluster &>/dev/null; then
        disable_defaults=$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null || echo "false")
        if [ "${disable_defaults}" = "true" ]; then
            print_warn "OperatorHub disableAllDefaultSources=true — default redhat-operators catalog may be disabled"
            print_info "  Re-enable: oc patch operatorhub cluster --type=merge -p '{\"spec\":{\"disableAllDefaultSources\":false}}'"
        fi
    fi

    catalog_max=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>/dev/null \
        | jq -r '[.status.channels[].currentCSV | capture("v(?<v>[0-9]+\\.[0-9]+(\\.[0-9]+)?)").v] | max_by(split(".") | map(tonumber))' 2>/dev/null || echo "")
    if [ -n "${catalog_max}" ] && version_gt "${target_mm}" "${catalog_max}"; then
        print_error "Catalog max RHACS version is ${catalog_max}; ${target_mm} is not available on this cluster's operator catalog"
        print_info "Refresh live catalog: oc delete pod -n openshift-marketplace -l olm.catalogSource=redhat-operators"
        print_info "Then recheck: oc get packagemanifest rhacs-operator -n openshift-marketplace -o json | jq -r '.status.channels[] | \"\\(.name) -> \\(.currentCSV)\"'"
    fi
}

# Argo CD app name from subscription tracking-id (e.g. acs:operators.coreos.com/... -> acs).
get_rhacs_argocd_app_name() {
    local sub_name sub_ns tracking_id
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)
    [ -n "${sub_name}" ] || return 1
    tracking_id=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" \
        -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || echo "")
    [ -n "${tracking_id}" ] || return 1
    echo "${tracking_id%%:*}"
}

# Namespace of the Argo CD Application CR (OpenShift GitOps default: openshift-gitops).
get_rhacs_argocd_app_namespace() {
    local app_name="$1"
    local ns
    [ -n "${app_name}" ] || return 1
    if [ -n "${RHACS_ARGOCD_APP_NAMESPACE:-}" ]; then
        echo "${RHACS_ARGOCD_APP_NAMESPACE}"
        return 0
    fi
    ns=$(oc get applications.argoproj.io -A -o json 2>/dev/null \
        | jq -r --arg app "${app_name}" '.items[] | select(.metadata.name == $app) | .metadata.namespace' 2>/dev/null | head -1)
    if [ -n "${ns}" ]; then
        echo "${ns}"
        return 0
    fi
    echo "openshift-gitops"
}

# Prevent Argo CD from reverting live-catalog subscription changes (ignoreDifferences on Subscription).
ensure_argocd_allows_subscription_catalog_upgrade() {
    local app_name app_ns sub_name sub_ns
    if [ "${RHACS_FIX_ARGOCD_CATALOG_DRIFT:-1}" != "1" ]; then
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        print_warn "jq required for Argo CD catalog drift fix; skipping"
        return 1
    fi

    app_name=$(get_rhacs_argocd_app_name 2>/dev/null || echo "")
    [ -n "${app_name}" ] || return 0

    app_ns=$(get_rhacs_argocd_app_namespace "${app_name}")
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)

    if ! oc get applications.argoproj.io "${app_name}" -n "${app_ns}" &>/dev/null; then
        print_warn "Argo CD Application ${app_ns}/${app_name} not found; subscription changes may be reverted on sync"
        return 1
    fi

    local has_source_ignore
    has_source_ignore=$(oc get applications.argoproj.io "${app_name}" -n "${app_ns}" -o json 2>/dev/null \
        | jq -r --arg sub "${sub_name}" --arg ns "${sub_ns}" '
            [.spec.ignoreDifferences[]? |
                select(.group == "operators.coreos.com" and .kind == "Subscription" and .name == $sub and (.namespace == $ns or .namespace == null)) |
                .jqPathExpressions[]? | select(. == ".spec.source")] | length
        ' 2>/dev/null || echo "0")

    if [ "${has_source_ignore:-0}" -gt 0 ]; then
        print_info "Argo CD app ${app_ns}/${app_name} already ignores Subscription catalog drift"
        return 0
    fi

    print_step "Configuring Argo CD app ${app_ns}/${app_name} to allow RHACS subscription catalog upgrades..."
    oc get applications.argoproj.io "${app_name}" -n "${app_ns}" -o json 2>/dev/null \
        | jq --arg sub "${sub_name}" --arg ns "${sub_ns}" '
            .spec.ignoreDifferences = ((.spec.ignoreDifferences // []) + [{
                group: "operators.coreos.com",
                kind: "Subscription",
                namespace: $ns,
                name: $sub,
                jqPathExpressions: [
                    ".spec.source",
                    ".spec.sourceNamespace",
                    ".spec.channel",
                    ".spec.installPlanApproval"
                ]
            }])
        ' | oc apply -f - 2>/dev/null || {
        print_warn "Could not patch Argo CD Application ${app_ns}/${app_name}"
        return 1
    }
    print_info "✓ Argo CD will no longer revert subscription source/channel to snapshot catalog"
    return 0
}

# Refresh redhat-operators catalog pods after switching subscription source.
refresh_redhat_operators_catalog() {
    local deleted
    deleted=$(oc delete pod -n openshift-marketplace -l olm.catalogSource=redhat-operators --wait=false 2>/dev/null || true)
    if [ -n "${deleted}" ]; then
        print_info "Refreshing redhat-operators catalog pods..."
        sleep 15
    fi
}

# Point subscription at live redhat-operators when snapshot catalog blocks upgrades.
ensure_live_redhat_operators_catalog() {
    local sub_name sub_ns current_source desired_channel target_version elapsed=0
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)
    [ -n "${sub_name}" ] || return 1

    current_source=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" \
        -o jsonpath='{.spec.source}' 2>/dev/null || echo "")
    if [ "${current_source}" = "redhat-operators" ]; then
        return 0
    fi

    if [ "${RHACS_USE_LIVE_CATALOG:-1}" = "0" ]; then
        print_warn "Subscription uses ${current_source:-unknown}; set RHACS_USE_LIVE_CATALOG=1 to switch to redhat-operators"
        return 1
    fi

    if [[ "${current_source}" != *snapshot* ]]; then
        print_warn "Subscription source is ${current_source:-unknown} (not a snapshot); only *snapshot* catalogs are auto-switched"
        return 1
    fi

    target_version="${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}"
    desired_channel=$(resolve_operator_channel_for_target "${target_version}")

    ensure_argocd_allows_subscription_catalog_upgrade || true

    print_step "Switching subscription catalog: ${current_source:-unknown} -> redhat-operators (channel ${desired_channel})..."
    oc patch subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" --type=merge -p "{
        \"spec\": {
            \"source\": \"redhat-operators\",
            \"sourceNamespace\": \"openshift-marketplace\",
            \"channel\": \"${desired_channel}\",
            \"installPlanApproval\": \"Automatic\"
        }
    }" || {
        print_warn "Could not switch subscription to redhat-operators"
        return 1
    }

    refresh_redhat_operators_catalog

    print_info "Waiting for subscription source to reconcile (up to 90s)..."
    while [ "${elapsed}" -lt 90 ]; do
        current_source=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" \
            -o jsonpath='{.spec.source}' 2>/dev/null || echo "")
        if [ "${current_source}" = "redhat-operators" ]; then
            print_info "✓ Subscription source: redhat-operators"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    print_warn "Subscription source is still ${current_source:-unknown} after 90s (Argo CD may still be reverting)"
    diagnose_rhacs_operator_catalog
    return 1
}

# Ensure operator catalog can provide target RHACS (snapshot -> live, Argo CD drift fix).
ensure_operator_catalog_for_upgrade() {
    local current_source
    current_source=$(get_rhacs_subscription_catalog_source 2>/dev/null || echo "")
    current_source="${current_source%% *}"
    if [[ "${current_source}" == *snapshot* ]]; then
        ensure_live_redhat_operators_catalog || true
    fi
}

# Max RHACS version available on a given OLM channel in the catalog (before install).
get_catalog_version_for_channel() {
    local channel="${1:-stable}"
    local csv_name
    csv_name=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>/dev/null \
        | jq -r --arg ch "${channel}" '.status.channels[] | select(.name == $ch) | .currentCSV' 2>/dev/null | head -1)
    if [ -n "${csv_name}" ]; then
        version_from_csv_name "${csv_name}"
    fi
}

# Function to get latest available RHACS version from the installed operator CSV.
get_latest_available_version() {
    local csv_name
    csv_name=$(get_rhacs_csv_name)
    if [ -z "${csv_name}" ]; then
        get_version_from_deployment_label
        return
    fi
    local csv_ns
    csv_ns=$(get_rhacs_csv_namespace)
    local ver
    ver=$(version_from_csv_name "${csv_name}")
    if [ -n "${ver}" ]; then
        echo "${ver}"
        return
    fi
    oc get csv "${csv_name}" -n "${csv_ns}" -o jsonpath='{.spec.version}' 2>/dev/null || get_version_from_deployment_label
}

# Best-effort max version the catalog can provide on the target operator channel.
get_target_channel_catalog_version() {
    local channel
    channel=$(get_channel_for_version "${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}")
    get_catalog_version_for_channel "${channel}"
}



# Function to verify RHACS installation
verify_rhacs_installation() {
    print_step "Verifying RHACS installation..."
    
    # Check if namespace exists
    if ! check_resource_exists "namespace" "${RHACS_NAMESPACE}"; then
        print_error "RHACS namespace '${RHACS_NAMESPACE}' does not exist"
        return 1
    fi
    print_info "✓ Namespace '${RHACS_NAMESPACE}' exists"
    
    # Check for Central deployment
    if ! check_resource_exists "deployment" "central" "${RHACS_NAMESPACE}"; then
        print_error "Central deployment not found in namespace '${RHACS_NAMESPACE}'"
        return 1
    fi
    print_info "✓ Central deployment exists"
    
    # Check if Central is ready
    local central_ready=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
    if [ "${central_ready}" != "True" ]; then
        print_warn "Central deployment is not yet ready"
        print_info "Waiting for Central to become ready..."
        oc wait --for=condition=available --timeout=300s deployment/central -n "${RHACS_NAMESPACE}" || {
            print_error "Central deployment did not become ready within timeout"
            return 1
        }
    fi
    print_info "✓ Central deployment is ready"
    
    # Check for SecuredCluster resources
    print_step "Checking SecuredCluster services..."
    local secured_clusters=$(oc get securedcluster -A -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
    if [ "${secured_clusters}" -eq 0 ]; then
        print_warn "No SecuredCluster resources found"
    else
        print_info "✓ Found ${secured_clusters} SecuredCluster resource(s)"
        
        # Verify each SecuredCluster by checking its pods
        while IFS= read -r sc; do
            if [ -n "${sc}" ]; then
                local sc_namespace=$(echo "${sc}" | awk '{print $1}')
                local sc_name=$(echo "${sc}" | awk '{print $2}')
                
                # Check if sensor, admission-control, and collector pods are running
                local sensor_ready=$(oc get deployment sensor -n "${sc_namespace}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
                local admission_ready=$(oc get deployment admission-control -n "${sc_namespace}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
                local collector_count=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
                local collector_desired=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
                
                if [ "${sensor_ready}" = "True" ] && [ "${admission_ready}" = "True" ] && [ "${collector_count}" -eq "${collector_desired}" ] && [ "${collector_count}" -gt 0 ]; then
                    print_info "  ✓ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' is ready (sensor, admission-control, and ${collector_count}/${collector_desired} collectors running)"
                else
                    print_warn "  ⚠ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' components: sensor=${sensor_ready}, admission-control=${admission_ready}, collectors=${collector_count}/${collector_desired}"
                fi
            fi
        done < <(oc get securedcluster -A --no-headers 2>/dev/null || true)
    fi
    
    return 0
}

# Function to verify route encryption
verify_route_encryption() {
    print_step "Verifying RHACS route encryption..."
    
    # Check if route exists
    if ! check_resource_exists "route" "${RHACS_ROUTE_NAME}" "${RHACS_NAMESPACE}"; then
        print_error "Route '${RHACS_ROUTE_NAME}' not found in namespace '${RHACS_NAMESPACE}'"
        return 1
    fi
    print_info "✓ Route '${RHACS_ROUTE_NAME}' exists"
    
    # Check if route has TLS termination
    local tls_term=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ -z "${tls_term}" ] || [ "${tls_term}" = "None" ]; then
        print_error "Route '${RHACS_ROUTE_NAME}' does not have TLS termination configured"
        print_info "Updating route to use edge TLS termination..."
        
        # Patch the route to add TLS termination
        oc patch route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" --type=json -p='[
            {
                "op": "add",
                "path": "/spec/tls",
                "value": {
                    "termination": "edge",
                    "insecureEdgeTerminationPolicy": "Redirect"
                }
            }
        ]' || {
            print_error "Failed to update route TLS configuration"
            return 1
        }
        
        print_info "✓ Route updated with TLS termination"
    else
        print_info "✓ Route has TLS termination: ${tls_term}"
    fi
    
    # Verify route is accessible via HTTPS
    local route_url=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${route_url}" ]; then
        print_info "Route URL: ${route_url}"
        
        # Check if route responds (with a timeout)
        if curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "${route_url}" | grep -q "200\|302\|401\|403"; then
            print_info "✓ Route is accessible via HTTPS"
        else
            print_warn "Route may not be fully accessible yet (this is normal if RHACS is still initializing)"
        fi
    fi
    
    return 0
}

# Get the RHACS CSV name (highest installed version across operator + stackrox namespaces).
# Returns e.g. rhacs-operator.v4.9.3. Empty if not found.
get_rhacs_csv_name() {
    local best_csv="" best_ver="" csv ver
    for ns in "${RHACS_OPERATOR_NAMESPACE}" "${RHACS_NAMESPACE}" openshift-operators; do
        while IFS= read -r csv; do
            [ -n "${csv}" ] || continue
            ver=$(version_from_csv_name "${csv}")
            if [ -z "${best_ver}" ] || { [ -n "${ver}" ] && version_gt "${ver}" "${best_ver}"; }; then
                best_ver="${ver}"
                best_csv="${csv}"
            fi
        done < <(oc get csv -n "${ns}" -o name 2>/dev/null | grep rhacs-operator | sed 's|.*/||' || true)
    done
    echo "${best_csv}"
}

# Get the namespace where the RHACS CSV is installed (for patching).
get_rhacs_csv_namespace() {
    if oc get csv -n "${RHACS_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep -q rhacs-operator; then
        echo "${RHACS_OPERATOR_NAMESPACE}"
    elif oc get csv -n "${RHACS_NAMESPACE}" -o name 2>/dev/null | grep -q rhacs-operator; then
        echo "${RHACS_NAMESPACE}"
    else
        echo "${RHACS_NAMESPACE}"
    fi
}

# Ensure CSV deploy details are updated to target version (no subscriptions).
# Patches only deployment container images in the CSV to the target version tag.
ensure_csv_deploy_version() {
    local target_version=$1
    local csv_name
    csv_name=$(get_rhacs_csv_name)
    local csv_ns
    csv_ns=$(get_rhacs_csv_namespace)
    if [ -z "${csv_name}" ]; then
        print_warn "No RHACS CSV found; skipping CSV deploy update"
        return 0
    fi
    print_step "Updating CSV ${csv_name} deploy details to version ${target_version}..."
    if ! command -v jq &>/dev/null; then
        print_warn "jq not found; cannot patch CSV deploy details. Install jq or update the CSV manually."
        return 1
    fi
    local csv_json
    csv_json=$(oc get csv "${csv_name}" -n "${csv_ns}" -o json 2>/dev/null) || true
    if [ -z "${csv_json}" ]; then
        print_error "Failed to get CSV ${csv_name}"
        return 1
    fi
    local patched
    patched=$(echo "${csv_json}" | jq --arg tv "${target_version}" '
        del(.status) |
        .spec.install.spec.deployments |= (map(
            .spec.template.spec.containers |= (map(
                if .image then .image = ((.image | split(":")[0]) + ":" + $tv) else . end
            ))
        ))
    ')
    if echo "${patched}" | oc apply -f - -n "${csv_ns}" 2>/dev/null; then
        print_info "CSV deploy details updated; waiting 45s for rollout..."
        sleep 45
        return 0
    fi
    print_warn "Could not apply CSV patch"
    return 1
}

# Function to check and update RHACS version
# Defaults to RHACS_DEFAULT_VERSION (4.10). Skips upgrade when operator catalog cannot provide target.
check_and_update_version() {
    print_step "Checking RHACS version..."

    if [ "${RHACS_SKIP_VERSION_UPDATE:-0}" = "1" ]; then
        local installed_only
        installed_only=$(get_installed_version)
        print_info "RHACS_SKIP_VERSION_UPDATE=1 — keeping installed version${installed_only:+: ${installed_only}}"
        return 0
    fi

    local target_version="${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}"
    print_info "Target version: ${target_version} (default: ${RHACS_DEFAULT_VERSION})"

    # Snapshot catalog + Argo CD: switch to live redhat-operators before channel/version work
    if [ -n "$(get_rhacs_subscription_name)" ]; then
        ensure_operator_catalog_for_upgrade
    fi
    
    # Prefer subscription channel update (subscriptions.operators.coreos.com); fall back to CSV when no subscription
    if [ -n "$(get_rhacs_subscription_name)" ]; then
        ensure_subscription_channel_for_version "${target_version}" || true
    else
        ensure_csv_deploy_version "${target_version}" || true
    fi
    
    # Get current installed version (after possible channel switch)
    local installed_version=$(get_installed_version)
    local current_image_tag=$(get_current_image_tag)
    
    if [ -z "${installed_version}" ]; then
        print_warn "Could not determine installed RHACS version from semantic version pattern"
        if [ -n "${current_image_tag}" ]; then
            print_info "Current image tag: ${current_image_tag}"
        fi
        installed_version="unknown"
    else
        print_info "Installed RHACS version: ${installed_version}"
    fi
    
    RHACS_RESOLVED_OPERATOR_CHANNEL=$(resolve_operator_channel_for_target "${target_version}")
    local operator_channel="${RHACS_RESOLVED_OPERATOR_CHANNEL}"
    print_info "Resolved operator channel: ${operator_channel} (auto=${RHACS_AUTO_OPERATOR_CHANNEL:-1})"

    local catalog_version installed_csv_version latest_version
    catalog_version=$(get_catalog_version_for_channel "${operator_channel}")
    installed_csv_version=$(get_latest_available_version)
    latest_version="${catalog_version:-${installed_csv_version}}"

    if [ -n "${catalog_version}" ]; then
        print_info "Catalog version on channel ${operator_channel}: ${catalog_version}"
    fi
    if [ -n "${installed_csv_version}" ]; then
        print_info "Installed operator CSV version: ${installed_csv_version}"
    fi

    local target_major_minor
    target_major_minor=$(extract_major_minor "${target_version}")
    local installed_major_minor
    installed_major_minor=$(extract_major_minor "${installed_version}")
    local latest_major_minor=""
    if [ -n "${latest_version}" ]; then
        latest_major_minor=$(extract_major_minor "${latest_version}")
        if version_gt "${target_major_minor}" "${latest_major_minor}"; then
            print_warn "Target ${target_version} is not available on channel ${operator_channel} (catalog max: ${latest_version})"
            print_warn "Available operator channels: $(list_rhacs_operator_channels)"
            ensure_live_redhat_operators_catalog || true
            diagnose_rhacs_operator_catalog
            print_warn "Skipping upgrade until the operator catalog provides ${target_major_minor}"
            print_info "Continuing setup with installed version: ${installed_version}"
            RHACS_VERSION_UPGRADE_SKIPPED=1
            return 0
        fi
    fi
    
    # Already at target: same minor = stable (4.10.x follows 4.10 channel)
    if [ "${installed_version}" != "unknown" ] && [ "${target_major_minor}" = "${installed_major_minor}" ]; then
        print_info "✓ RHACS is already at target version ${target_version} (installed: ${installed_version})"
        return 0
    fi
    
    # Downgrade check: only when target minor < installed minor (e.g. 4.9 vs 4.10.0)
    if [ "${installed_version}" != "unknown" ] && [ "${target_version}" != "unknown" ]; then
        if [ "$(printf '%s\n' "${target_major_minor}" "${installed_major_minor}" | sort -V | head -n1)" = "${target_major_minor}" ] && \
           [ "${target_major_minor}" != "${installed_major_minor}" ]; then
            print_warn "⚠️  Warning: Target version ${target_version} is older than installed version ${installed_version}"
            print_warn "This would be a DOWNGRADE!"
            if [ "${RHACS_FORCE_DOWNGRADE:-false}" != "true" ]; then
                print_error "Refusing to downgrade. To force: export RHACS_FORCE_DOWNGRADE=true"
                print_info "Keeping current version: ${installed_version}"
                return 0
            fi
            print_warn "RHACS_FORCE_DOWNGRADE=true - proceeding with downgrade..."
        fi
    fi
    
    # Proceed with update to target
    print_info "Current version ${installed_version} -> Target version ${target_version}"
    update_rhacs_version "${target_version}"
}

# True when catalog version satisfies target minor (e.g. 4.10.3 meets target 4.10).
catalog_version_meets_target() {
    local catalog_ver="$1"
    local target_mm="$2"
    local catalog_mm
    catalog_mm=$(extract_major_minor "${catalog_ver}")
    [ -n "${catalog_mm}" ] && ! version_gt "${target_mm}" "${catalog_mm}"
}

# Pick the OLM channel that can provide the target RHACS version (or the best available).
resolve_operator_channel_for_target() {
    local target_version="$1"
    local target_mm channel catalog_ver catalog_mm
    local -a candidates=() seen=()

    target_mm=$(extract_major_minor "${target_version}")

    if [ "${RHACS_USE_VERSION_PINNED_CHANNEL:-0}" = "1" ]; then
        echo "rhacs-${target_mm}"
        return 0
    fi

    if [ "${RHACS_AUTO_OPERATOR_CHANNEL:-1}" = "0" ] && [ -n "${RHACS_OPERATOR_CHANNEL:-}" ]; then
        echo "${RHACS_OPERATOR_CHANNEL}"
        return 0
    fi

    if [ -n "${RHACS_OPERATOR_CHANNEL:-}" ]; then
        candidates+=("${RHACS_OPERATOR_CHANNEL}")
    fi
    candidates+=("stable" "rhacs-${target_mm}" "latest")

    for channel in "${candidates[@]}"; do
        local dup=false
        for s in "${seen[@]:-}"; do
            [ "${s}" = "${channel}" ] && dup=true && break
        done
        [ "${dup}" = true ] && continue
        seen+=("${channel}")

        catalog_ver=$(get_catalog_version_for_channel "${channel}")
        if [ -n "${catalog_ver}" ] && catalog_version_meets_target "${catalog_ver}" "${target_mm}"; then
            echo "${channel}"
            return 0
        fi
    done

    local best_ch="" best_mm=""
    while IFS= read -r channel; do
        [ -n "${channel}" ] || continue
        catalog_ver=$(get_catalog_version_for_channel "${channel}")
        [ -n "${catalog_ver}" ] || continue
        catalog_mm=$(extract_major_minor "${catalog_ver}")
        if [ -z "${best_mm}" ] || version_gt "${catalog_mm}" "${best_mm}"; then
            best_mm="${catalog_mm}"
            best_ch="${channel}"
        fi
    done < <(list_rhacs_operator_channels | tr ' ' '\n' | awk 'NF')

    if [ -n "${best_ch}" ]; then
        echo "${best_ch}"
        return 0
    fi

    echo "${RHACS_OPERATOR_CHANNEL:-stable}"
}

# Operator OLM channel for upgrades (delegates to auto-resolution).
get_channel_for_version() {
    local ver="$1"
    if [ -n "${RHACS_RESOLVED_OPERATOR_CHANNEL}" ]; then
        echo "${RHACS_RESOLVED_OPERATOR_CHANNEL}"
        return 0
    fi
    resolve_operator_channel_for_target "${ver}"
}

# Extract major.minor from a version string (4.10.0 -> 4.10).
extract_major_minor() {
    local ver="$1"
    if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "${ver}"
    fi
}

# True when ver_a is strictly greater than ver_b (semver-ish via sort -V).
version_gt() {
    local ver_a="$1"
    local ver_b="$2"
    [ "$(printf '%s\n' "${ver_a}" "${ver_b}" | sort -V | tail -1)" = "${ver_a}" ] && [ "${ver_a}" != "${ver_b}" ]
}

# Get RHACS subscription name using subscriptions.operators.coreos.com.
# Returns subscription name (e.g. rhacs-operator) or empty if not found.
get_rhacs_subscription_name() {
    local ns
    for ns in ${RHACS_SUBSCRIPTION_SEARCH_NAMESPACES}; do
        local sub
        sub=$(oc get subscriptions.operators.coreos.com -n "${ns}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].metadata.name}' 2>/dev/null || echo "")
        if [ -n "${sub}" ]; then
            echo "${sub}"
            return 0
        fi
    done
    echo ""
}

# Namespace where the RHACS subscription lives (paired with get_rhacs_subscription_name).
get_rhacs_subscription_namespace() {
    local ns
    for ns in ${RHACS_SUBSCRIPTION_SEARCH_NAMESPACES}; do
        if oc get subscriptions.operators.coreos.com -n "${ns}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].metadata.name}' 2>/dev/null | grep -q .; then
            echo "${ns}"
            return 0
        fi
    done
    echo "${RHACS_OPERATOR_NAMESPACE}"
}

# Ensure operator subscription channel is set for target version (e.g. 4.10 -> rhacs-4.10).
# Uses subscriptions.operators.coreos.com - the correct resource name for oc.
ensure_subscription_channel_for_version() {
    local target_version=$1
    local desired_channel
    desired_channel=$(resolve_operator_channel_for_target "${target_version}")
    RHACS_RESOLVED_OPERATOR_CHANNEL="${desired_channel}"
    local sub_name sub_ns
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)
    if [ -z "${sub_name}" ]; then
        print_warn "No RHACS subscription found (searched: ${RHACS_SUBSCRIPTION_SEARCH_NAMESPACES})"
        print_warn "Find it with: oc get subscription -A | grep rhacs"
        print_warn "Without a subscription, the operator channel cannot be updated for ${target_version}"
        return 1
    fi

    local catalog_csv catalog_ver
    catalog_csv=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>/dev/null \
        | jq -r --arg ch "${desired_channel}" '.status.channels[] | select(.name == $ch) | .currentCSV' 2>/dev/null | head -1)
    catalog_ver=$(version_from_csv_name "${catalog_csv}")
    if [ -z "${catalog_csv}" ]; then
        print_warn "Channel '${desired_channel}' not found in openshift-marketplace catalog"
        print_warn "Available channels: $(list_rhacs_operator_channels)"
        ensure_live_redhat_operators_catalog && desired_channel=$(resolve_operator_channel_for_target "${target_version}")
        catalog_csv=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>/dev/null \
            | jq -r --arg ch "${desired_channel}" '.status.channels[] | select(.name == $ch) | .currentCSV' 2>/dev/null | head -1)
        if [ -z "${catalog_csv}" ]; then
            diagnose_rhacs_operator_catalog
            return 1
        fi
        RHACS_RESOLVED_OPERATOR_CHANNEL="${desired_channel}"
    fi
    print_info "Catalog CSV for channel ${desired_channel}: ${catalog_csv} (${catalog_ver:-unknown})"

    local current_channel
    current_channel=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    if [ "${current_channel}" = "${desired_channel}" ]; then
        print_info "Subscription already on channel: ${desired_channel} (namespace ${sub_ns})"
        return 0
    fi
    print_step "Setting subscription channel: ${current_channel:-unknown} -> ${desired_channel} (namespace ${sub_ns})..."
    if ! oc patch subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/channel\",\"value\":\"${desired_channel}\"}]" 2>/dev/null; then
        print_warn "Could not set subscription channel to ${desired_channel}"
        return 1
    fi
    local wait_sec="${RHACS_CHANNEL_RECONCILE_WAIT_SEC:-120}"
    print_info "Waiting ${wait_sec}s for OLM to reconcile channel ${desired_channel}..."
    sleep "${wait_sec}"
    return 0
}

# Get the name of the Central CR in RHACS_NAMESPACE (e.g. "central" or "stackrox-central-services").
# Empty if no Central CR exists.
get_central_cr_name() {
    oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Approve pending OLM InstallPlans for the RHACS operator (Manual approval blocks upgrades).
approve_pending_rhacs_installplans() {
    local sub_ns
    sub_ns=$(get_rhacs_subscription_namespace)
    [ -n "${sub_ns}" ] || return 0
    if ! command -v jq &>/dev/null; then
        return 0
    fi

    local pending
    pending=$(oc get installplan -n "${sub_ns}" -o json 2>/dev/null \
        | jq -r '.items[] | select((.spec.clusterServiceVersionNames[]? // "") | test("rhacs")) | select(.spec.approved != true) | .metadata.name' 2>/dev/null || true)
    for ip in ${pending}; do
        [ -n "${ip}" ] || continue
        print_step "Approving InstallPlan ${ip} in ${sub_ns}..."
        oc patch installplan "${ip}" -n "${sub_ns}" --type=merge -p '{"spec":{"approved":true}}' 2>/dev/null || \
            print_warn "Could not approve InstallPlan ${ip}"
    done
}

# Periodic upgrade diagnostics: subscription, InstallPlan, operator CSV, Central deployment.
print_rhacs_upgrade_status() {
    local sub_name sub_ns
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)

    if [ -n "${sub_name}" ]; then
        local sub_channel sub_state sub_approval install_plan
        sub_channel=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "?")
        sub_state=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" -o jsonpath='{.status.state}' 2>/dev/null || echo "?")
        sub_approval=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" -o jsonpath='{.spec.installPlanApproval}' 2>/dev/null || echo "Automatic")
        install_plan=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" -o jsonpath='{.status.installplan.name}{.status.installPlanRef.name}' 2>/dev/null || echo "")
        print_info "  Subscription ${sub_ns}/${sub_name}: channel=${sub_channel} state=${sub_state} approval=${sub_approval}${install_plan:+ installPlan=${install_plan}}"
        if [ -n "${install_plan}" ]; then
            local ip_phase ip_approved
            ip_phase=$(oc get installplan "${install_plan}" -n "${sub_ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
            ip_approved=$(oc get installplan "${install_plan}" -n "${sub_ns}" -o jsonpath='{.spec.approved}' 2>/dev/null || echo "?")
            print_info "  InstallPlan ${install_plan}: phase=${ip_phase} approved=${ip_approved}"
        fi
    fi

    local csv_name csv_ns csv_ver
    csv_name=$(get_rhacs_csv_name)
    csv_ns=$(get_rhacs_csv_namespace)
    csv_ver=$(get_latest_available_version)
    print_info "  Operator CSV: ${csv_ns}/${csv_name:-none} (version ${csv_ver:-unknown})"

    local central_img central_ready central_updated
    central_img=$(get_current_image_tag)
    central_ready=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "?")
    central_updated=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null | head -c 120 || echo "")
    print_info "  Central deployment: image=${central_img:-?} ready=${central_ready}${central_updated:+ (${central_updated})}"

    local central_cr_name central_status
    central_cr_name=$(get_central_cr_name)
    if [ -n "${central_cr_name}" ]; then
        central_status=$(oc get central "${central_cr_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null | head -c 160 || echo "")
        print_info "  Central CR ${central_cr_name}: ${central_status:-no status}"
    fi
}

# Wait until the installed operator CSV reaches target major.minor (Central follows operator upgrade).
wait_for_operator_csv_version() {
    local target_mm="$1"
    local max_wait="${2:-${RHACS_OPERATOR_CSV_WAIT_SEC:-600}}"
    local elapsed=0 csv_mm

    print_info "Waiting for operator CSV to reach ${target_mm} (up to ${max_wait}s)..."
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        approve_pending_rhacs_installplans
        csv_mm=$(extract_major_minor "$(get_latest_available_version 2>/dev/null || echo "")")
        if [ -n "${csv_mm}" ] && ! version_gt "${target_mm}" "${csv_mm}"; then
            print_info "✓ Operator CSV at ${csv_mm} (target ${target_mm})"
            return 0
        fi
        print_info "Operator CSV: ${csv_mm:-unknown} (target ${target_mm}, ${elapsed}s/${max_wait}s)"
        print_rhacs_upgrade_status
        sleep 30
        elapsed=$((elapsed + 30))
    done
    print_warn "Operator CSV did not reach ${target_mm} within ${max_wait}s (current: ${csv_mm:-unknown})"
    return 1
}

# Wait for Central deployment to reach target major.minor with periodic status output.
wait_for_central_target_version() {
    local target_mm="$1"
    local max_wait="${2:-${RHACS_CENTRAL_UPGRADE_WAIT_SEC:-600}}"
    local elapsed=0 current_ver current_mm last_status_at=-999

    print_info "Waiting for Central to reach ${target_mm} (up to ${max_wait}s)..."
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        approve_pending_rhacs_installplans
        current_ver=$(get_installed_version)
        current_mm=$(extract_major_minor "${current_ver}")

        if [ -n "${current_mm}" ] && [ "${current_mm}" = "${target_mm}" ]; then
            if oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=120s 2>/dev/null; then
                print_info "✓ Central at target version ${current_ver}, rollout complete"
                return 0
            fi
        fi

        if [ $((elapsed - last_status_at)) -ge 30 ] || [ "${elapsed}" -eq 0 ]; then
            print_info "Central version: ${current_ver:-unknown} (target ${target_mm}, ${elapsed}s/${max_wait}s)"
            print_rhacs_upgrade_status
            last_status_at=${elapsed}
        fi

        sleep 15
        elapsed=$((elapsed + 15))
    done

    print_warn "Timeout waiting for Central ${target_mm}. Current: $(get_installed_version)"
    print_warn "Check: oc get subscription,installplan,csv -A | grep rhacs; oc describe central -n ${RHACS_NAMESPACE}"
    print_rhacs_upgrade_status
    return 1
}

# Function to update RHACS version
update_rhacs_version() {
    local target_version=$1
    local target_major_minor
    target_major_minor=$(extract_major_minor "${target_version}")
    local has_subscription=false

    print_info "Updating RHACS to version ${target_version}..."

    # Discover Central CR name (operator may use "central" or "stackrox-central-services")
    local central_cr_name
    central_cr_name=$(get_central_cr_name)

    if [ -n "${central_cr_name}" ]; then
        print_info "Updating Central resource (${central_cr_name})..."

        if [ -n "$(get_rhacs_subscription_name)" ]; then
            has_subscription=true
            if ensure_subscription_channel_for_version "${target_version}"; then
                approve_pending_rhacs_installplans
                wait_for_operator_csv_version "${target_major_minor}" || true
            else
                print_warn "Subscription channel could not be set; Central upgrade may stall"
            fi
        fi

        local current_image
        current_image=$(oc get central "${central_cr_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.image}' 2>/dev/null || echo "")

        if [ -n "${current_image}" ]; then
            local image_repo
            image_repo=$(echo "${current_image}" | sed 's/:.*//')
            oc patch central "${central_cr_name}" -n "${RHACS_NAMESPACE}" --type=json -p="[
                {\"op\": \"replace\", \"path\": \"/spec/central/image\", \"value\": \"${image_repo}:${target_version}\"}
            ]" || {
                print_error "Failed to update Central image"
                return 1
            }
        elif [ "${has_subscription}" = true ]; then
            print_info "Central has no custom image; operator will reconcile Central after CSV upgrade"
        elif ensure_csv_deploy_version "${target_version}"; then
            print_info "No subscription found; patched operator CSV deploy details as fallback"
        else
            print_warn "No subscription and CSV patch failed; cannot drive Central upgrade"
            return 0
        fi

        local installed_now installed_mm
        installed_now=$(get_installed_version)
        installed_mm=$(extract_major_minor "${installed_now}")

        if [ -n "${installed_mm}" ] && [ "${installed_mm}" = "${target_major_minor}" ]; then
            print_info "✓ RHACS already at target version ${installed_now}"
            return 0
        fi

        wait_for_central_target_version "${target_major_minor}" || true
        return 0
    else
        # No Central CR: try subscription channel first, then CSV deploy details
        if [ -n "$(get_rhacs_subscription_name)" ]; then
            print_info "Central CR not found; updating subscription channel to ${target_version}..."
            if ! ensure_subscription_channel_for_version "${target_version}"; then
                print_error "Failed to update subscription channel"
                return 1
            fi
        else
            print_info "Central CR not found; updating CSV deploy details to ${target_version}..."
            if ! ensure_csv_deploy_version "${target_version}"; then
                print_error "Failed to update CSV deploy details"
                return 1
            fi
        fi
        print_info "Waiting for deployment rollout to complete..."
        oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=600s || {
            print_warn "Rollout may still be in progress. Check: oc get pods -n ${RHACS_NAMESPACE}"
        }
        print_info "✓ RHACS update initiated"
    fi
    
    # Verify new version
    sleep 10
    local new_version=$(get_installed_version)
    if [ -n "${new_version}" ] && [ "${new_version}" != "unknown" ]; then
        print_info "Current version after update: ${new_version}"
    fi
}

# RHACS operator CSV declares console.openshift.io/plugins (typically advanced-cluster-security).
get_rhacs_console_plugins_from_csv() {
    local csv_name csv_ns plugins_json
    csv_name=$(get_rhacs_csv_name)
    csv_ns=$(get_rhacs_csv_namespace)
    if [ -z "${csv_name}" ]; then
        return 1
    fi
    plugins_json=$(oc get csv "${csv_name}" -n "${csv_ns}" -o jsonpath='{.metadata.annotations.console\.openshift\.io/plugins}' 2>/dev/null || echo "")
    if [ -n "${plugins_json}" ] && command -v jq &>/dev/null; then
        echo "${plugins_json}" | jq -r '.[]? // empty' 2>/dev/null
        return 0
    fi
    return 1
}

get_rhacs_console_plugin_from_csv() {
    get_rhacs_console_plugins_from_csv 2>/dev/null | head -1
}

# Discover ConsolePlugin CR name (cluster-scoped). RHACS uses advanced-cluster-security in current operator bundles.
find_rhacs_console_plugin_name() {
    local candidate name

    if [ -n "${RHACS_CONSOLE_PLUGIN_NAME:-}" ]; then
        if oc get consoleplugin "${RHACS_CONSOLE_PLUGIN_NAME}" &>/dev/null; then
            echo "${RHACS_CONSOLE_PLUGIN_NAME}"
            return 0
        fi
        print_warn "RHACS_CONSOLE_PLUGIN_NAME=${RHACS_CONSOLE_PLUGIN_NAME} set but ConsolePlugin not found"
    fi

    for candidate in advanced-cluster-security acs rhacs; do
        if oc get consoleplugin "${candidate}" &>/dev/null; then
            echo "${candidate}"
            return 0
        fi
    done

    if command -v jq &>/dev/null && oc get consoleplugins -o json &>/dev/null; then
        name=$(oc get consoleplugins -o json 2>/dev/null | jq -r '
            .items[] | select(
                .metadata.name == "advanced-cluster-security" or
                .metadata.name == "acs" or
                .metadata.name == "rhacs" or
                (.spec.displayName != null and (
                    (.spec.displayName | ascii_downcase | test("advanced cluster security")) or
                    (.spec.displayName | ascii_downcase | test("rhacs"))
                ))
            ) | .metadata.name
        ' 2>/dev/null | head -1)
        if [ -n "${name}" ]; then
            echo "${name}"
            return 0
        fi
    fi

    name=$(get_rhacs_console_plugin_from_csv 2>/dev/null || true)
    if [ -n "${name}" ]; then
        echo "${name}"
        return 0
    fi

    return 1
}

get_openshift_cluster_version() {
    oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo ""
}

# RHACS 4.10 console plugin docs: OCP 4.19, 4.20, or 4.21 required.
openshift_version_meets_console_plugin_requirement() {
    local ocp_ver="${1:-$(get_openshift_cluster_version)}"
    local min_ocp="${RHACS_CONSOLE_PLUGIN_MIN_OCP:-4.19}"
    if [ -z "${ocp_ver}" ]; then
        return 1
    fi
    local ocp_mm
    ocp_mm=$(extract_major_minor "${ocp_ver}")
    [ "$(printf '%s\n' "${min_ocp}" "${ocp_mm}" | sort -V | tail -1)" = "${ocp_mm}" ]
}

secured_cluster_present_for_console_plugin() {
    oc get securedcluster -n "${RHACS_NAMESPACE}" -o name 2>/dev/null | grep -q .
}

wait_for_console_operator_rollout() {
    local max_wait="${RHACS_CONSOLE_ROLLOUT_WAIT_SEC:-300}"
    local elapsed=0
    local step=10

    print_info "Waiting for OpenShift Console rollout after plugin enable (up to ${max_wait}s)..."
    if oc rollout status deployment/console -n openshift-console --timeout="${max_wait}s" 2>/dev/null; then
        print_info "✓ OpenShift Console deployment rolled out"
        return 0
    fi

    while [ "${elapsed}" -lt "${max_wait}" ]; do
        local available updated
        available=$(oc get deployment console -n openshift-console -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        updated=$(oc get deployment console -n openshift-console -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
        local desired
        desired=$(oc get deployment console -n openshift-console -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "${available:-0}" -ge "${desired:-1}" ] && [ "${updated:-0}" -ge "${desired:-1}" ]; then
            print_info "✓ OpenShift Console deployment is available (${available}/${desired})"
            return 0
        fi
        sleep "${step}"
        elapsed=$((elapsed + step))
    done
    print_warn "OpenShift Console rollout not confirmed within ${max_wait}s — hard-refresh the browser after pods stabilize"
    return 1
}

verify_console_plugin_backend() {
    local plugin_name="$1"
    local svc_ns svc_name

    if [ -z "${plugin_name}" ]; then
        return 1
    fi

    svc_ns=$(oc get consoleplugin "${plugin_name}" -o jsonpath='{.spec.backend.service.name}{"\n"}{.spec.backend.service.namespace}' 2>/dev/null | tail -1)
    svc_name=$(oc get consoleplugin "${plugin_name}" -o jsonpath='{.spec.backend.service.name}' 2>/dev/null || echo "")
    if [ -z "${svc_ns}" ] || [ -z "${svc_name}" ]; then
        print_warn "ConsolePlugin '${plugin_name}' has no backend service reference yet"
        return 1
    fi

    if oc get svc "${svc_name}" -n "${svc_ns}" &>/dev/null; then
        print_info "✓ Plugin backend service ${svc_ns}/${svc_name} exists"
    else
        print_warn "Plugin backend service ${svc_ns}/${svc_name} not found"
        return 1
    fi

    if oc get endpoints "${svc_name}" -n "${svc_ns}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; then
        print_info "✓ Plugin backend service has endpoints"
        return 0
    fi

    print_warn "Plugin backend service ${svc_ns}/${svc_name} has no endpoints — SecuredCluster operator may still be reconciling"
    return 1
}

diagnose_rhacs_console_plugin() {
    local plugin_name="${RHACS_CONSOLE_PLUGIN_NAME:-advanced-cluster-security}"
    local ocp_ver installed_ver installed_mm target_mm

    print_step "Console plugin diagnostics"
    ocp_ver=$(get_openshift_cluster_version)
    installed_ver=$(get_installed_version 2>/dev/null || echo "unknown")
    installed_mm=$(extract_major_minor "${installed_ver}")
    target_mm=$(extract_major_minor "${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}")

    print_info "OpenShift version: ${ocp_ver:-unknown} (RHACS 4.10 plugin requires OCP ${RHACS_CONSOLE_PLUGIN_MIN_OCP}+)"
    print_info "RHACS installed: ${installed_ver} (target ${target_mm} on channel ${RHACS_OPERATOR_CHANNEL:-stable})"

    if ! openshift_version_meets_console_plugin_requirement "${ocp_ver}"; then
        print_error "OpenShift ${ocp_ver:-unknown} is below ${RHACS_CONSOLE_PLUGIN_MIN_OCP} — RHACS console security integration is not supported on this cluster version"
    fi

    if [ -n "${installed_mm}" ] && version_gt "${target_mm}" "${installed_mm}"; then
        print_error "RHACS ${installed_mm} is below ${target_mm} — upgrade on channel ${RHACS_OPERATOR_CHANNEL:-stable} before the console plugin can work"
    fi

    if secured_cluster_present_for_console_plugin; then
        print_info "✓ SecuredCluster CR present in ${RHACS_NAMESPACE} (required to deploy the plugin)"
    else
        print_error "No SecuredCluster in ${RHACS_NAMESPACE} — the RHACS operator deploys the ConsolePlugin with SecuredCluster, not Central alone"
        print_info "Install SecuredCluster on this OpenShift cluster, then rerun this script"
    fi

    if oc get consoleplugin "${plugin_name}" &>/dev/null; then
        print_info "✓ ConsolePlugin CR '${plugin_name}' exists"
        verify_console_plugin_backend "${plugin_name}" || true
    else
        print_error "ConsolePlugin CR '${plugin_name}' not found"
        print_info "List plugins: oc get consoleplugins"
    fi

    local enabled_plugins
    enabled_plugins=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
    if echo "${enabled_plugins}" | tr ' ' '\n' | grep -qx "${plugin_name}"; then
        print_info "✓ '${plugin_name}' is listed in consoles.operator.openshift.io/cluster spec.plugins"
    else
        print_error "'${plugin_name}' is NOT enabled in consoles.operator.openshift.io/cluster spec.plugins"
        print_info "Enable: oc patch consoles.operator.openshift.io cluster --type=json -p='[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${plugin_name}\"}]'"
    fi

    oc get deployment console -n openshift-console -o jsonpath='Console pods ready: {.status.readyReplicas}/{.spec.replicas}{"\n"}' 2>/dev/null || true
    print_info "After fixes: hard-refresh the OpenShift console (Ctrl+Shift+R) and look for Security > Vulnerabilities in the navigation"
}

wait_for_rhacs_console_plugin() {
    local max_wait="${RHACS_CONSOLE_PLUGIN_WAIT_SEC:-600}"
    local elapsed=0
    local plugin_name=""

    print_info "Waiting for RHACS ConsolePlugin (up to ${max_wait}s; deployed with SecuredCluster)..."
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        plugin_name=$(find_rhacs_console_plugin_name 2>/dev/null || true)
        if [ -n "${plugin_name}" ] && oc get consoleplugin "${plugin_name}" &>/dev/null; then
            echo "${plugin_name}"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    return 1
}

enable_plugin_in_console_operator() {
    local plugin_name="$1"
    local console_json patched

    if ! command -v jq &>/dev/null; then
        print_error "jq is required to enable the RHACS Console plugin"
        return 1
    fi

    console_json=$(oc get consoles.operator.openshift.io cluster -o json 2>/dev/null || echo "")
    if [ -z "${console_json}" ]; then
        print_warn "Could not read consoles.operator.openshift.io/cluster"
        return 1
    fi

    if echo "${console_json}" | jq -e --arg p "${plugin_name}" '.spec.plugins[]? | select(. == $p)' &>/dev/null; then
        print_info "✓ RHACS Console plugin '${plugin_name}' is already enabled"
        return 0
    fi

    # Remove empty plugin entries (some clusters have spec.plugins: [""]).
    patched=$(echo "${console_json}" | jq --arg p "${plugin_name}" '
        .spec.plugins = ((.spec.plugins // []) | map(select(length > 0)) + [$p] | unique)
    ' -c)

    if oc patch consoles.operator.openshift.io cluster --type=merge \
        -p "{\"spec\":{\"plugins\":$(echo "${patched}" | jq -c '.spec.plugins')}}" 2>/dev/null; then
        print_info "✓ RHACS Console plugin '${plugin_name}' enabled in OpenShift Console"
        return 0
    fi

    if oc patch consoles.operator.openshift.io cluster --type=json \
        -p="[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${plugin_name}\"}]" 2>/dev/null; then
        print_info "✓ RHACS Console plugin '${plugin_name}' enabled in OpenShift Console"
        return 0
    fi

    print_warn "Could not patch Console to enable plugin '${plugin_name}'; requires cluster-admin"
    return 1
}

resolve_rhacs_console_plugin_name() {
    local plugin_name

    plugin_name=$(find_rhacs_console_plugin_name 2>/dev/null || true)
    if [ -n "${plugin_name}" ] && oc get consoleplugin "${plugin_name}" &>/dev/null; then
        echo "${plugin_name}"
        return 0
    fi

    plugin_name=$(wait_for_rhacs_console_plugin 2>/dev/null || true)
    if [ -n "${plugin_name}" ] && oc get consoleplugin "${plugin_name}" &>/dev/null; then
        echo "${plugin_name}"
        return 0
    fi

    plugin_name=$(get_rhacs_console_plugin_from_csv 2>/dev/null || true)
    if [ -n "${plugin_name}" ]; then
        echo "${plugin_name}"
        return 0
    fi

    echo "${RHACS_CONSOLE_PLUGIN_NAME:-advanced-cluster-security}"
}

wait_for_rhacs_target_version() {
    local target_mm="${1:-4.10}"
    local max_wait="${RHACS_VERSION_WAIT_SEC:-600}"
    local elapsed=0 installed_mm last_status_at=-999

    print_info "Waiting for RHACS ${target_mm} before enabling Console plugin (up to ${max_wait}s)..."
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        approve_pending_rhacs_installplans
        installed_mm=$(extract_major_minor "$(get_installed_version 2>/dev/null || echo "")")
        if [ -n "${installed_mm}" ] && ! version_gt "${target_mm}" "${installed_mm}"; then
            print_info "✓ RHACS at ${installed_mm} (target ${target_mm})"
            return 0
        fi
        if [ $((elapsed - last_status_at)) -ge 30 ] || [ "${elapsed}" -eq 0 ]; then
            print_info "RHACS version: ${installed_mm:-unknown} (target ${target_mm}, ${elapsed}s/${max_wait}s)"
            print_rhacs_upgrade_status
            last_status_at=${elapsed}
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    print_warn "RHACS not at ${target_mm} yet after ${max_wait}s; Console plugin may be unavailable until upgrade completes"
    print_rhacs_upgrade_status
    return 1
}

# Ensure RHACS OpenShift Console security plugin is registered and enabled (4.10+ vulnerability/VM views).
ensure_rhacs_console_plugin_enabled() {
    if [ "${RHACS_ENSURE_CONSOLE_PLUGIN:-1}" != "1" ]; then
        print_info "Skipping Console plugin enablement (RHACS_ENSURE_CONSOLE_PLUGIN=${RHACS_ENSURE_CONSOLE_PLUGIN})"
        return 0
    fi

    print_step "Ensuring RHACS OpenShift Console security plugin is enabled..."

    if ! oc get consoles.operator.openshift.io cluster &>/dev/null; then
        print_warn "Console operator resource not found; skipping Console plugin enablement"
        return 0
    fi

    local target_mm plugin_name installed_mm ocp_ver
    target_mm=$(extract_major_minor "${RHACS_VERSION:-${RHACS_DEFAULT_VERSION}}")
    ocp_ver=$(get_openshift_cluster_version)

    if ! openshift_version_meets_console_plugin_requirement "${ocp_ver}"; then
        print_error "OpenShift ${ocp_ver:-unknown} does not meet RHACS console plugin requirement (OCP ${RHACS_CONSOLE_PLUGIN_MIN_OCP}+)"
        print_warn "Upgrade OpenShift or use RHACS Central UI for vulnerability views until the cluster is on a supported OCP version"
        diagnose_rhacs_console_plugin
        return 0
    fi

    installed_mm=$(extract_major_minor "$(get_installed_version 2>/dev/null || echo "")")

    if [ "${RHACS_VERSION_UPGRADE_SKIPPED:-0}" = "1" ] || \
       { [ -n "${installed_mm}" ] && version_gt "${target_mm}" "${installed_mm}"; }; then
        print_warn "RHACS ${installed_mm:-unknown} is below ${target_mm}; skipping Console plugin (requires 4.10+ operator/Central/SecuredCluster)"
        print_info "Upgrade first: ensure subscription is on rhacs-${target_mm} (e.g. openshift-operators), then rerun this script"
        diagnose_rhacs_console_plugin
        return 0
    fi

    wait_for_rhacs_target_version "${target_mm}" || true
    installed_mm=$(extract_major_minor "$(get_installed_version 2>/dev/null || echo "")")
    if [ -n "${installed_mm}" ] && version_gt "${target_mm}" "${installed_mm}"; then
        print_warn "RHACS still at ${installed_mm} after wait; skipping Console plugin until upgrade completes"
        diagnose_rhacs_console_plugin
        return 0
    fi

    if ! secured_cluster_present_for_console_plugin; then
        print_error "No SecuredCluster in ${RHACS_NAMESPACE} — RHACS deploys the ConsolePlugin when SecuredCluster is installed on this cluster"
        print_info "Central-only installs do not surface Security > Vulnerabilities in the OpenShift console on this cluster"
        diagnose_rhacs_console_plugin
        return 0
    fi

    plugin_name=$(resolve_rhacs_console_plugin_name)
    print_info "Using console plugin name: ${plugin_name}"

    if ! oc get consoleplugin "${plugin_name}" &>/dev/null; then
        print_warn "ConsolePlugin CR '${plugin_name}' not found after ${RHACS_CONSOLE_PLUGIN_WAIT_SEC:-600}s"
        print_warn "Confirm RHACS operator CSV is 4.10+ and SecuredCluster is reconciled: oc get securedcluster,csv -n ${RHACS_NAMESPACE}"
    else
        print_info "Found ConsolePlugin CR: ${plugin_name}"
        verify_console_plugin_backend "${plugin_name}" || true
    fi

    if ! enable_plugin_in_console_operator "${plugin_name}"; then
        diagnose_rhacs_console_plugin
        return 0
    fi

    wait_for_console_operator_rollout || true
    verify_console_plugin_backend "${plugin_name}" || true

    print_info ""
    diagnose_rhacs_console_plugin
}

# Main function
main() {
    print_info "RHACS Installation Verification"
    print_info "================================="
    print_info "Defaults: version=${RHACS_VERSION}, channel=auto (prefers ${RHACS_OPERATOR_CHANNEL}), console plugin=${RHACS_CONSOLE_PLUGIN_NAME}"
    
    # Verify RHACS installation
    if ! verify_rhacs_installation; then
        print_error "RHACS installation verification failed"
        exit 1
    fi
    
    print_info ""
    
    # Verify route encryption
    if ! verify_route_encryption; then
        print_error "Route encryption verification failed"
        exit 1
    fi
    
    print_info ""
    
    # Check and update version (e.g. to 4.10) before enabling Console plugin
    check_and_update_version
    
    print_info ""
    
    # Ensure Console plugin is enabled after version update (Install Operator page: Console plugin = Enable)
    ensure_rhacs_console_plugin_enabled
    
    print_info ""
    print_info "================================="
    print_info "✓ RHACS verification complete!"
    print_info "================================="
}

# Run main only when executed directly (not when sourced by diagnose-console-plugin.sh).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
