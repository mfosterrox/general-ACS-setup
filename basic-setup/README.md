# ACS Central Basic Setup

Core post-install configuration scripts for RHACS Central. Used by [general-ACS-setup](../README.md) across all OpenShift environments.

## Overview

The `install.sh` script orchestrates numbered setup scripts in sequence:

1. Installs `roxctl` CLI if not present
2. Validates `ROX_API_TOKEN` from `~/.bashrc`
3. Runs configuration scripts 01, 02, 03, 05, 06, 07

## Environment Variables

### Required (in `~/.bashrc`)

```bash
export ROX_API_TOKEN="<admin-scoped-api-token>"
export ROX_CENTRAL_ADDRESS="https://central-stackrox.apps.<cluster-domain>"
```

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `RHACS_NAMESPACE` | `stackrox` | RHACS install namespace |
| `RHACS_ROUTE_NAME` | `central` | Route name for URL discovery |
| `RHACS_VERSION` | `4.10` | Target version (defaults to `RHACS_DEFAULT_VERSION`) |
| `RHACS_DEFAULT_VERSION` | `4.10` | Latest stable default upgrade target |
| `RHACS_OPERATOR_CHANNEL` | `stable` | Preferred OLM channel (tried first when auto-resolution is on) |
| `RHACS_AUTO_OPERATOR_CHANNEL` | `1` | Auto-switch subscription to `rhacs-4.10` (etc.) when `stable` cannot provide target |
| `RHACS_OPERATOR_NAMESPACE` | `openshift-operators` | Subscription namespace for AllNamespaces operator installs |
| `RHACS_USE_VERSION_PINNED_CHANNEL` | `0` | Use `rhacs-X.Y` channels only when set to `1` |
| `RHACS_CONSOLE_PLUGIN_NAME` | `advanced-cluster-security` | OpenShift Console security plugin |
| `RHACS_ENSURE_CONSOLE_PLUGIN` | `1` | Enable Console security plugin after upgrade (set `0` to skip) |
| `RHACS_SKIP_VERSION_UPDATE` | `0` | Set to `1` to skip version management |
| `RHACS_USE_LIVE_CATALOG` | `1` | Auto-switch `redhat-operators-snapshot` → `redhat-operators` |
| `RHACS_FIX_ARGOCD_CATALOG_DRIFT` | `1` | Patch Argo CD `ignoreDifferences` so GitOps does not revert catalog source |
| `RHACS_OPERATOR_CSV_WAIT_SEC` | `600` | Wait for operator CSV to reach target before Central wait |
| `RHACS_CENTRAL_UPGRADE_WAIT_SEC` | `600` | Wait for Central deployment to reach target version |
| `RHACS_FORCE_DOWNGRADE` | `false` | Allow downgrade to older version |
| `SKIP_COLLECTOR_NETWORK_CONFIG` | `0` | Skip script 02 |
| `ROX_NON_AGGREGATED_NETWORKS` | auto-detect | Manual CIDR override for collector |
| `SECURED_CLUSTER_NAME` | auto | SecuredCluster CR name override |
| `ALLOW_PASSWORD_TOKEN_GEN` | `0` | Deprecated password-based token fallback |
| `RHACS_CONSOLE_PLUGIN_NAME` | auto | Override ConsolePlugin name (default: `advanced-cluster-security`) |
| `RHACS_CONSOLE_PLUGIN_WAIT_SEC` | `180` | Seconds to wait for ConsolePlugin after SecuredCluster install |

## Quick Start

Clone and run from the **project root** (see [main README](../README.md) for full instructions):

```bash
source ~/.bashrc
git clone https://github.com/mfosterrox/general-ACS-setup.git
cd general-ACS-setup
chmod +x install.sh verify-setup.sh basic-setup/install.sh
./install.sh
./verify-setup.sh
```

Or run **basic-setup only** from this folder:

```bash
source ~/.bashrc
cd general-ACS-setup/basic-setup
chmod +x install.sh
./install.sh
```

## Setup Scripts

| Script | Description | Requires Token |
|--------|-------------|----------------|
| `install.sh` | Orchestrator — validates token, installs roxctl, runs scripts | N/A |
| `01-verify-rhacs-install.sh` | Verify RHACS, TLS, version, Console plugin | No |
| `02-configure-collector-networks.sh` | Configure `ROX_NON_AGGREGATED_NETWORKS` on Collector | No |
| `03-compliance-operator-install.sh` | Install Red Hat Compliance Operator | No |
| `05-configure-rhacs-settings.sh` | Configure metrics, retention, platform via API | **Yes** |
| `06-setup-co-scan-schedule.sh` | Create compliance scan schedules | **Yes** |
| `07-trigger-compliance-scan.sh` | Trigger immediate compliance scans | **Yes** |

## roxctl and curl Usage

`roxctl` expects `host:port` (no `https://` prefix):

```bash
ROX_ENDPOINT="${ROX_CENTRAL_ADDRESS#https://}"
roxctl -e "$ROX_ENDPOINT:443" central whoami
```

`curl` uses the full URL with Bearer token:

```bash
curl -k -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/auth/status"
```

## Version Management

By default the script upgrades to **4.10** (`RHACS_DEFAULT_VERSION`) and **auto-resolves** the OLM channel: tries `stable`, then `rhacs-4.10`, then `latest`, and patches the subscription in `openshift-operators` (typical AllNamespaces install). Override with `RHACS_VERSION` or disable with `RHACS_SKIP_VERSION_UPDATE=1`.

When `stable` only offers 4.9.2 but `rhacs-4.10` offers 4.10.3, the script patches:

```bash
oc patch subscription rhacs-operator -n openshift-operators --type=merge \
  -p='{"spec":{"channel":"rhacs-4.10"}}'
```

Set `RHACS_AUTO_OPERATOR_CHANNEL=0` and `RHACS_OPERATOR_CHANNEL=stable` to disable auto channel selection.

| Current | Target | `stable` | `rhacs-4.10` | Result |
|---------|--------|----------|--------------|--------|
| 4.9.2 | 4.10 | 4.9.2 | 4.10.3 | Auto-patches to `rhacs-4.10`, upgrades |
| 4.9.2 | 4.10 | 4.9.2 | missing | Skipped — catalog refresh needed |
| 4.9.2 | — | any | any | No upgrade if `RHACS_SKIP_VERSION_UPDATE=1` |

## OpenShift Console Security Plugin

RHACS 4.10 ships a dynamic OpenShift Console plugin (`advanced-cluster-security`) that surfaces vulnerability data in the console — including VM workloads on OpenShift Virtualization. The setup script:

1. Auto-resolves the operator channel (e.g. `rhacs-4.10` when `stable` lags) and upgrades to 4.10
2. Waits for the `ConsolePlugin` CR
3. Patches `consoles.operator.openshift.io/cluster` to enable the plugin

Disable with `RHACS_ENSURE_CONSOLE_PLUGIN=0` if you do not want console integration.

**Common failure causes**

| Symptom | Likely cause |
|---------|----------------|
| No `Security` menu in OpenShift console | OCP below 4.19, RHACS below 4.10, or plugin not in `spec.plugins` |
| `ConsolePlugin` CR missing | No SecuredCluster on this cluster (Central-only install) |
| Plugin enabled but UI empty | Console rollout pending — wait for `deployment/console` in `openshift-console` |

Run diagnostics without changing the cluster:

```bash
bash basic-setup/diagnose-console-plugin.sh
```

## What Gets Configured

### Collector Networks (Script 02)

Patches SecuredCluster to set `ROX_NON_AGGREGATED_NETWORKS` for non-RFC1918 pod/service CIDRs common on showroom clusters.

```bash
# Manual override
export ROX_NON_AGGREGATED_NETWORKS="172.231.0.0/16"

# Skip
export SKIP_COLLECTOR_NETWORK_CONFIG=1
```

### RHACS Settings (Script 05)

- Telemetry enabled
- Metrics collection (1-minute interval)
- Retention policies (alerts, runtime, vulnerabilities, reports)
- Platform component recognition

### Compliance Scanning (Scripts 06–07)

- Daily scan schedules for OpenShift compliance profiles
- Optional immediate scan trigger

## Individual Script Execution

```bash
source ~/.bashrc

bash basic-setup/01-verify-rhacs-install.sh
bash basic-setup/02-configure-collector-networks.sh
bash basic-setup/03-compliance-operator-install.sh
bash basic-setup/05-configure-rhacs-settings.sh   # requires ROX_API_TOKEN
bash basic-setup/06-setup-co-scan-schedule.sh   # requires ROX_API_TOKEN
bash basic-setup/07-trigger-compliance-scan.sh  # requires ROX_API_TOKEN
```

## Troubleshooting

### Token validation fails

```bash
curl -k -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/auth/status"
```

Ensure the token has Admin scope and has not expired.

### Missing variables

```bash
export ROX_CENTRAL_ADDRESS="https://central-stackrox.apps.your-cluster.com"
export ROX_API_TOKEN="your-token-here"
export RHACS_NAMESPACE="stackrox"
source ~/.bashrc
```

### RHACS not ready

```bash
oc get deployment central -n stackrox
oc wait --for=condition=available --timeout=300s deployment/central -n stackrox
```
