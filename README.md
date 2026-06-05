# general-ACS-setup

Post-install configuration for Red Hat Advanced Cluster Security (RHACS) Central across OpenShift environments — showroom labs, RHDP workshops, and customer demos.

This repo configures an **already-installed** RHACS Central deployment. It does not install the RHACS Operator or Central from scratch.

## Prerequisites

- RHACS Operator installed with Console plugin enabled
- RHACS Central and SecuredCluster running in namespace `stackrox` (or override `RHACS_NAMESPACE`)
- `oc login` with cluster-admin (or equivalent)
- `jq` and `curl` installed
- Admin-scoped API token saved to `~/.bashrc`

## Quick Start

### First-time setup

```bash
# 1. Set credentials in ~/.bashrc (one-time per environment)
cat >> ~/.bashrc <<'EOF'
export ROX_API_TOKEN="<admin-scoped-api-token>"
export ROX_CENTRAL_ADDRESS="https://central-stackrox.apps.<cluster-domain>"
EOF
source ~/.bashrc

# 2. Clone the repo
git clone https://github.com/mfosterrox/general-ACS-setup.git
cd general-ACS-setup

# 3. Run setup
chmod +x install.sh verify-setup.sh basic-setup/install.sh
./install.sh
./verify-setup.sh
```

### Update and rerun (existing clone)

```bash
source ~/.bashrc
cd general-ACS-setup
git pull origin main
./install.sh
./verify-setup.sh
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ROX_API_TOKEN` | **Yes** | — | Admin-scoped API token for RHACS Central |
| `ROX_CENTRAL_ADDRESS` | **Yes** | auto-detect | Full HTTPS URL to Central (`oc get route central`) |
| `RHACS_NAMESPACE` | No | `stackrox` | Namespace where RHACS is installed |
| `RHACS_ROUTE_NAME` | No | `central` | OpenShift route name for Central |
| `RHACS_VERSION` | No | `4.10` | Target version (defaults to latest stable via `RHACS_DEFAULT_VERSION`) |
| `RHACS_DEFAULT_VERSION` | No | `4.10` | Default upgrade target when `RHACS_VERSION` is unset |
| `RHACS_SKIP_VERSION_UPDATE` | No | `0` | Set to `1` to keep installed version (no upgrade attempt) |
| `RHACS_FORCE_DOWNGRADE` | No | `false` | Allow downgrade when `RHACS_VERSION` is older |
| `SKIP_COLLECTOR_NETWORK_CONFIG` | No | `0` | Set to `1` to skip script 02 |
| `SKIP_BASIC_SETUP` | No | `0` | Set to `1` to skip basic-setup in root `install.sh` |
| `ALLOW_PASSWORD_TOKEN_GEN` | No | `0` | Deprecated: generate token from `ROX_PASSWORD` if token missing |

## Setup Scripts

Executed in order by `basic-setup/install.sh`:

| Script | Description | Requires Token |
|--------|-------------|----------------|
| `01-verify-rhacs-install.sh` | Verify Central/Scanner, version management, Console plugin | No |
| `02-configure-collector-networks.sh` | Set `ROX_NON_AGGREGATED_NETWORKS` for non-RFC1918 CIDRs | No |
| `03-compliance-operator-install.sh` | Install Red Hat Compliance Operator | No |
| `05-configure-rhacs-settings.sh` | Configure metrics, retention, platform settings via API | **Yes** |
| `06-setup-co-scan-schedule.sh` | Create daily compliance scan schedules | **Yes** |
| `07-trigger-compliance-scan.sh` | Trigger immediate compliance scans | **Yes** |

Script `04-deploy-applications.sh` is intentionally excluded — demo workloads belong in environment-specific repos like [rhacs-demo](https://github.com/mfosterrox/rhacs-demo).

## Relationship to rhacs-demo

| Repo | Purpose |
|------|---------|
| **general-ACS-setup** (this repo) | Shared ACS Central post-install configuration for all environments |
| **rhacs-demo** | Full presenter workshop with demo apps, FAM, monitoring, MCP, Splunk, and lab content |

Use this repo when you need consistent Central configuration without demo-specific add-ons.

## Troubleshooting

### ROX_API_TOKEN not found

```bash
# Verify token is in ~/.bashrc
grep ROX_API_TOKEN ~/.bashrc

# Test token
curl -k -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/auth/status"
```

### ROX_CENTRAL_ADDRESS auto-detection

```bash
oc get route central -n stackrox -o jsonpath='https://{.spec.host}{"\n"}'
```

### Rerun a single script

```bash
source ~/.bashrc
bash basic-setup/05-configure-rhacs-settings.sh
```

### Rerun full setup

```bash
source ~/.bashrc
./install.sh
```

## What This Does NOT Cover

- RHACS Operator / Central installation
- SecuredCluster init bundle generation
- Demo workloads and integrations (Splunk, MCP, FAM, Tekton, GitOps policies)
- Non-OpenShift Kubernetes clusters
