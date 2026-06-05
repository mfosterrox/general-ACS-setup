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
| `RHACS_VERSION` | — | Target version (e.g. `4.10`); unset = no upgrade attempt |
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

When `RHACS_VERSION` is **unset**, the script keeps the installed version and does not attempt an upgrade.

When `RHACS_VERSION` is set, the script upgrades only if the operator catalog can provide that version. If the catalog maxes out lower (e.g. operator has 4.9.2 but target is 4.10), the upgrade is skipped with a warning and setup continues.

| Current | `RHACS_VERSION` | Catalog latest | Result |
|---------|-----------------|----------------|--------|
| 4.9.2 | (unset) | 4.9.2 | No upgrade |
| 4.9.2 | 4.10 | 4.9.2 | Skipped — catalog cannot provide 4.10 |
| 4.9.2 | 4.9 | 4.9.2 | Refuses downgrade unless `RHACS_FORCE_DOWNGRADE=true` |

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
