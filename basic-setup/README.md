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
| `RHACS_OPERATOR_CHANNEL` | `stable` | OLM channel — exported by default for RHACS 4.10 upgrades |
| `RHACS_USE_VERSION_PINNED_CHANNEL` | `0` | Use `rhacs-X.Y` channels when set to `1` |
| `RHACS_CONSOLE_PLUGIN_NAME` | `advanced-cluster-security` | OpenShift Console security plugin |
| `RHACS_ENSURE_CONSOLE_PLUGIN` | `1` | Enable Console security plugin after upgrade (set `0` to skip) |
| `RHACS_SKIP_VERSION_UPDATE` | `0` | Set to `1` to skip version management |
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

By default the script upgrades to **4.10** (`RHACS_DEFAULT_VERSION`) using the OLM **`stable`** operator channel (per [Red Hat RHACS 4.10 upgrade docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.10/html/upgrading/upgrade-operator)). Override with `RHACS_VERSION` or disable with `RHACS_SKIP_VERSION_UPDATE=1`.

If your subscription is pinned to `rhacs-4.9` (or the script previously targeted `rhacs-4.10`), the channel will not advance to 4.10. The setup script patches the subscription to `stable` unless you set `RHACS_OPERATOR_CHANNEL` or `RHACS_USE_VERSION_PINNED_CHANNEL=1`.

The script checks the **catalog** on the target channel (not only the installed CSV). If `stable` in `openshift-marketplace` cannot provide 4.10 yet, the upgrade is skipped with available channels listed in the log.

| Current | Target (default) | `stable` catalog | Result |
|---------|------------------|------------------|--------|
| 4.9.2 on `rhacs-4.9` | 4.10 (default) | 4.9.2 only | Skipped — refresh catalog or wait for 4.10 on `stable` |
| 4.9.2 on `rhacs-4.9` | 4.10 | 4.10.x | Patches channel to `stable`, upgrades |
| 4.9.2 | — | any | No upgrade if `RHACS_SKIP_VERSION_UPDATE=1` |
| 4.9.3 | 4.9.2 | 4.9.2 | Refuses downgrade unless `RHACS_FORCE_DOWNGRADE=true` |

Manual channel fix:

```bash
oc get subscription -A | grep rhacs
oc patch subscription rhacs-operator -n <namespace> --type=merge -p='{"spec":{"channel":"stable"}}'
oc get packagemanifest rhacs-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}{"\n"}'
```

## OpenShift Console Security Plugin

RHACS 4.10 ships a dynamic OpenShift Console plugin (`advanced-cluster-security`) that surfaces vulnerability data in the console — including VM workloads on OpenShift Virtualization. The setup script:

1. Upgrades to 4.10 on channel `stable`
2. Waits for the `ConsolePlugin` CR
3. Patches `consoles.operator.openshift.io/cluster` to enable the plugin

Disable with `RHACS_ENSURE_CONSOLE_PLUGIN=0` if you do not want console integration.

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
