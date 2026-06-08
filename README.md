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
| `RHACS_OPERATOR_CHANNEL` | No | `stable` | OLM subscription channel — **exported by default** so upgrades target RHACS 4.10 |
| `RHACS_USE_VERSION_PINNED_CHANNEL` | No | `0` | Set to `1` to use `rhacs-X.Y` channel names instead of `stable` |
| `RHACS_CONSOLE_PLUGIN_NAME` | No | `advanced-cluster-security` | OpenShift Console security plugin (4.10 vulnerability/VM views) |
| `RHACS_ENSURE_CONSOLE_PLUGIN` | No | `1` | Set to `0` to skip enabling the Console security plugin |
| `RHACS_SKIP_VERSION_UPDATE` | No | `0` | Set to `1` to keep installed version (no upgrade attempt) |
| `RHACS_FORCE_DOWNGRADE` | No | `false` | Allow downgrade when `RHACS_VERSION` is older |
| `SKIP_COLLECTOR_NETWORK_CONFIG` | No | `0` | Set to `1` to skip script 02 |
| `SKIP_BASIC_SETUP` | No | `0` | Set to `1` to skip basic-setup in root `install.sh` |
| `SKIP_MONITORING_SETUP` | No | `0` | Set to `1` to skip monitoring-setup in root `install.sh` |
| `SKIP_DEMO_APPS` | No | `0` | Set to `1` to skip demo-apps in root `install.sh` |
| `SKIP_PARASOL_INSURANCE` | No | `0` | Set to `1` to skip only Parasol Insurance |
| `PARASOL_IMAGE` | No | `quay.io/jfalkner1/parasol-insurance:latest` | Parasol Insurance container image |
| `PARASOL_NAMESPACE` | No | `parasol-insurance` | Namespace for Parasol Insurance |
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

Script `04-deploy-applications.sh` from rhacs-demo is not included. Root `install.sh` deploys **Parasol Insurance** via `demo-apps/` ([quay.io/jfalkner1/parasol-insurance:latest](https://quay.io/repository/jfalkner1/parasol-insurance?tab=tags&tag=latest)). Skip with `SKIP_DEMO_APPS=1`.

After `basic-setup`, root `install.sh` runs **monitoring-setup** (Cluster Observability Operator, Prometheus scrape of Central `/metrics`, Perses dashboards, certificate auth). See [monitoring-setup/README.md](monitoring-setup/README.md).

| Script | Description | Requires Token |
|--------|-------------|----------------|
| `monitoring-setup/install.sh` | COO stack, Perses dashboards, Monitoring auth provider | **Yes** |
| `monitoring-setup/01-setup-certificates.sh` | CA + client certs for Prometheus scrape auth | No |
| `monitoring-setup/02-install-monitoring.sh` | MonitoringStack, ScrapeConfig, Perses | No |
| `monitoring-setup/03-configure-rhacs-auth.sh` | Declarative role + User-Certificate auth provider | **Yes** |

Monitoring manifests default to namespace `stackrox` (standard RHACS install). Set `RHACS_NAMESPACE` if your Central runs elsewhere.

## Relationship to rhacs-demo

| Repo | Purpose |
|------|---------|
| **general-ACS-setup** (this repo) | Shared ACS Central post-install + Prometheus monitoring for all environments |
| **rhacs-demo** | Full presenter workshop with demo apps, FAM, MCP, Splunk, and lab content |

Use this repo when you need consistent Central configuration and monitoring without demo-specific add-ons.

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
bash monitoring-setup/install.sh
bash demo-apps/install.sh
```

### Parasol Insurance only

```bash
oc apply -f demo-apps/parasol-insurance/k8s.yaml
oc get route parasol-insurance -n parasol-insurance -o jsonpath='https://{.spec.host}{"\n"}'
```

### Rerun full setup

```bash
source ~/.bashrc
./install.sh
```

### OpenShift Console security plugin not showing

The RHACS 4.10 console integration requires **all** of the following on the **same** OpenShift cluster:

1. **OpenShift 4.19+** (per [RHACS 4.10 docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.10/html/configuring/accessing-vulnerability-information-in-web-console))
2. **RHACS 4.10** Central and SecuredCluster (operator on channel `stable`)
3. **SecuredCluster** installed in `stackrox` — Central alone does not deploy the plugin
4. `advanced-cluster-security` in `consoles.operator.openshift.io/cluster` `spec.plugins`
5. OpenShift Console rollout complete (hard-refresh browser: Ctrl+Shift+R)

Diagnose:

```bash
source ~/.bashrc
bash basic-setup/diagnose-console-plugin.sh
```

Quick checks:

```bash
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
oc get csv -A | grep rhacs
oc get securedcluster,consoleplugin -n stackrox
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}'
oc get deployment console -n openshift-console
```

## What This Does NOT Cover

- RHACS Operator / Central installation
- SecuredCluster init bundle generation
- Demo workloads and integrations (Splunk, MCP, FAM, Tekton, GitOps policies) — see [rhacs-demo](https://github.com/mfosterrox/rhacs-demo)
- Non-OpenShift Kubernetes clusters
