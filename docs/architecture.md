# PayStream Authorization Service -- Architecture Document

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [Component Details](#2-component-details)
3. [Request Flow](#3-request-flow)
4. [Canary Deployment Flow](#4-canary-deployment-flow)
5. [Failure Modes](#5-failure-modes)
6. [Security Architecture](#6-security-architecture)
7. [Observability Architecture](#7-observability-architecture)

---

## 1. System Architecture

### High-Level Overview

The PayStream Authorization Service is a payment transaction authorization API
deployed on Kubernetes with progressive delivery via Argo Rollouts, traffic
management via Istio Ambient Mesh, and automated observability-driven canary
analysis. The system is designed so that every new release is validated against
production SLOs before it receives full traffic.

### Architecture Diagram

```
                          EXTERNAL CLIENTS
                               |
                               v
                  +------------------------+
                  |    Istio Gateway        |
                  |  (paystream-gateway)    |
                  |  paystream.local:80     |
                  +------------------------+
                               |
                               v
                  +------------------------+
                  |    VirtualService       |
                  |  (auth-service-vs)      |
                  |                        |
                  |  Weighted routing:      |
                  |  stable: W%  canary: X% |
                  +----------+-------------+
                       |              |
            +----------+              +----------+
            |                                    |
            v                                    v
  +-------------------+              +-------------------+
  | auth-service      |              | auth-service      |
  | STABLE ReplicaSet |              | CANARY ReplicaSet |
  | (3 replicas)      |              | (scaled by Argo)  |
  |                   |              |                   |
  |  Go HTTP :8080    |              |  Go HTTP :8080    |
  |  - /v1/authorize  |              |  - /v1/authorize  |
  |  - /health        |              |  - /health        |
  |  - /metrics       |              |  - /metrics       |
  |  - /admin/fault-  |              |  - /admin/fault-  |
  |    inject         |              |    inject         |
  +-------------------+              +-------------------+
            |                                    |
            +----------+   +---------------------+
                       |   |
                       v   v
              +-------------------+
              |    Prometheus     |
              |  scrape /metrics  |
              |  every 15s        |
              |  retention: 7d    |
              +--------+----------+
                       |
          +------------+------------+
          |                         |
          v                         v
  +--------------+         +------------------+
  | Grafana      |         | Argo Rollouts    |
  | Dashboards   |         | Controller       |
  | :3000        |         |                  |
  |              |         | AnalysisRun:     |
  | - P95 lat.   |         |  - P95 < 2.5s   |
  | - Success %  |         |  - Err rate < 1% |
  | - Req rate   |         |  - Success > 80% |
  | - CB state   |         |  - CB healthy    |
  | - Rollout    |         |                  |
  |   progress   |         | Actions:         |
  +--------------+         |  - Promote       |
                           |  - Abort/Rollback|
                           +------------------+

  +---------------------------------------------+
  |              SECRETS PIPELINE                |
  |                                             |
  |  HashiCorp Vault  -->  External Secrets     |
  |  (paystream/v2)        Operator             |
  |                        refreshInterval: 1m  |
  |                        --> K8s Secret:      |
  |                            auth-service-    |
  |                            secrets          |
  +---------------------------------------------+

  +---------------------------------------------+
  |              AMBIENT MESH (ztunnel)          |
  |                                             |
  |  All pods in the paystream namespace have   |
  |  automatic mTLS via ztunnel (no sidecars).  |
  |  Label: istio.io/dataplane-mode: ambient    |
  +---------------------------------------------+
```

### Namespace Layout

```
+----------------------------+     +----------------------------+
|  paystream (production)    |     |  paystream-staging         |
|                            |     |                            |
|  - auth-service (Rollout)  |     |  - auth-service (Rollout)  |
|  - prometheus              |     |  - vault-backend (ESO)     |
|  - grafana                 |     |  - auth-service-secrets    |
|  - vault                   |     +----------------------------+
|  - vault-backend (ESO)     |
|  - auth-service-secrets    |
|                            |
|  Both namespaces labeled:  |
|  istio.io/dataplane-mode:  |
|    ambient                 |
+----------------------------+
```

---

## 2. Component Details

| Component | Purpose | K8s Resource Type | Namespace |
|---|---|---|---|
| auth-service | Payment authorization API (Go) | `Rollout` (argoproj.io/v1alpha1) | paystream |
| auth-service (svc) | ClusterIP service routing all traffic to all pods | `Service` | paystream |
| auth-service-stable | Service selector for the stable ReplicaSet | `Service` | paystream |
| auth-service-canary | Service selector for the canary ReplicaSet | `Service` | paystream |
| auth-service-config | Runtime configuration (PORT, LATENCY_BASE_MS, SUCCESS_RATE, SERVICE_VERSION) | `ConfigMap` | paystream |
| auth-service-secrets | Sensitive credentials (BANK_API_KEY, DB_PASSWORD, ENCRYPTION_KEY) | `Secret` (managed by ESO) | paystream |
| auth-service-pdb | Ensures at most 1 replica unavailable during voluntary disruptions | `PodDisruptionBudget` | paystream |
| auth-service-netpol | Restricts ingress to Istio gateway, mesh traffic, and Prometheus; restricts egress to DNS and in-namespace | `NetworkPolicy` | paystream |
| auth-service-role | RBAC: read-only access to own secrets and configmaps | `Role` | paystream |
| auth-service-rolebinding | Binds Role to the auth-service ServiceAccount | `RoleBinding` | paystream |
| auth-service (SA) | Dedicated ServiceAccount with least-privilege RBAC | `ServiceAccount` | paystream |
| paystream-gateway | Istio ingress entry point on port 80 (HTTP) | `Gateway` (networking.istio.io/v1beta1) | paystream |
| auth-service-vs | Weighted traffic routing between stable and canary; retries on 5xx; 5s timeout | `VirtualService` (networking.istio.io/v1beta1) | paystream |
| auth-service-dr | Connection pooling (100 TCP, 10 req/conn) and outlier detection (5 consecutive 5xx, 30s ejection) | `DestinationRule` (networking.istio.io/v1beta1) | paystream |
| auth-service-health | AnalysisTemplate: P95 latency < 2.5s, error rate < 1% | `AnalysisTemplate` (argoproj.io/v1alpha1) | paystream |
| auth-service-success-rate | AnalysisTemplate: success rate > 80%, circuit breaker state < 1 (closed) | `AnalysisTemplate` (argoproj.io/v1alpha1) | paystream |
| prometheus | Metrics collection, alerting rule evaluation, 7-day retention | `Deployment` + `Service` (ClusterIP :9090) | paystream |
| prometheus-config | Prometheus scrape configuration with kubernetes_sd_configs | `ConfigMap` | paystream |
| alerting-rules | Alert rules: high latency, low success rate, circuit breaker open, canary degradation | `ConfigMap` | paystream |
| grafana | Visualization dashboards with anonymous read access | `Deployment` + `Service` (ClusterIP :3000) | paystream |
| grafana-datasource | Prometheus datasource provisioning for Grafana | `ConfigMap` | paystream |
| grafana-dashboards | Dashboard provider configuration for Grafana | `ConfigMap` | paystream |
| vault | HashiCorp Vault in dev mode for secrets storage | `Deployment` + `Service` (ClusterIP :8200) | paystream |
| vault-backend | SecretStore connecting ESO to Vault (paystream/v2 KV engine) | `SecretStore` (external-secrets.io/v1beta1) | paystream |
| auth-service-secrets (ESO) | ExternalSecret syncing Vault secrets to K8s every 1 minute | `ExternalSecret` (external-secrets.io/v1beta1) | paystream |
| vault-token | Vault authentication token for ESO | `Secret` | paystream |
| paystream | Production namespace with ambient mesh label | `Namespace` | -- |
| paystream-staging | Staging namespace with ambient mesh label | `Namespace` | -- |

---

## 3. Request Flow

This section describes the complete lifecycle of a `POST /v1/authorize` request
from the moment it arrives at the cluster to the moment the response is returned.

### Step-by-Step Flow

```
1. Client sends POST /v1/authorize
   Body: {"card_number":"4532...", "amount":150.00, "currency":"USD",
          "merchant":"Amazon", "processor":"visa_net"}

2. DNS resolves paystream.local to the Istio ingress gateway IP.

3. The Istio Gateway (paystream-gateway) accepts the connection on port 80
   and matches the host paystream.local.

4. The VirtualService (auth-service-vs) evaluates the routing rules:
   - Route name: "primary"
   - Timeout: 5s per request
   - Retry policy: 3 attempts, 2s per try, on 5xx/reset/connect-failure
   - Weighted destinations:
     * auth-service-stable: W% (e.g., 90% during canary)
     * auth-service-canary: X% (e.g., 10% during canary)

5. ztunnel (ambient mesh data plane) encrypts the connection with mTLS
   between the gateway and the selected pod. No sidecar is injected.

6. The DestinationRule (auth-service-dr) enforces:
   - Connection pool: max 100 TCP connections, 10 requests per connection
   - Outlier detection: eject endpoint after 5 consecutive 5xx errors,
     check every 30s, eject for 30s, eject at most 50% of endpoints

7. The request arrives at the Go HTTP server on port 8080.

8. AuthorizeHandler validates the request:
   a. Rejects non-POST methods (405 Method Not Allowed)
   b. Limits body to 1 MB (MaxBytesReader)
   c. Decodes JSON body into authorizeRequest struct

9. The handler wraps the authorization logic inside CircuitBreaker.Execute():
   a. If circuit breaker is OPEN: returns 503 Service Unavailable immediately
      with {"error":"service unavailable","reason":"circuit breaker open"}
   b. If CLOSED or HALF-OPEN: executes the authorization function:
      - Computes latency = LATENCY_BASE_MS + random jitter (-50ms to +50ms)
      - If fault injection is enabled, overrides latency and success rate
      - Simulates bank API call with time.Sleep(latency)
      - Rolls success based on SUCCESS_RATE probability
      - Returns "approved" or "declined" (declined counts as error for CB)

10. Circuit breaker state machine (sony/gobreaker):
    - Tracks consecutive failures
    - Trips to OPEN after 5 consecutive failures
    - After 30s in OPEN, transitions to HALF-OPEN
    - Allows 3 probe requests in HALF-OPEN
    - Returns to CLOSED if probes succeed, back to OPEN if they fail
    - State changes are logged and emitted as circuit_breaker_state metric

11. Prometheus metrics are recorded:
    - auth_request_duration_seconds histogram (version, status, processor)
    - auth_requests_total counter (version, status, processor)
    - auth_success_rate gauge (computed from atomic counters)
    - circuit_breaker_state gauge (0=closed, 1=half-open, 2=open)

12. Response is returned:
    HTTP 200 OK
    {"transaction_id":"txn-1708876543-0042", "status":"approved",
     "processor":"visa_net", "amount":150.00, "latency_ms":187,
     "version":"1.0.0"}

13. Prometheus scrapes the pod's /metrics endpoint every 15s,
    collecting the updated counters and histograms.
```

### Request Timing Budget

| Phase | Budget | Notes |
|---|---|---|
| Istio Gateway + VirtualService routing | < 5ms | ztunnel L4 processing |
| Authorization logic (bank API simulation) | 150--250ms | LATENCY_BASE_MS=200, jitter +/-50 |
| JSON serialization | < 1ms | Standard library encoder |
| **Total P95 target** | **< 2.5s** | **SLO enforced by AnalysisTemplate** |
| VirtualService timeout | 5s | Hard cutoff, returns 504 |
| Retry budget | 3 attempts x 2s | Only on 5xx/reset/connect-failure |

---

## 4. Canary Deployment Flow

### Overview

When a new image is pushed to DockerHub (triggered by a merge to master), the CD
pipeline updates the Rollout image, and Argo Rollouts orchestrates a progressive
canary release with automated analysis gates.

### Deployment Sequence

```
Phase 0: TRIGGER
  CI pipeline builds, tests, scans (Trivy), and pushes image to DockerHub
  CD pipeline triggers on CI success (workflow_run) or manual dispatch
  kubectl argo rollouts set image auth-service auth-service=<new-image>

Phase 1: CANARY 10%
  +------------------------------------------------------------+
  |  Argo Rollouts:                                            |
  |  1. Creates canary ReplicaSet with new image               |
  |  2. Updates VirtualService weights: stable=90, canary=10   |
  |  3. Runs AnalysisTemplate: auth-service-health             |
  |     - P95 latency < 2.5s  (5 checks, 30s interval,        |
  |                             fail limit: 2)                 |
  |     - Error rate < 1%     (5 checks, 30s interval,         |
  |                             fail limit: 2)                 |
  |  4. If analysis PASSES: proceed                            |
  |     If analysis FAILS: automatic rollback to stable        |
  +------------------------------------------------------------+

Phase 2: PAUSE (2 minutes)
  Traffic remains at 10% canary while operators can observe
  dashboards and optionally abort manually.

Phase 3: CANARY 50%
  +------------------------------------------------------------+
  |  Argo Rollouts:                                            |
  |  1. Updates VirtualService weights: stable=50, canary=50   |
  |  2. Runs AnalysisTemplate: auth-service-success-rate       |
  |     - Success rate > 80%  (5 checks, 30s interval,        |
  |                             fail limit: 1)                 |
  |     - Circuit breaker state < 1  (must be CLOSED)          |
  |       (5 checks, 30s interval, fail limit: 2)              |
  |  3. If analysis PASSES: proceed                            |
  |     If analysis FAILS: automatic rollback                  |
  +------------------------------------------------------------+

Phase 4: PAUSE (2 minutes)
  Traffic remains at 50% canary. Final observation window.

Phase 5: CANARY 100% (PROMOTION)
  +------------------------------------------------------------+
  |  Argo Rollouts:                                            |
  |  1. Updates VirtualService weights: stable=0, canary=100   |
  |  2. Scales down old stable ReplicaSet                      |
  |  3. Promotes canary ReplicaSet to become new stable        |
  |  4. Resets VirtualService: stable=100, canary=0            |
  +------------------------------------------------------------+

Rollback Window: Last 2 revisions are retained for instant rollback.
```

### Analysis Templates in Detail

**auth-service-health** (runs at 10% traffic):

| Metric | PromQL | Threshold | Checks | Fail Limit |
|---|---|---|---|---|
| P95 latency | `histogram_quantile(0.95, sum(rate(auth_request_duration_seconds_bucket{version="<canary>"}[2m])) by (le))` | < 2.5s | 5 @ 30s | 2 |
| Error rate | `1 - (sum(rate(auth_requests_total{version="<canary>",status="approved"}[2m])) / sum(rate(auth_requests_total{version="<canary>"}[2m])))` | < 0.01 (1%) | 5 @ 30s | 2 |

**auth-service-success-rate** (runs at 50% traffic):

| Metric | PromQL | Threshold | Checks | Fail Limit |
|---|---|---|---|---|
| Success rate | `sum(rate(auth_requests_total{version="<canary>",status="approved"}[2m])) / sum(rate(auth_requests_total{version="<canary>"}[2m]))` | > 0.80 (80%) | 5 @ 30s | 1 |
| Circuit breaker | `circuit_breaker_state` | < 1 (closed) | 5 @ 30s | 2 |

### Manual Operations

```bash
# Promote canary immediately (skip remaining steps)
kubectl argo rollouts promote auth-service -n paystream

# Abort canary and rollback to stable
kubectl argo rollouts abort auth-service -n paystream

# Retry a failed rollout
kubectl argo rollouts retry rollout auth-service -n paystream

# Watch rollout progress in real time
kubectl argo rollouts get rollout auth-service -n paystream --watch
```

---

## 5. Failure Modes

### 5.1 Service Degradation (High Latency)

**Trigger:** Bank API response time increases beyond normal range (e.g., fault
injection sets LATENCY_MS to 3000ms).

**Detection Chain:**
1. `auth_request_duration_seconds` histogram records elevated latencies.
2. Prometheus evaluates `AuthServiceHighLatency` alert rule:
   P95 > 2.5s for 2 minutes triggers critical alert.
3. During canary: `auth-service-health` AnalysisTemplate detects P95 > 2.5s.

**System Response:**
- Istio VirtualService enforces a 5s request timeout. Requests exceeding
  this are terminated with 504 Gateway Timeout.
- Istio retries up to 3 times with 2s per-try timeout on 5xx responses.
- If during canary rollout: Argo Rollouts aborts the canary after 2 failed
  analysis checks and rolls back traffic to 100% stable.
- DestinationRule outlier detection ejects slow endpoints after 5 consecutive
  5xx errors, removing them from the load balancing pool for 30s.

**Recovery:** When latency returns below threshold, ejected endpoints are
reinstated after baseEjectionTime (30s). Alert auto-resolves.

---

### 5.2 Circuit Breaker Trips

**Trigger:** 5 consecutive failures in the bank API simulation (declined
transactions count as failures to the circuit breaker).

**State Machine:**
```
CLOSED --[5 consecutive failures]--> OPEN --[30s timeout]--> HALF-OPEN
   ^                                                             |
   |                                                             |
   +----[3 successful probes]------<----[any failure]-->  OPEN --+
```

**Detection Chain:**
1. `circuit_breaker_state` gauge changes to 2 (OPEN).
2. `circuit_breaker_trips_total` counter increments.
3. Prometheus evaluates `AuthServiceCircuitBreakerOpen` alert:
   state == 2 for 30s triggers warning alert.
4. During canary: `auth-service-success-rate` AnalysisTemplate checks
   `circuit_breaker_state < 1`, which fails when state is OPEN (2) or
   HALF-OPEN (1).

**System Response:**
- All requests routed to the affected pod receive immediate 503 responses
  with `{"error":"service unavailable","reason":"circuit breaker open"}`.
  No bank API call is attempted, preventing cascade.
- After 30s, circuit breaker transitions to HALF-OPEN and allows 3 probe
  requests through.
- If probes succeed: returns to CLOSED, normal operation resumes.
- If probes fail: returns to OPEN for another 30s cycle.
- During canary: rollout is aborted, traffic returns to stable.

**Impact:** Latency for rejected requests drops to near zero (no bank call),
protecting downstream systems. Clients receive fast failure signals.

---

### 5.3 Canary Fails Analysis

**Trigger:** Any AnalysisTemplate metric crosses its threshold beyond the
configured fail limit.

**Scenarios:**

| Analysis | Failure Condition | Fail Limit | Time to Detect |
|---|---|---|---|
| P95 latency | >= 2.5s | 2 of 5 checks | 60--150s |
| Error rate | >= 1% | 2 of 5 checks | 60--150s |
| Success rate | <= 80% | 1 of 5 checks | 30s |
| Circuit breaker | state >= 1 | 2 of 5 checks | 60--150s |

**System Response:**
1. Argo Rollouts marks the AnalysisRun as **Failed**.
2. The Rollout status transitions to **Degraded**.
3. Argo Rollouts resets VirtualService weights to stable=100, canary=0.
4. Canary ReplicaSet is scaled down.
5. The failed rollout is recorded in the Rollout history (last 2 revisions
   retained per `rollbackWindow.revisions: 2`).

**Recovery:** Fix the issue in the application code, push a new commit. CI
rebuilds and pushes a new image. CD triggers a fresh canary rollout.

---

### 5.4 Prometheus Goes Down

**Trigger:** Prometheus pod crashes, OOM killed, or becomes unready.

**Impact:**
- Grafana dashboards show "No Data" for all panels.
- Argo Rollouts AnalysisTemplates cannot query Prometheus. PromQL queries
  return errors or timeouts.
- AnalysisRuns may fail with provider errors, which count toward the fail
  limit. If enough checks fail, the canary is rolled back automatically.
- Alerting rules stop being evaluated; no new alerts fire.

**Mitigations:**
- Prometheus has readinessProbe (`/-/ready`) and livenessProbe (`/-/healthy`)
  so Kubernetes will restart it if it becomes unhealthy.
- Resource limits (512Mi memory, 500m CPU) with adequate requests (256Mi,
  250m) reduce OOM risk.
- 7-day retention with `--storage.tsdb.retention.time=7d` prevents unbounded
  disk growth.

**Recovery:** Prometheus recovers automatically via liveness probe restart.
Once ready, it resumes scraping and backfills from the last checkpoint.
In-flight AnalysisRuns that failed due to Prometheus downtime may require
manually retrying the rollout.

---

### 5.5 Vault Becomes Unavailable

**Trigger:** Vault pod crashes, is evicted, or the Vault seal state changes.

**Impact:**
- External Secrets Operator cannot refresh secrets from Vault.
- The ExternalSecret resource reports a sync failure in its status.
- **Existing secrets are NOT deleted.** The Kubernetes Secret
  `auth-service-secrets` retains its last synced values because ESO uses
  `creationPolicy: Owner` (the Secret persists as long as the ExternalSecret
  exists).
- Running pods continue to operate normally with the secrets already injected
  via environment variables at startup.
- **New pods** scheduled after Vault goes down will still mount the existing
  Kubernetes Secret and start successfully.

**Risk Window:** If a secret rotation was in progress (refreshInterval: 1m),
the old secret value remains active. If the old credential is revoked at the
source (e.g., the bank rotates the API key), the service will start failing
authentication with the bank.

**Recovery:** Restore Vault. ESO automatically retries secret sync on the
next refresh cycle (1 minute). Once Vault is healthy, the Secret is updated
and new pods will receive the fresh values. Existing pods require a restart
to pick up rotated secrets (since secrets are injected as env vars, not
mounted as volumes with auto-rotation).

---

## 6. Security Architecture

### 6.1 Container Security

| Control | Implementation | File |
|---|---|---|
| Minimal base image | `gcr.io/distroless/static:nonroot` -- no shell, no package manager, no OS utilities | `app/Dockerfile` |
| Non-root execution | `USER nonroot:nonroot` in Dockerfile; distroless/static:nonroot sets UID 65534 | `app/Dockerfile` |
| Static binary | `CGO_ENABLED=0 GOOS=linux` produces a fully static Go binary with no libc dependency | `app/Dockerfile` |
| Stripped binary | `-ldflags="-s -w"` removes debug symbols and DWARF information, reducing attack surface and image size | `app/Dockerfile` |
| Image scanning | Trivy scans for CRITICAL and HIGH vulnerabilities in CI; results uploaded as SARIF | `.github/workflows/ci.yaml` |
| Request size limit | `http.MaxBytesReader(w, r.Body, 1<<20)` limits POST body to 1 MB | `app/handlers/authorize.go` |

### 6.2 Network Security

| Control | Implementation | File |
|---|---|---|
| mTLS (mesh-wide) | Istio Ambient Mesh with ztunnel provides transparent mutual TLS between all pods in labeled namespaces. No sidecars required. | `k8s/namespaces.yaml` (label: `istio.io/dataplane-mode: ambient`) |
| NetworkPolicy (ingress) | auth-service pods only accept traffic from: (1) istio-system namespace on port 8080, (2) paystream namespace pods on port 8080, (3) Prometheus pods on port 8080 | `k8s/base/network-policy.yaml` |
| NetworkPolicy (egress) | auth-service pods can only reach: (1) DNS (UDP/TCP 53), (2) pods within paystream namespace, (3) kube-system for DNS resolution | `k8s/base/network-policy.yaml` |
| Connection pooling | DestinationRule limits to 100 TCP connections and 10 requests per connection, preventing connection exhaustion | `k8s/networking/destination-rule.yaml` |
| Outlier detection | Endpoints returning 5 consecutive 5xx errors are ejected for 30s; max 50% of endpoints can be ejected | `k8s/networking/destination-rule.yaml` |
| Request timeout | VirtualService enforces 5s timeout per request | `k8s/networking/virtualservice.yaml` |
| Retry policy | 3 retry attempts with 2s per-try timeout, only on 5xx/reset/connect-failure | `k8s/networking/virtualservice.yaml` |

### 6.3 RBAC and Least Privilege

| Control | Implementation | File |
|---|---|---|
| Dedicated ServiceAccount | `auth-service` ServiceAccount; pods do not use the default SA | `k8s/base/serviceaccount.yaml` |
| Scoped Role | Role grants only `get` and `list` on `secrets` (restricted to `auth-service-secrets` by resourceNames) and `configmaps` | `k8s/base/rbac.yaml` |
| RoleBinding | Binds the Role exclusively to the `auth-service` ServiceAccount in the `paystream` namespace | `k8s/base/rbac.yaml` |
| CD pipeline RBAC | CD pipeline kubeconfig should use a dedicated service account with access limited to: rollouts, pods, services, endpoints in paystream/paystream-staging namespaces | `.github/workflows/cd.yaml` (documented) |

### 6.4 Secrets Management

| Control | Implementation | File |
|---|---|---|
| External secrets store | HashiCorp Vault (KV v2 engine at path `paystream`) stores all sensitive credentials | `k8s/secrets/vault.yaml` |
| Automated sync | External Secrets Operator syncs Vault secrets to Kubernetes Secrets every 1 minute | `k8s/secrets/external-secret.yaml` |
| Secret separation | Production secrets at `prod/auth-service`, staging at `staging/auth-service` in Vault | `k8s/secrets/external-secret.yaml` |
| Secrets injected as env vars | BANK_API_KEY, DB_PASSWORD, ENCRYPTION_KEY injected via `secretKeyRef` | `k8s/base/rollout.yaml` |
| No secrets in Git | Vault token in dev mode is the only secret in manifests (for local dev only); production would use Kubernetes auth method | `k8s/secrets/secret-store.yaml` |

### 6.5 Supply Chain Security

| Control | Implementation |
|---|---|
| Vulnerability scanning | Trivy scans every pushed image for CRITICAL and HIGH CVEs |
| SARIF upload | Scan results uploaded to GitHub Security tab via CodeQL SARIF integration |
| Image tagging | Images tagged with commit SHA (immutable) and `latest` (mutable convenience tag) |
| Build caching | GitHub Actions cache (`type=gha`) for Docker layers; deterministic builds |
| Dependency pinning | `go.sum` provides cryptographic verification of all Go dependencies |

---

## 7. Observability Architecture

### 7.1 Metrics Pipeline

```
+------------------+     scrape /metrics     +------------------+
| auth-service     | <----- every 15s ------ | Prometheus       |
| pods (port 8080) |                         | (prom/prometheus |
|                  |                         |  v2.51.0)        |
| Exposed metrics: |                         |                  |
| - auth_request_  |     kubernetes_sd_      | Config:          |
|   duration_secs  |     configs:            | - 15s scrape     |
|   (histogram)    |     role: pod           | - 15s evaluation |
| - auth_requests_ |     namespace:          | - 7d retention   |
|   total (counter)|     paystream           |                  |
| - auth_success_  |                         | Relabeling:      |
|   rate (gauge)   |                         | - keep app=auth- |
| - circuit_       |                         |   service        |
|   breaker_state  |                         | - extract version|
|   (gauge)        |                         |   label          |
| - circuit_       |                         | - extract pod    |
|   breaker_trips_ |                         |   name           |
|   total (counter)|                         +--------+---------+
+------------------+                                  |
                                                      |
                                    +-----------------+------------------+
                                    |                                    |
                                    v                                    v
                          +-------------------+              +-------------------+
                          | Grafana           |              | Argo Rollouts     |
                          | (grafana:10.4.0)  |              | AnalysisRuns      |
                          |                   |              |                   |
                          | Datasource:       |              | Queries:          |
                          | Prometheus :9090  |              | - P95 latency     |
                          | (auto-provisioned)|              | - Error rate      |
                          |                   |              | - Success rate    |
                          | Anonymous read    |              | - CB state        |
                          | access enabled    |              |                   |
                          +-------------------+              +-------------------+
```

### 7.2 Prometheus Metrics Reference

| Metric | Type | Labels | Description |
|---|---|---|---|
| `auth_request_duration_seconds` | Histogram | version, status, processor | Duration of authorization requests. Buckets: 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s |
| `auth_requests_total` | Counter | version, status, processor | Total number of authorization requests processed |
| `auth_success_rate` | Gauge | -- | Current authorization success rate (0.0 to 1.0), computed from atomic counters |
| `circuit_breaker_state` | Gauge | -- | Current circuit breaker state: 0 = closed, 1 = half-open, 2 = open |
| `circuit_breaker_trips_total` | Counter | -- | Cumulative number of times the circuit breaker has tripped to OPEN |

### 7.3 Alerting Rules

All alerts are defined in `k8s/monitoring/alerting-rules.yaml` and evaluated
by Prometheus every 15 seconds.

| Alert | Expression | For | Severity | Meaning |
|---|---|---|---|---|
| `AuthServiceHighLatency` | P95 latency > 2.5s (5m window) | 2m | critical | Service is breaching the latency SLO |
| `AuthServiceLowSuccessRate` | Success rate < 90% (5m window) | 1m | critical | Too many transactions are being declined |
| `AuthServiceCircuitBreakerOpen` | `circuit_breaker_state == 2` | 30s | warning | Bank API circuit breaker has tripped |
| `CanaryDegradation` | Canary P95 / Stable P95 > 1.5 (5m window) | 1m | critical | Canary is 50%+ slower than stable version |

### 7.4 Alerting Flow

```
Prometheus evaluates rules every 15s
         |
         v
  Condition met? ----NO----> (no action)
         |
        YES
         |
         v
  "for" duration elapsed? ----NO----> (pending, keep checking)
         |
        YES
         |
         v
  Alert fires (FIRING state)
         |
         v
  [Integration point for Alertmanager]
  In production, configure Alertmanager for routing to:
  - PagerDuty (critical severity)
  - Slack #paystream-alerts (warning severity)
  - Email (all severities)
```

Note: Alertmanager is not deployed in this local development setup. The alert
rules are defined and evaluated by Prometheus. In production, add an
Alertmanager deployment and configure `alerting.alertmanagers` in the
Prometheus config.

### 7.5 Grafana Dashboard Structure

The Grafana instance is provisioned with the Prometheus datasource
automatically. The recommended dashboard layout:

```
+------------------------------------------------------------------+
|                 PayStream Auth Service Dashboard                  |
+------------------------------------------------------------------+
|                                                                  |
|  Row 1: SLO Overview                                             |
|  +-------------------------+  +-------------------------+        |
|  | P95 Latency (gauge)     |  | Success Rate (gauge)    |        |
|  | Target: < 2.5s          |  | Target: > 80%           |        |
|  | Query: histogram_       |  | Query: auth_success_    |        |
|  |   quantile(0.95, ...)   |  |   rate                  |        |
|  +-------------------------+  +-------------------------+        |
|                                                                  |
|  Row 2: Traffic                                                  |
|  +----------------------------------------------------------+   |
|  | Request Rate (time series, by version and status)         |   |
|  | Query: sum(rate(auth_requests_total[5m])) by (version,    |   |
|  |        status)                                            |   |
|  +----------------------------------------------------------+   |
|                                                                  |
|  Row 3: Latency Distribution                                     |
|  +----------------------------------------------------------+   |
|  | Latency Heatmap (by version)                              |   |
|  | Query: sum(rate(auth_request_duration_seconds_bucket[5m]))|   |
|  |        by (le, version)                                   |   |
|  +----------------------------------------------------------+   |
|                                                                  |
|  Row 4: Reliability                                              |
|  +-------------------------+  +-------------------------+        |
|  | Circuit Breaker State   |  | Circuit Breaker Trips   |        |
|  | (stat panel)            |  | (time series)           |        |
|  | Query: circuit_breaker_ |  | Query: circuit_breaker_ |        |
|  |   state                 |  |   trips_total           |        |
|  | Thresholds:             |  |                         |        |
|  |   0=green (closed)      |  |                         |        |
|  |   1=yellow (half-open)  |  |                         |        |
|  |   2=red (open)          |  |                         |        |
|  +-------------------------+  +-------------------------+        |
|                                                                  |
|  Row 5: Canary Rollout                                           |
|  +----------------------------------------------------------+   |
|  | Canary vs Stable P95 (time series, dual Y-axis)           |   |
|  | Query A: histogram_quantile(0.95, ...{version=~"canary"}) |   |
|  | Query B: histogram_quantile(0.95, ...{version!~"canary"}) |   |
|  +----------------------------------------------------------+   |
|  +----------------------------------------------------------+   |
|  | Canary vs Stable Success Rate (time series)               |   |
|  | Query A: rate(approved{version=~"canary"}) / rate(total)  |   |
|  | Query B: rate(approved{version!~"canary"}) / rate(total)  |   |
|  +----------------------------------------------------------+   |
|                                                                  |
+------------------------------------------------------------------+
```

### 7.6 Service Discovery

Prometheus discovers auth-service pods using `kubernetes_sd_configs` with
`role: pod` scoped to the `paystream` namespace. Relabeling rules:

1. **Keep only auth-service pods:** `__meta_kubernetes_pod_label_app` must
   match `auth-service`.
2. **Set scrape target:** Override `__address__` to use port 8080.
3. **Propagate version label:** Extract `__meta_kubernetes_pod_label_version`
   into the `version` time series label, enabling per-version queries for
   canary vs. stable comparison.
4. **Propagate pod name:** Extract `__meta_kubernetes_pod_name` into the `pod`
   label for per-instance debugging.

This configuration means that canary pods automatically appear in Prometheus
as soon as Argo Rollouts creates them, with their `version` label reflecting
the pod template hash. No manual configuration is needed when a canary is
launched.
