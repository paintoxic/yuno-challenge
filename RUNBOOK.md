# Operational Runbook -- PayStream Authorization Service

## 1. Service Overview

| Property              | Value                                                         |
|-----------------------|---------------------------------------------------------------|
| **Service**           | `auth-service` (PayStream Authorization Service)              |
| **Image**             | `paintoxic/paystream-auth-service`                            |
| **Namespace (prod)**  | `paystream`                                                   |
| **Namespace (stg)**   | `paystream-staging`                                           |
| **Container port**    | `8080`                                                        |
| **Service port**      | `80` (ClusterIP, maps to 8080)                                |
| **Replicas**          | 3                                                             |
| **Rollout type**      | Argo Rollouts canary (10% -> 50% -> 100%)                     |
| **Service mesh**      | Istio Ambient Mesh (no sidecars)                              |
| **Secrets backend**   | HashiCorp Vault (dev mode) + External Secrets Operator        |

### Endpoints

| Path                  | Method | Description                                   |
|-----------------------|--------|-----------------------------------------------|
| `/v1/authorize`       | POST   | Payment authorization (main business endpoint)|
| `/health`             | GET    | Health check (includes CB state, P95, uptime) |
| `/admin/fault-inject` | POST   | Toggle fault injection for testing             |
| `/metrics`            | GET    | Prometheus metrics (OpenMetrics format)        |

### Services (Kubernetes)

| Service Name            | Purpose                               |
|-------------------------|---------------------------------------|
| `auth-service`          | Primary service (all pods)            |
| `auth-service-stable`   | Stable ReplicaSet only (Argo managed) |
| `auth-service-canary`   | Canary ReplicaSet only (Argo managed) |

### Supporting Infrastructure

| Component          | In-cluster address                                        | Port |
|--------------------|-----------------------------------------------------------|------|
| Prometheus         | `prometheus.paystream.svc.cluster.local`                  | 9090 |
| Grafana            | `grafana.paystream.svc.cluster.local`                     | 3000 |
| Vault              | `vault.paystream.svc.cluster.local`                       | 8200 |
| Istio Gateway      | `paystream-gateway` (host: `paystream.local`)             | 80   |

---

## 2. Common Operations

### 2.1 Deploy a New Canary Version

**Via kubectl (manual):**

```bash
# 1. Set the new image -- Argo Rollouts detects the change and starts the canary
kubectl argo rollouts set image auth-service \
  auth-service=paintoxic/paystream-auth-service:<NEW_TAG> \
  -n paystream

# 2. Verify the rollout has started
kubectl argo rollouts get rollout auth-service -n paystream

# 3. Watch the rollout in real time (blocks until completion or failure)
kubectl argo rollouts get rollout auth-service -n paystream --watch
```

**Via CD pipeline (GitHub Actions):**

Trigger the `CD -- Deploy Canary` workflow manually from the Actions tab, providing:
- `image_tag`: the commit SHA or Docker tag to deploy
- `environment`: `production` or `staging`

The pipeline automatically runs after a successful CI build on `master`.

### 2.2 Monitor Rollout Progress

```bash
# Quick status overview
kubectl argo rollouts get rollout auth-service -n paystream

# Detailed status with live updates
kubectl argo rollouts get rollout auth-service -n paystream --watch

# Check which step the rollout is on
kubectl argo rollouts status auth-service -n paystream

# List all pods with their revision labels
kubectl get pods -n paystream -l app=auth-service \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,VERSION:.metadata.labels.version,HASH:.metadata.labels.rollouts-pod-template-hash

# Check the VirtualService weight distribution
kubectl get virtualservice auth-service-vs -n paystream -o yaml | grep -A5 "route:"

# View active AnalysisRuns
kubectl get analysisrun -n paystream --sort-by=.metadata.creationTimestamp
```

### 2.3 Manual Promote Canary

Use this when the rollout is paused at a step and you want to advance:

```bash
# Promote to the next step
kubectl argo rollouts promote auth-service -n paystream

# Skip all remaining steps and go straight to 100% (full promote)
kubectl argo rollouts promote auth-service -n paystream --full
```

### 2.4 Abort and Rollback

```bash
# Abort the current rollout -- traffic returns to stable, canary pods scale down
kubectl argo rollouts abort auth-service -n paystream

# After aborting, the rollout enters a "Degraded" state.
# Retry (re-deploy) the same version to clear the Degraded status:
kubectl argo rollouts retry rollout auth-service -n paystream

# Alternatively, roll back to a previous revision:
kubectl argo rollouts undo auth-service -n paystream

# Roll back to a specific revision number:
kubectl argo rollouts undo auth-service -n paystream --to-revision=2
```

### 2.5 Inject Faults for Testing

Fault injection lets you simulate degraded backend behavior to test circuit breaker and alerting.

**Enable fault injection (high latency + low success rate):**

```bash
# Port-forward to a canary pod
kubectl port-forward -n paystream svc/auth-service-canary 8080:80 &

# Inject: 3-second latency, 50% success rate
curl -X POST http://localhost:8080/admin/fault-inject \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "latency_ms": 3000, "success_rate": 0.5}'
```

**Enable fault injection (moderate -- useful for testing CB trip):**

```bash
curl -X POST http://localhost:8080/admin/fault-inject \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "latency_ms": 500, "success_rate": 0.3}'
```

**Disable fault injection (restore normal behavior):**

```bash
curl -X POST http://localhost:8080/admin/fault-inject \
  -H "Content-Type: application/json" \
  -d '{"enabled": false, "latency_ms": 0, "success_rate": 1.0}'
```

> **Note:** Fault injection is per-pod (in-memory). Each pod must be targeted individually. Restarting a pod clears its fault state.

### 2.6 Check Health Endpoint

```bash
# Via port-forward (direct to pod)
kubectl port-forward -n paystream svc/auth-service 8080:80 &
curl -s http://localhost:8080/health | jq .

# Expected healthy response:
# {
#   "status": "healthy",
#   "latency_p95_ms": 245,
#   "success_rate": 0.94,
#   "circuit_breaker": "closed",
#   "version": "1.0.0",
#   "uptime_seconds": 3600.5
# }

# Check canary pods specifically
kubectl port-forward -n paystream svc/auth-service-canary 8081:80 &
curl -s http://localhost:8081/health | jq .

# Check stable pods specifically
kubectl port-forward -n paystream svc/auth-service-stable 8082:80 &
curl -s http://localhost:8082/health | jq .
```

**Send a test authorization request:**

```bash
curl -X POST http://localhost:8080/v1/authorize \
  -H "Content-Type: application/json" \
  -d '{
    "card_number": "4539-1488-0343-6467",
    "amount": 149.99,
    "currency": "USD",
    "merchant": "TechStore Online",
    "processor": "visa"
  }' | jq .
```

---

## 3. Troubleshooting

### 3.1 Rollout Stuck at Analysis

**Symptoms:** Rollout sits at an analysis step and neither succeeds nor fails. The `kubectl argo rollouts get rollout` output shows an AnalysisRun in `Running` status for an extended period.

**Diagnosis:**

```bash
# 1. List AnalysisRuns and find the latest one
kubectl get analysisrun -n paystream --sort-by=.metadata.creationTimestamp

# 2. Check the AnalysisRun details (look at metric results)
kubectl describe analysisrun <ANALYSIS_RUN_NAME> -n paystream

# 3. Check whether Prometheus is reachable from the cluster
kubectl exec -it deploy/prometheus -n paystream -- wget -q -O- "http://localhost:9090/-/ready"

# 4. Run the analysis query manually against Prometheus
kubectl port-forward -n paystream svc/prometheus 9090:9090 &
curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.95,sum(rate(auth_request_duration_seconds_bucket[2m]))by(le))" | jq .

# 5. Check that Prometheus is actually scraping auth-service pods
curl -s "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job=="auth-service")'
```

**Resolution:**

- If Prometheus returns no data: verify the `auth-service` pods expose metrics on port 8080 at `/metrics` and that Prometheus scrape config matches the pod labels.
- If the query returns data but the AnalysisRun is stuck: check the `successCondition` in the AnalysisTemplate. The `auth-service-health` template expects P95 latency < 2.5s and error rate < 1%. The `auth-service-success-rate` template expects success rate > 80% and circuit breaker state < 1 (closed).
- If you need to bypass the analysis: promote manually with `kubectl argo rollouts promote auth-service -n paystream`.

### 3.2 Circuit Breaker Stuck OPEN

**Symptoms:** The `/health` endpoint returns `"circuit_breaker": "open"` and `"status": "unhealthy"`. The `/v1/authorize` endpoint returns `503 Service Unavailable` with `"reason": "circuit breaker open"`.

**Diagnosis:**

```bash
# 1. Check health endpoint for CB state
kubectl port-forward -n paystream svc/auth-service 8080:80 &
curl -s http://localhost:8080/health | jq '{status, circuit_breaker, success_rate}'

# 2. Check pod logs for state transitions
kubectl logs -n paystream -l app=auth-service --tail=50 | grep "circuit-breaker"

# 3. Check Prometheus for the circuit breaker metric
kubectl port-forward -n paystream svc/prometheus 9090:9090 &
curl -s "http://localhost:9090/api/v1/query?query=circuit_breaker_state" | jq '.data.result[]'
# Values: 0=closed, 1=half-open, 2=open
```

**Resolution:**

The circuit breaker (sony/gobreaker) configuration:
- **Trips after:** 5 consecutive failures
- **Timeout (open -> half-open):** 30 seconds
- **Half-open max requests:** 3 (if these succeed, CB closes)
- **Counter reset interval:** 60 seconds

Steps to recover:

1. **If fault injection is active, disable it immediately:**
   ```bash
   # For each pod (or use a loop with all pod names):
   kubectl port-forward -n paystream svc/auth-service 8080:80 &
   curl -X POST http://localhost:8080/admin/fault-inject \
     -H "Content-Type: application/json" \
     -d '{"enabled": false, "latency_ms": 0, "success_rate": 1.0}'
   ```
2. **Wait 30 seconds** for the CB to transition from `open` to `half-open`.
3. **Send a few test requests** to let the half-open state probe succeed:
   ```bash
   for i in $(seq 1 5); do
     curl -s -X POST http://localhost:8080/v1/authorize \
       -H "Content-Type: application/json" \
       -d '{"card_number":"4539-1488-0343-6467","amount":10.00,"currency":"USD","merchant":"Test","processor":"visa"}' | jq .status
     sleep 1
   done
   ```
4. **Verify the CB has closed:**
   ```bash
   curl -s http://localhost:8080/health | jq .circuit_breaker
   # Should return "closed"
   ```

### 3.3 Pods Not Starting

**Symptom: `CreateContainerConfigError` -- missing secrets**

```bash
# 1. Check pod events
kubectl describe pod -n paystream -l app=auth-service | grep -A10 "Events:"

# 2. Check if the Kubernetes Secret exists
kubectl get secret auth-service-secrets -n paystream
# If missing: the ExternalSecret has not synced yet

# 3. Check ExternalSecret sync status
kubectl get externalsecret auth-service-secrets -n paystream
kubectl describe externalsecret auth-service-secrets -n paystream

# 4. Check if Vault is running and the init job completed
kubectl get pods -n paystream -l app=vault
kubectl get job vault-init -n paystream
kubectl logs job/vault-init -n paystream

# 5. If Vault init job never ran or failed, re-run it
kubectl delete job vault-init -n paystream 2>/dev/null
kubectl apply -f k8s/secrets/vault-init-job.yaml
```

**Symptom: `ImagePullBackOff` or `ErrImagePull`**

```bash
# 1. Check pod events for the exact error
kubectl describe pod -n paystream -l app=auth-service | grep -A5 "Warning"

# 2. Verify the image exists on DockerHub
docker manifest inspect paintoxic/paystream-auth-service:<TAG>

# 3. If using a private registry, ensure the pull secret is configured
kubectl get secret -n paystream | grep docker
```

**Symptom: `CrashLoopBackOff`**

```bash
# 1. Check pod logs for the crash reason
kubectl logs -n paystream -l app=auth-service --previous --tail=30

# 2. Common causes:
#    - Missing or invalid environment variables (check ConfigMap)
kubectl get configmap auth-service-config -n paystream -o yaml
#    - Port conflict (another process on 8080)
#    - Missing secrets (BANK_API_KEY, DB_PASSWORD, ENCRYPTION_KEY)
```

### 3.4 VirtualService Not Routing Traffic

**Symptoms:** Requests to the gateway host `paystream.local` return 404 or connection refused. In-mesh service-to-service calls to `auth-service` fail.

**Diagnosis:**

```bash
# 1. Verify Istio is installed and ambient mode is active
istioctl version
kubectl get namespace paystream --show-labels | grep "istio.io/dataplane-mode"
# Should show: istio.io/dataplane-mode=ambient

# 2. Check that all Istio networking resources exist
kubectl get gateway,virtualservice,destinationrule -n paystream

# 3. Validate the Istio configuration for errors
istioctl analyze -n paystream

# 4. Check if the Istio ingress gateway pod is running
kubectl get pods -n istio-system -l istio=ingressgateway

# 5. Verify the VirtualService is attached to the gateway
kubectl get virtualservice auth-service-vs -n paystream -o yaml

# 6. Check that endpoints are populated for the services
kubectl get endpoints auth-service-stable -n paystream
kubectl get endpoints auth-service-canary -n paystream
```

**Resolution:**

- If the namespace label `istio.io/dataplane-mode: ambient` is missing:
  ```bash
  kubectl label namespace paystream istio.io/dataplane-mode=ambient --overwrite
  ```
- If the gateway is missing or misconfigured, re-apply:
  ```bash
  kubectl apply -f k8s/networking/gateway.yaml
  kubectl apply -f k8s/networking/virtualservice.yaml
  kubectl apply -f k8s/networking/destination-rule.yaml
  ```
- If `istioctl analyze` reports conflicts, follow the suggested fixes in its output.

### 3.5 High Latency

**Symptoms:** The `/health` endpoint reports `latency_p95_ms` above 2500. The `AuthServiceHighLatency` alert fires in Prometheus.

**Diagnosis:**

```bash
# 1. Check if fault injection is active
kubectl port-forward -n paystream svc/auth-service 8080:80 &
curl -s http://localhost:8080/health | jq '{latency_p95_ms, status, circuit_breaker}'

# 2. Query Prometheus for P95 latency by version
kubectl port-forward -n paystream svc/prometheus 9090:9090 &
curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.95,sum(rate(auth_request_duration_seconds_bucket[5m]))by(le,version))" | jq '.data.result[] | {version: .metric.version, p95: .value[1]}'

# 3. Check resource pressure on the node
kubectl top pods -n paystream -l app=auth-service
kubectl top nodes

# 4. Check for Istio outlier detection ejections
istioctl proxy-config cluster -n paystream deploy/auth-service 2>/dev/null || echo "N/A in ambient mode"
```

**Resolution:**

- If fault injection is active, disable it (see section 2.5).
- If pods are CPU-throttled (`kubectl top pods` shows limits reached), consider increasing resource limits in the Rollout manifest.
- The baseline latency is configured via the `LATENCY_BASE_MS` ConfigMap key (default: `200`ms). Jitter adds +/-50ms. Anything significantly above this indicates fault injection or resource starvation.

### 3.6 External Secrets Not Syncing

**Symptoms:** The `auth-service-secrets` Kubernetes Secret does not exist or is outdated. Pods fail to start with `CreateContainerConfigError`.

**Diagnosis:**

```bash
# 1. Check ExternalSecret status
kubectl get externalsecret -n paystream
# STATUS column should show "SecretSynced"

# 2. Get detailed sync status and errors
kubectl describe externalsecret auth-service-secrets -n paystream

# 3. Check SecretStore connectivity to Vault
kubectl describe secretstore vault-backend -n paystream
# Look for "Valid" in the status conditions

# 4. Check that Vault is running and responsive
kubectl get pods -n paystream -l app=vault
kubectl exec -n paystream deploy/vault -- vault status

# 5. Verify the secrets exist in Vault
kubectl exec -n paystream deploy/vault -- vault kv get paystream/prod/auth-service

# 6. Check ESO controller pods (installed cluster-wide)
kubectl get pods -n external-secrets
kubectl logs -n external-secrets deploy/external-secrets --tail=30

# 7. If ESO is not installed, install it
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

**Resolution:**

- If Vault has no secrets: re-run the init job:
  ```bash
  kubectl delete job vault-init -n paystream 2>/dev/null
  kubectl apply -f k8s/secrets/vault-init-job.yaml
  ```
- If the SecretStore shows `Invalid`: check that the `vault-token` Secret exists with `token: root` and that Vault is reachable at `http://vault:8200`.
- If ESO is not installed: the `setup.sh` script installs it. Run `./setup.sh` or install manually via Helm.

---

## 4. Alerting Response

### 4.1 AuthServiceHighLatency

| Field     | Value                                                    |
|-----------|----------------------------------------------------------|
| **Expr**  | `P95 latency > 2.5s for 2 minutes`                      |
| **Severity** | `critical`                                            |

**Response procedure:**

1. Open the Grafana dashboard: `kubectl port-forward -n paystream svc/grafana 3000:3000` then browse to `http://localhost:3000`.
2. Check if fault injection is active on any pod:
   ```bash
   for pod in $(kubectl get pods -n paystream -l app=auth-service -o name); do
     echo "--- $pod ---"
     kubectl port-forward -n paystream $pod 9999:8080 &
     sleep 1
     curl -s http://localhost:9999/health | jq '{status, latency_p95_ms, circuit_breaker}'
     kill %1 2>/dev/null
   done
   ```
3. If fault injection is active, disable it (section 2.5).
4. If no fault injection, check pod resource usage: `kubectl top pods -n paystream -l app=auth-service`.
5. If a canary rollout is in progress and the canary is the source of high latency, abort: `kubectl argo rollouts abort auth-service -n paystream`.

### 4.2 AuthServiceLowSuccessRate

| Field     | Value                                                    |
|-----------|----------------------------------------------------------|
| **Expr**  | `Success rate < 90% for 1 minute`                        |
| **Severity** | `critical`                                            |

**Response procedure:**

1. Check the success rate per version to isolate canary vs. stable:
   ```bash
   kubectl port-forward -n paystream svc/prometheus 9090:9090 &
   curl -s "http://localhost:9090/api/v1/query?query=(sum(rate(auth_requests_total{status=%22approved%22}[5m]))by(version))/(sum(rate(auth_requests_total[5m]))by(version))" | jq '.data.result[] | {version: .metric.version, success_rate: .value[1]}'
   ```
2. If only the canary version is affected, abort the rollout:
   ```bash
   kubectl argo rollouts abort auth-service -n paystream
   ```
3. If the stable version is also affected:
   - Check circuit breaker state (section 3.2).
   - Check if fault injection is active (section 2.5).
   - Check pod logs for errors: `kubectl logs -n paystream -l app=auth-service --tail=50`.

### 4.3 AuthServiceCircuitBreakerOpen

| Field     | Value                                                    |
|-----------|----------------------------------------------------------|
| **Expr**  | `circuit_breaker_state == 2 for 30 seconds`              |
| **Severity** | `warning`                                             |

**Response procedure:**

1. This alert means the simulated "bank API" backend has received 5+ consecutive failures, tripping the circuit breaker.
2. Disable fault injection if active (section 2.5).
3. Wait 30 seconds for the CB to transition to half-open.
4. The CB will automatically close if the next 3 requests succeed.
5. Monitor recovery:
   ```bash
   watch -n2 'kubectl exec -n paystream deploy/auth-service -- wget -q -O- http://localhost:8080/health 2>/dev/null | python3 -m json.tool'
   ```
6. If the CB does not recover, restart the affected pods:
   ```bash
   kubectl rollout restart rollout/auth-service -n paystream
   ```

### 4.4 CanaryDegradation

| Field     | Value                                                    |
|-----------|----------------------------------------------------------|
| **Expr**  | `Canary P95 latency > 1.5x stable P95 for 1 minute`     |
| **Severity** | `critical`                                            |

**Response procedure:**

1. This alert indicates the new canary version is performing significantly worse than the stable version.
2. **Abort the rollout immediately:**
   ```bash
   kubectl argo rollouts abort auth-service -n paystream
   ```
3. Investigate the canary version:
   ```bash
   # Check which image the canary was running
   kubectl argo rollouts get rollout auth-service -n paystream

   # Review canary pod logs
   kubectl logs -n paystream -l app=auth-service,rollouts-pod-template-hash=<CANARY_HASH> --tail=100
   ```
4. File a bug against the canary image tag. Do not re-promote until the regression is identified and fixed.

---

## 5. Useful Commands -- Quick Reference

### Argo Rollouts

| Action                              | Command                                                                      |
|-------------------------------------|------------------------------------------------------------------------------|
| Get rollout status                  | `kubectl argo rollouts get rollout auth-service -n paystream`                |
| Watch rollout live                  | `kubectl argo rollouts get rollout auth-service -n paystream --watch`         |
| Promote to next step                | `kubectl argo rollouts promote auth-service -n paystream`                    |
| Full promote (skip all steps)       | `kubectl argo rollouts promote auth-service -n paystream --full`             |
| Abort rollout                       | `kubectl argo rollouts abort auth-service -n paystream`                      |
| Retry after abort                   | `kubectl argo rollouts retry rollout auth-service -n paystream`              |
| Undo (rollback)                     | `kubectl argo rollouts undo auth-service -n paystream`                       |
| Set new image                       | `kubectl argo rollouts set image auth-service auth-service=<IMAGE> -n paystream` |
| List AnalysisRuns                   | `kubectl get analysisrun -n paystream --sort-by=.metadata.creationTimestamp` |
| Describe latest AnalysisRun         | `kubectl describe analysisrun -n paystream -l rollouts-pod-template-hash=<HASH>` |
| Rollout history                     | `kubectl argo rollouts get rollout auth-service -n paystream --no-color`     |

### kubectl

| Action                              | Command                                                                      |
|-------------------------------------|------------------------------------------------------------------------------|
| List auth-service pods              | `kubectl get pods -n paystream -l app=auth-service -o wide`                  |
| Pod resource usage                  | `kubectl top pods -n paystream -l app=auth-service`                          |
| Pod logs (follow)                   | `kubectl logs -n paystream -l app=auth-service -f --tail=50`                 |
| Previous crash logs                 | `kubectl logs -n paystream -l app=auth-service --previous --tail=30`         |
| Describe a failing pod              | `kubectl describe pod <POD_NAME> -n paystream`                               |
| Check endpoints                     | `kubectl get endpoints -n paystream auth-service auth-service-stable auth-service-canary` |
| Check ConfigMap                     | `kubectl get configmap auth-service-config -n paystream -o yaml`             |
| Check secrets (existence only)      | `kubectl get secret auth-service-secrets -n paystream`                        |
| Check ExternalSecret sync           | `kubectl get externalsecret -n paystream`                                    |
| Vault status                        | `kubectl exec -n paystream deploy/vault -- vault status`                     |
| Re-seed Vault secrets               | `kubectl delete job vault-init -n paystream; kubectl apply -f k8s/secrets/vault-init-job.yaml` |
| Port-forward service                | `kubectl port-forward -n paystream svc/auth-service 8080:80`                 |
| Port-forward Prometheus             | `kubectl port-forward -n paystream svc/prometheus 9090:9090`                 |
| Port-forward Grafana                | `kubectl port-forward -n paystream svc/grafana 3000:3000`                    |
| Port-forward Vault UI               | `kubectl port-forward -n paystream svc/vault 8200:8200`                      |

### Istio

| Action                              | Command                                                                      |
|-------------------------------------|------------------------------------------------------------------------------|
| Validate Istio config               | `istioctl analyze -n paystream`                                              |
| Check proxy status                  | `istioctl proxy-status`                                                      |
| Check namespace mesh enrollment     | `kubectl get namespace paystream --show-labels`                              |
| List Istio networking resources     | `kubectl get gateway,virtualservice,destinationrule -n paystream`            |
| Inspect VirtualService weights      | `kubectl get vs auth-service-vs -n paystream -o jsonpath='{.spec.http[0].route[*].weight}'` |
| Istio version                       | `istioctl version`                                                           |

### Prometheus Queries (via port-forward on 9090)

| Metric                              | PromQL                                                                       |
|-------------------------------------|------------------------------------------------------------------------------|
| P95 latency by version              | `histogram_quantile(0.95, sum(rate(auth_request_duration_seconds_bucket[5m])) by (le, version))` |
| Success rate by version             | `sum(rate(auth_requests_total{status="approved"}[5m])) by (version) / sum(rate(auth_requests_total[5m])) by (version)` |
| Request rate (total)                | `sum(rate(auth_requests_total[5m]))` |
| Circuit breaker state               | `circuit_breaker_state`  (0=closed, 1=half-open, 2=open)                     |
| Circuit breaker trip count          | `circuit_breaker_trips_total`                                                |
| Active alerts                       | `ALERTS{alertstate="firing"}`                                                |
