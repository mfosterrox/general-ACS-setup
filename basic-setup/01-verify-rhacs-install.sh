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
RHACS_OPERATOR_NAMESPACE="${RHACS_OPERATOR_NAMESPACE:-rhacs-operator}"

# Target version when set via RHACS_VERSION (empty = keep installed version, no upgrade attempt)
RHACS_VERSION="${RHACS_VERSION:-}"

# Namespaces to search for the RHACS OLM subscription (comma- or space-separated override)
RHACS_SUBSCRIPTION_SEARCH_NAMESPACES="${RHACS_SUBSCRIPTION_SEARCH_NAMESPACES:-${RHACS_OPERATOR_NAMESPACE} openshift-operators ${RHACS_NAMESPACE}}"

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

# Function to get latest available RHACS version from operator (CSV).
# Returns the version the operator can provide (e.g. from CSV metadata).
get_latest_available_version() {
    local csv_name
    csv_name=$(get_rhacs_csv_name)
    if [ -z "${csv_name}" ]; then
        get_version_from_deployment_label
        return
    fi
    local csv_ns
    csv_ns=$(get_rhacs_csv_namespace)
    # CSV name format: rhacs-operator.v4.10.0 or similar
    if [[ "${csv_name}" =~ \.v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        # Try spec.version from CSV
        oc get csv "${csv_name}" -n "${csv_ns}" -o jsonpath='{.spec.version}' 2>/dev/null || get_version_from_deployment_label
    fi
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

# Get the RHACS CSV name. Checks operator namespace first, then RHACS namespace.
# Returns e.g. rhacs-operator.v4.9.3. Empty if not found.
get_rhacs_csv_name() {
    local csv
    csv=$(oc get csv -n "${RHACS_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep rhacs-operator | head -1 | sed 's|.*/||')
    if [ -n "${csv}" ]; then
        echo "${csv}"
        return
    fi
    oc get csv -n "${RHACS_NAMESPACE}" -o name 2>/dev/null | grep rhacs-operator | head -1 | sed 's|.*/||' || echo ""
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
# Uses RHACS_VERSION as target when set. Skips upgrade when operator catalog cannot provide target.
check_and_update_version() {
    print_step "Checking RHACS version..."

    if [ -z "${RHACS_VERSION}" ]; then
        local installed_only
        installed_only=$(get_installed_version)
        if [ -n "${installed_only}" ]; then
            print_info "RHACS_VERSION not set — keeping installed version: ${installed_only}"
        else
            print_info "RHACS_VERSION not set — skipping version management"
        fi
        return 0
    fi

    local target_version="${RHACS_VERSION}"
    print_info "Target version: ${target_version}"
    
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
    
    # Latest from operator (after channel switch; informational)
    local latest_version
    latest_version=$(get_latest_available_version)
    if [ -n "${latest_version}" ]; then
        print_info "Latest available version from operator: ${latest_version}"
    fi

    local target_major_minor
    target_major_minor=$(extract_major_minor "${target_version}")
    local installed_major_minor
    installed_major_minor=$(extract_major_minor "${installed_version}")
    local latest_major_minor=""
    if [ -n "${latest_version}" ]; then
        latest_major_minor=$(extract_major_minor "${latest_version}")
        if version_gt "${target_major_minor}" "${latest_major_minor}"; then
            print_warn "Target ${target_version} is not available from the installed operator catalog (latest: ${latest_version})"
            print_warn "Skipping upgrade. Install a newer RHACS operator catalog or set RHACS_VERSION=${latest_major_minor}"
            print_info "Continuing setup with installed version: ${installed_version}"
            return 0
        fi
    fi
    
    # Already at target: same minor = stable (4.10.x follows 4.10 channel)
    if [ "${installed_version}" != "unknown" ] && [ "${target_major_minor}" = "${installed_major_minor}" ]; then
        print_info "✓ RHACS is already on ${target_version} channel (installed: ${installed_version})"
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

# Map target minor version to operator channel (e.g. 4.10 -> rhacs-4.10)
# Red Hat catalog uses rhacs-4.x channel names.
get_channel_for_version() {
    local ver=$1
    local major_minor=""
    if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
        major_minor="${BASH_REMATCH[1]}"
        echo "rhacs-${major_minor}"
    else
        echo "rhacs-4.10"
    fi
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
    desired_channel=$(get_channel_for_version "${target_version}")
    local sub_name sub_ns
    sub_name=$(get_rhacs_subscription_name)
    sub_ns=$(get_rhacs_subscription_namespace)
    if [ -z "${sub_name}" ]; then
        print_info "No RHACS subscription found (searched: ${RHACS_SUBSCRIPTION_SEARCH_NAMESPACES}); skipping subscription channel update"
        return 1
    fi
    local current_channel
    current_channel=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    if [ "${current_channel}" = "${desired_channel}" ]; then
        print_info "Subscription already on channel: ${desired_channel} (namespace ${sub_ns})"
        return 2
    fi
    print_step "Setting subscription channel: ${current_channel:-unknown} -> ${desired_channel} for version ${target_version} (namespace ${sub_ns})..."
    if ! oc patch subscriptions.operators.coreos.com "${sub_name}" -n "${sub_ns}" --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/channel\",\"value\":\"${desired_channel}\"}]" 2>/dev/null; then
        print_warn "Could not set subscription channel to ${desired_channel}"
        return 1
    fi
    print_info "Waiting for operator to reconcile to ${desired_channel}, 60s..."
    sleep 60
    return 0
}

# Get the name of the Central CR in RHACS_NAMESPACE (e.g. "central" or "stackrox-central-services").
# Empty if no Central CR exists.
get_central_cr_name() {
    oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Function to update RHACS version
update_rhacs_version() {
    local target_version=$1
    local target_major_minor
    target_major_minor=$(extract_major_minor "${target_version}")
    local upgrade_initiated=false

    print_info "Updating RHACS to version ${target_version}..."

    # Discover Central CR name (operator may use "central" or "stackrox-central-services")
    local central_cr_name
    central_cr_name=$(get_central_cr_name)

    if [ -n "${central_cr_name}" ]; then
        print_info "Updating Central resource (${central_cr_name})..."

        local sub_rc=0
        ensure_subscription_channel_for_version "${target_version}" || sub_rc=$?
        if [ "${sub_rc}" -eq 0 ]; then
            upgrade_initiated=true
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
            upgrade_initiated=true
        else
            print_info "Central has no custom image; upgrade depends on operator subscription/CSV channel"
        fi

        if [ "${upgrade_initiated}" != "true" ]; then
            if ensure_csv_deploy_version "${target_version}"; then
                upgrade_initiated=true
            fi
        fi

        local installed_now
        installed_now=$(get_installed_version)
        local installed_mm
        installed_mm=$(extract_major_minor "${installed_now}")

        if [ "${upgrade_initiated}" != "true" ]; then
            print_warn "No upgrade action was applied (no subscription channel change, Central image, or CSV patch)"
            print_warn "Remaining on installed version: ${installed_now:-unknown}"
            return 0
        fi

        if [ -n "${installed_mm}" ] && [ "${installed_mm}" = "${target_major_minor}" ]; then
            print_info "✓ RHACS already at target version ${installed_now}"
            return 0
        fi

        print_info "Waiting for Central to reach ${target_version} (current: ${installed_now:-unknown})..."
        local max_wait=600
        local elapsed=0
        local last_reported_ver=""
        while [ "${elapsed}" -lt "${max_wait}" ]; do
            local current_ver current_mm
            current_ver=$(get_installed_version)
            current_mm=$(extract_major_minor "${current_ver}")

            if [ -n "${current_mm}" ] && [ "${current_mm}" = "${target_major_minor}" ]; then
                if oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=120s 2>/dev/null; then
                    print_info "✓ Central at target version ${current_ver}, rollout complete"
                    return 0
                fi
            fi

            if [ "${current_ver}" != "${last_reported_ver}" ]; then
                print_info "Central version: ${current_ver:-unknown} (waiting for ${target_major_minor})..."
                last_reported_ver="${current_ver}"
            fi

            sleep 20
            elapsed=$((elapsed + 20))
        done

        print_warn "Timeout waiting for version ${target_version}. Current: $(get_installed_version)"
        print_warn "Check operator channel/CSV and Central CR: oc get subscription,csv -A | grep rhacs; oc get central -n ${RHACS_NAMESPACE} -o yaml"
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
get_rhacs_console_plugin_from_csv() {
    local csv_name csv_ns plugins_json
    csv_name=$(get_rhacs_csv_name)
    csv_ns=$(get_rhacs_csv_namespace)
    if [ -z "${csv_name}" ]; then
        return 1
    fi
    plugins_json=$(oc get csv "${csv_name}" -n "${csv_ns}" -o jsonpath='{.metadata.annotations.console\.openshift\.io/plugins}' 2>/dev/null || echo "")
    if [ -n "${plugins_json}" ] && command -v jq &>/dev/null; then
        echo "${plugins_json}" | jq -r '.[0] // empty' 2>/dev/null
        return 0
    fi
    return 1
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

wait_for_rhacs_console_plugin() {
    local max_wait="${RHACS_CONSOLE_PLUGIN_WAIT_SEC:-180}"
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

    if echo "${console_json}" | jq -e '.spec.plugins | type == "array"' &>/dev/null; then
        if oc patch consoles.operator.openshift.io cluster --type=json \
            -p="[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${plugin_name}\"}]" 2>/dev/null; then
            print_info "✓ RHACS Console plugin '${plugin_name}' enabled in OpenShift Console"
            return 0
        fi
    fi

    patched=$(echo "${console_json}" | jq --arg p "${plugin_name}" '.spec.plugins = ((.spec.plugins // []) + [$p] | unique)' -c)
    if oc patch consoles.operator.openshift.io cluster --type=merge -p "{\"spec\":{\"plugins\":$(echo "${patched}" | jq -c '.spec.plugins')}}" 2>/dev/null; then
        print_info "✓ RHACS Console plugin '${plugin_name}' enabled in OpenShift Console"
        return 0
    fi

    print_warn "Could not patch Console to enable plugin '${plugin_name}'; requires cluster-admin"
    return 1
}

# Ensure RHACS OpenShift Console plugin is registered (ConsolePlugin CR) and enabled in console-operator.
ensure_rhacs_console_plugin_enabled() {
    print_step "Ensuring RHACS Console plugin is enabled..."

    if ! oc get consoles.operator.openshift.io cluster &>/dev/null; then
        print_warn "Console operator resource not found; skipping Console plugin enablement"
        return 0
    fi

    local plugin_name installed_mm
    plugin_name=$(find_rhacs_console_plugin_name 2>/dev/null || true)

    if [ -z "${plugin_name}" ] || ! oc get consoleplugin "${plugin_name}" &>/dev/null; then
        plugin_name=$(wait_for_rhacs_console_plugin 2>/dev/null || true)
    fi

    if [ -z "${plugin_name}" ] || ! oc get consoleplugin "${plugin_name}" &>/dev/null; then
        installed_mm=$(extract_major_minor "$(get_installed_version 2>/dev/null || echo "")")
        print_warn "RHACS ConsolePlugin CR not found on the cluster"
        if [ -n "${installed_mm}" ] && version_gt "4.10" "${installed_mm}"; then
            print_warn "OpenShift console integration requires RHACS 4.10+ (installed: ${installed_mm})"
        else
            print_warn "Ensure a SecuredCluster is installed and the RHACS Operator was installed with Console plugin enabled"
            print_warn "Operator UI: Installed Operators → RHACS → Console plugin → Enable"
            print_warn "Or reinstall operator with Console plugin enabled; plugin name is typically: advanced-cluster-security"
        fi
        print_info "After ConsolePlugin exists, rerun: bash basic-setup/01-verify-rhacs-install.sh"
        return 0
    fi

    print_info "Found ConsolePlugin: ${plugin_name}"
    enable_plugin_in_console_operator "${plugin_name}"
}

# Main function
main() {
    print_info "RHACS Installation Verification"
    print_info "================================="
    
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

# Run main function
main "$@"
