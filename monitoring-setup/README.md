# RHACS Monitoring Setup

Part of [general-ACS-setup](../README.md). Installed automatically by root `./install.sh` after `basic-setup` (skip with `SKIP_MONITORING_SETUP=1`).

Scripts and configurations to set up monitoring for Red Hat Advanced Cluster Security (RHACS) using the Cluster Observability Operator.

## Overview

The monitoring setup enables Prometheus to scrape metrics from RHACS Central API service on the `/metrics` endpoint (port 443/HTTPS). The access requires proper authentication and authorization.

This setup aligns with:
- [RHACS 4.10 Monitoring documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.10/html/configuring/monitor-acs) (15.2.1, 15.4.3, 15.4.4)
- [stackrox/monitoring-examples](https://github.com/stackrox/monitoring-examples) (cluster-observability-operator, perses, rhacs)

## Prerequisites

- OpenShift or Kubernetes cluster with RHACS installed
- Cluster Observability Operator installed (for OpenShift)
- `oc` CLI tool (logged in)
- `openssl` tool
- `ROX_API_TOKEN` and `ROX_CENTRAL_ADDRESS` in `~/.bashrc` (same as basic-setup)
- RHACS installed in the `stackrox` namespace (`RHACS_NAMESPACE`; YAML manifests use `stackrox` by default)

## Environment Variables

The scripts use the following environment variables:

- `ROX_CENTRAL_ADDRESS`: Full URL to RHACS Central (e.g., `https://central-stackrox.apps.cluster.com`)
- `ROX_API_TOKEN`: API token for authentication

**Important for `roxctl` usage:**

The `roxctl` CLI expects `host:port` format for the `-e` flag and defaults to `https://`. If your `ROX_CENTRAL_ADDRESS` includes `https://`, strip it before using with `roxctl`:

```bash
# Correct usage with roxctl
export ROX_CENTRAL_ADDRESS="https://central-stackrox.apps.cluster.com"
ROX_ENDPOINT="${ROX_CENTRAL_ADDRESS#https://}"  # Strips https:// prefix
roxctl -e "$ROX_ENDPOINT:443" central userpki list

# Alternative: use the helper function in the scripts
ROX_ENDPOINT=$(get_rox_endpoint)
roxctl -e "$ROX_ENDPOINT:443" central userpki list
```

For `curl` commands, use the full URL with `https://`:

```bash
# Correct usage with curl
curl -k -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/auth/status"
```

## Quick Start

### Automated Setup

From the repo root (runs basic-setup then monitoring):

```bash
source ~/.bashrc
./install.sh
```

Or monitoring only:

```bash
source ~/.bashrc
cd monitoring-setup
./install.sh
```

**What this script does:**

The installation is broken into three modular scripts:

1. **`01-setup-certificates.sh`** - Certificate Generation
   - Creates CA certificate for auth provider
   - Generates client certificate for Prometheus
   - Creates Kubernetes secret for monitoring stack
   - Exports TLS_CERT environment variable

2. **`02-install-monitoring.sh`** - Monitoring Stack Installation
   - Disables OpenShift monitoring on Central (per docs 15.2.1)
   - Installs Cluster Observability Operator (MonitoringStack, ScrapeConfig)
   - Applies Prometheus Operator resources if CRD exists (prometheus-operator/)
   - Installs Perses UI plugin, datasource, and dashboard

3. **`03-configure-rhacs-auth.sh`** - RHACS Authentication Configuration
   - Applies declarative configuration (roles & permissions)
   - Enables declarative config mount on Central
   - Creates User-Certificate auth provider
   - Creates Admin group mapping for the auth provider

4. **Verification & Testing**
   - Validates group mappings exist
   - Tests client certificate authentication
   - Provides troubleshooting guidance

**Note**: The script is idempotent and safe to run multiple times.

### Manual Step-by-Step Setup

You can also run each script individually:

```bash
cd monitoring-setup

# Step 1: Generate certificates
./01-setup-certificates.sh

# Step 2: Install monitoring components
./02-install-monitoring.sh

# Step 3: Configure RHACS authentication
export ROX_CENTRAL_ADDRESS="https://your-central-url"
export ROX_API_TOKEN="your-api-token"
./03-configure-rhacs-auth.sh
```

### Option 2: Manual Setup

If you prefer to set up components individually:

1. **Generate TLS certificates for testing:**
   ```bash
   cd monitoring-examples/cluster-observability-operator
   ./generate-test-user-certificate.sh
   ```

2. **Apply RHACS declarative configuration:**
   ```bash
   kubectl apply -f monitoring-examples/rhacs/declarative-configuration-configmap.yaml
   ```

3. **Deploy monitoring stack:**
   ```bash
   kubectl apply -f monitoring-examples/cluster-observability-operator/monitoring-stack.yaml
   ```

4. **Configure scrape settings:**
   ```bash
   kubectl apply -f monitoring-examples/cluster-observability-operator/scrape-config.yaml
   ```

## Authentication Methods

RHACS supports multiple authentication methods for Prometheus:

### 1. API Token (Recommended for Production)

Create an API token in RHACS with the "Prometheus Server" role:

1. In RHACS UI: **Platform Configuration** → **Integrations** → **API Token**
2. Create a new token with "Prometheus Server" role
3. Store the token in a secret:
   ```bash
   export ROX_API_TOKEN='your-token-here'
   kubectl create secret generic stackrox-prometheus-api-token \
     -n stackrox \
     --from-literal=token="$ROX_API_TOKEN"
   ```

### 2. TLS Certificates (Testing)

For testing purposes, you can use TLS client certificates:

1. Generate certificates using the provided script:
   ```bash
   cd monitoring-examples/cluster-observability-operator
   ./generate-test-user-certificate.sh
   ```

2. Configure User Certificates auth provider in RHACS:
   - Go to **Platform Configuration** → **Access Control** → **Auth Providers**
   - Add a new User Certificates provider
   - Upload the certificate (`tls.crt`)
   - Create a user with the certificate's CN as Subject
   - Assign the "Prometheus Server" role

3. Test access:
   ```bash
   export ROX_CENTRAL_ADDRESS='https://your-central-url'
   curl --cert tls.crt --key tls.key $ROX_CENTRAL_ADDRESS/v1/auth/status
   ```

**Detailed Instructions**: See [CERTIFICATE-AUTH-GUIDE.md](CERTIFICATE-AUTH-GUIDE.md) for step-by-step configuration with screenshots and troubleshooting.

### 3. Service Account Token

You can also use Kubernetes service account tokens:

- **OpenShift OAuth provider**: Use long-lived service account token as client key
- **Short-lived projected token**: Configure via additional scrape config file
- **Generated token secret**: Create a secret of type `kubernetes.io/service-account-token`

## RHACS Configuration

### Permission Set and Role

The setup creates a permission set and role for Prometheus with read access to:

- Administration
- Alert
- Cluster
- Deployment
- Image
- Integration
- Namespace
- Node
- WorkflowAdministration

These permissions are defined in `monitoring-examples/rhacs/declarative-configuration-configmap.yaml`.

### Configuring Custom Metrics

RHACS exposes both fixed and customizable metrics:

**Fixed metrics** (gathered once per hour):
- `rox_central_health_cluster_info` - Cluster health
- `rox_central_cfg_total_policies` - Total policy numbers
- `rox_central_cert_exp_hours` - Certificate expiry

**Customizable metrics**:
- `rox_central_image_vuln_<name>` - Image vulnerabilities
- `rox_central_node_vuln_<name>` - Node vulnerabilities
- `rox_central_policy_violation_<name>` - Policy violations

To configure custom metrics:

```bash
# Get current configuration
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_ADDRESS/v1/config | jq

# Set custom metrics (example: image vulnerabilities)
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_ADDRESS/v1/config | \
  jq '.privateConfig.metrics.imageVulnerabilities = {
        gatheringPeriodMinutes: 10,
        descriptors: {
          deployment_severity: {
            labels: ["Cluster", "Namespace", "Deployment", "IsPlatformWorkload", "IsFixable", "Severity"]
          },
          namespace_severity: {
            labels: ["Cluster", "Namespace", "Severity"]
          }
        }
      } | { config: . }' | \
  curl -X PUT -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_ADDRESS/v1/config --data-binary @-
```

## Monitoring Stack

The Cluster Observability Operator deploys a namespaced monitoring stack that includes:

- **Prometheus**: Metrics collection and storage
- **Alertmanager**: Alert handling and routing
- **Thanos Querier**: Multi-cluster querying (optional)

### Configuration

The monitoring stack configuration (`monitoring-stack.yaml`) includes:

```yaml
spec:
  alertmanagerConfig:
    disabled: false
  prometheusConfig:
    replicas: 1
  resourceSelector:
    matchLabels:
      app: central
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 256Mi
  retention: 1d
```

### Accessing Prometheus UI

Forward the Prometheus port:

```bash
kubectl port-forward -n stackrox svc/sample-stackrox-monitoring-stack-prometheus 9090:9090
```

Then open http://localhost:9090 in your browser.

## Diagnostics

### Check Monitoring Resources

```bash
kubectl get all -n stackrox | grep -E "(prometheus|monitoring|alertmanager)"
```

### Check Secrets

```bash
kubectl get secrets -n stackrox | grep -E "(prometheus|tls|token)"
```

### Check MonitoringStack Status

```bash
kubectl get monitoringstack -n stackrox
kubectl describe monitoringstack sample-stackrox-monitoring-stack -n stackrox
```

### Check ScrapeConfig Status

```bash
kubectl get scrapeconfig -n stackrox
kubectl describe scrapeconfig sample-stackrox-scrape-config -n stackrox
```

### Test Authentication

**With TLS certificates:**
```bash
export ROX_CENTRAL_ADDRESS='https://your-central-url'
curl --cert tls.crt --key tls.key -k $ROX_CENTRAL_ADDRESS/v1/auth/status
curl --cert tls.crt --key tls.key -k $ROX_CENTRAL_ADDRESS/metrics
```

**With API token:**
```bash
export ROX_API_TOKEN='your-token-here'
export ROX_CENTRAL_ADDRESS='https://your-central-url'
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_ADDRESS/v1/auth/status
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_ADDRESS/metrics
```

### View Prometheus Logs

```bash
kubectl logs -n stackrox -l app.kubernetes.io/name=prometheus -f
```

## Troubleshooting

### Issue: Metrics work in Prometheus but not in OpenShift console

**Important:** The OpenShift **Observe → Metrics** page uses the platform Prometheus (openshift-monitoring), not the COO Prometheus in stackrox. RHACS metrics from the COO stack appear in **Perses dashboards**, not the default Metrics page.

**Where to find RHACS metrics in the console:**
1. Go to **Observe → Dashboards** (or **Observe → Monitoring** depending on OCP version)
2. Select the **RHACS Prometheus Datasource** from the datasource dropdown
3. Open the **Advanced Cluster Security / Overview** dashboard

**If the Perses dashboard section is missing or shows no data:**
- Ensure the COO namespace has the cluster-monitoring label: `oc label namespace openshift-cluster-observability-operator openshift.io/cluster-monitoring=true --overwrite`
- Verify Prometheus has data (COO uses StatefulSet): `oc exec -n stackrox statefulset/sample-stackrox-monitoring-stack-prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=sum(rox_central_policy_violation_namespace_severity)' 2>/dev/null` — or port-forward and open http://localhost:9090/graph
- Check that the UIPlugin has `spec.monitoring.perses.enabled: true`

### Issue: Dashboard shows "No data"

**If using Prometheus Operator** (monitoring.coreos.com): The install script applies `prometheus-operator/` when the Prometheus Operator CRD exists. Simply applying those files may be enough to get data into the OpenShift console.

**If using Cluster Observability Operator** (endpoints work locally but Prometheus not scraping):

If `curl --cert client.crt --key client.key -k $ROX_CENTRAL_ADDRESS/metrics` works but the dashboard shows no data, Prometheus may be failing TLS verification when scraping Central. The ScrapeConfig includes `insecureSkipVerify: true` to bypass server cert verification. Re-apply the scrape config:

```bash
oc apply -f monitoring-examples/cluster-observability-operator/scrape-config.yaml
# Restart Prometheus to pick up changes (if needed)
oc rollout restart statefulset -n stackrox -l app.kubernetes.io/name=prometheus 2>/dev/null || \
oc rollout restart deployment -n stackrox -l app.kubernetes.io/name=prometheus 2>/dev/null || true
```

Run the debug script to test connectivity at each step (RHACS → Prometheus → Perses):

```bash
cd monitoring-setup
export ROX_CENTRAL_ADDRESS="https://your-central-url"
./debug-monitoring.sh
```

Key checks:
- **Client cert auth**: `curl --cert client.crt --key client.key -k $ROX_CENTRAL_ADDRESS/v1/auth/status`
- **Metrics endpoint**: `curl --cert client.crt --key client.key -k $ROX_CENTRAL_ADDRESS/metrics | head -20`
- **Prometheus targets**: `oc port-forward -n stackrox svc/sample-stackrox-monitoring-stack-prometheus 9090:9090` then open http://localhost:9090/targets
- **Enable metrics**: Policy violations, image/node vulnerabilities are disabled by default. Enable in RHACS: **Platform Configuration → System Configuration → Prometheus metrics**

### Issue: Client certificate authentication fails with "credentials not found"

**Symptoms:** `curl --cert client.crt --key client.key -k $ROX_CENTRAL_ADDRESS/v1/auth/status` returns `{"code":16, "message":"credentials not found"}`

**Root cause:** The group mapping (role assignment) for the auth provider wasn't created or hasn't propagated yet.

**Solution:**

1. **Run the troubleshooting script:**
   ```bash
   cd monitoring-setup
   ./troubleshoot-auth.sh
   ```
   
   This script will:
   - Verify the auth provider is configured
   - Check if group mappings exist
   - Automatically create missing group mappings
   - Test client certificate authentication
   - Provide specific guidance based on the issue found

2. **Wait for propagation:** Auth changes can take 10-30 seconds to propagate. Wait a moment and test again.

3. **Manual fix via UI:**
   - Go to RHACS UI: **Platform Configuration** → **Access Control** → **Groups**
   - Create a new group:
     - **Auth Provider**: Monitoring
     - **Key**: (leave empty)
     - **Value**: (leave empty)
     - **Role**: Admin

4. **Manual fix via API:**
   ```bash
   # Get the auth provider ID
   AUTH_PROVIDER_ID=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
     "$ROX_CENTRAL_ADDRESS/v1/authProviders" | \
     grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)
   
   # Create the group
   curl -k -X POST "$ROX_CENTRAL_ADDRESS/v1/groups" \
     -H "Authorization: Bearer $ROX_API_TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"props\":{\"authProviderId\":\"$AUTH_PROVIDER_ID\",\"key\":\"\",\"value\":\"\"},\"roleName\":\"Prometheus Server\"}"
   ```

### Issue: Prometheus can't scrape RHACS metrics

**Symptoms:** No metrics appearing in Prometheus

**Solutions:**
1. Verify authentication is configured correctly
2. Check if the scrape config has the correct TLS settings
3. Verify the service CA certificate is available:
   ```bash
   kubectl get secret service-ca -n stackrox
   ```
4. Check Prometheus logs for errors:
   ```bash
   kubectl logs -n stackrox -l app.kubernetes.io/name=prometheus -f
   ```

### Issue: TLS certificate authentication fails

**Symptoms:** `curl --cert tls.crt --key tls.key` returns 401 or 403

**Solutions:**
1. Verify User Certificates auth provider is configured in RHACS
2. Ensure the certificate CN matches the expected format
3. Check if the certificate is properly uploaded in RHACS
4. Verify the "Prometheus Server" role is assigned

### Issue: API token authentication fails

**Symptoms:** `curl -H "Authorization: Bearer $ROX_API_TOKEN"` returns 401 or 403

**Solutions:**
1. Verify the API token is valid and not expired
2. Check if the token has the "Prometheus Server" role
3. Ensure the secret is created correctly:
   ```bash
   kubectl get secret stackrox-prometheus-api-token -n stackrox -o yaml
   ```

### Issue: MonitoringStack not deploying

**Symptoms:** MonitoringStack resource exists but Prometheus pods don't start

**Solutions:**
1. Check if Cluster Observability Operator is installed:
   ```bash
   kubectl get csv -A | grep observability
   ```
2. Check operator logs:
   ```bash
   kubectl logs -n openshift-operators -l app.kubernetes.io/name=cluster-observability-operator
   ```
3. Verify resource quotas and limits in the namespace

## Directory Structure

```
monitoring-setup/
├── README.md                           # This file
├── install.sh                          # Main orchestrator script
├── 01-setup-certificates.sh            # Certificate generation
├── 02-install-monitoring.sh            # Monitoring stack installation
├── 03-configure-rhacs-auth.sh          # RHACS auth configuration
├── debug-monitoring.sh                 # Debug "No data" on dashboard
├── troubleshoot-auth.sh                # Authentication troubleshooting
├── reset.sh                            # Cleanup script
└── monitoring-examples/                # Configuration examples
    ├── README.md                       # General overview
    ├── rhacs/                          # RHACS-specific configuration
    │   ├── README.md
    │   ├── declarative-configuration-configmap.yaml
    │   ├── auth-provider.json.tpl
    │   └── admin-group.json.tpl
    ├── cluster-observability-operator/ # COO configuration
    │   ├── README.md
    │   ├── subscription.yaml
    │   ├── monitoring-stack.yaml
    │   ├── scrape-config.yaml
    │   └── generate-test-user-certificate.sh
    ├── prometheus-operator/            # Prometheus Operator examples
    │   ├── README.md
    │   ├── prometheus.yaml
    │   └── additional-scrape-config.yaml
    └── perses/                         # Dashboard examples
        ├── README.md
        ├── dashboard.yaml
        ├── datasource.yaml
        └── ui-plugin.yaml
```

## Resources

- **RHACS Documentation**: [Red Hat Advanced Cluster Security for Kubernetes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/)
- **Cluster Observability Operator**: [OpenShift Monitoring Overview](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/)
- **Monitoring Examples Repository**: [stackrox/stackrox](https://github.com/stackrox/stackrox)

## License

See [LICENSE](monitoring-examples/LICENSE) file in the monitoring-examples directory.
