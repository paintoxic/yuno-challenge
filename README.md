# PayStream Authorization Service — Canary Infrastructure

> Progressive canary deployment infrastructure for PayStream's authorization service, built with Argo Rollouts, Istio Ambient Mesh, and automated health validation.

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Application](#application)
- [Kubernetes Manifests](#kubernetes-manifests)
- [CI/CD Pipeline](#cicd-pipeline)
- [Canary Deployment Strategy](#canary-deployment-strategy)
- [Networking (Istio)](#networking-istio)
- [Secrets Management](#secrets-management)
- [Monitoring & Observability](#monitoring--observability)
- [Testing](#testing)
- [Design Decisions](#design-decisions)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
                    ┌─────────────────────────────────────────────────┐
                    │                  Minikube Cluster                │
                    │                                                  │
   Internet ──────►│  Istio Gateway ──► VirtualService                │
                    │                       │                          │
                    │              ┌────────┴────────┐                │
                    │              │                  │                │
                    │         weight: 90%        weight: 10%          │
                    │              │                  │                │
                    │     ┌───────▼──────┐  ┌───────▼──────┐        │
                    │     │   Stable      │  │   Canary      │        │
                    │     │  auth-svc     │  │  auth-svc     │        │
                    │     │  v1.0.0       │  │  v1.1.0       │        │
                    │     └──────┬───────┘  └──────┬───────┘        │
                    │            │                  │                 │
                    │     ┌──────▼──────────────────▼──────┐        │
                    │     │         Prometheus              │        │
                    │     │    (metrics collection)         │        │
                    │     └──────────────┬─────────────────┘        │
                    │                    │                            │
                    │     ┌──────────────▼─────────────────┐        │
                    │     │    Argo Rollouts Controller      │        │
                    │     │  (AnalysisTemplate evaluation)   │        │
                    │     │  Auto-promote / Auto-rollback    │        │
                    │     └─────────────────────────────────┘        │
                    │                                                  │
                    │     ┌─────────────────────────────────┐        │
                    │     │  Vault + External Secrets Operator│        │
                    │     │  (secrets rotation & sync)        │        │
                    │     └─────────────────────────────────┘        │
                    └─────────────────────────────────────────────────┘
```

## Prerequisites

- macOS or Linux
- Docker Desktop installed and running
- 4+ CPU cores and 8+ GB RAM available for Minikube
- GitHub account with access to the repository

## Quick Start

```bash
# Clone the repository
git clone git@github.com:paintoxic/yuno-challenge.git
cd yuno-challenge

# Run the setup script (installs all dependencies and configures cluster)
bash setup.sh

# Apply manifests in order
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/secrets/
kubectl apply -f k8s/base/
kubectl apply -f k8s/rollouts/
kubectl apply -f k8s/networking/
kubectl apply -f k8s/monitoring/

# Verify the deployment
kubectl get rollouts -n paystream
kubectl argo rollouts get rollout auth-service -n paystream
```

## Project Structure

```
/
├── CLAUDE.md                     # Project guidelines
├── README.md                     # This file
├── DESIGN.md                     # Technical design decisions
├── RUNBOOK.md                    # Operational runbook
├── setup.sh                      # Automated cluster setup
├── app/                          # Go authorization service
│   ├── main.go                   # HTTP server entrypoint
│   ├── handlers/                 # Request handlers
│   │   ├── authorize.go          # POST /v1/authorize
│   │   ├── health.go             # GET /health
│   │   └── fault_inject.go       # POST /admin/fault-inject
│   ├── circuit/                  # Circuit breaker (sony/gobreaker)
│   ├── metrics/                  # Prometheus metrics
│   └── Dockerfile                # Multi-stage distroless build
├── k8s/                          # Kubernetes manifests
│   ├── namespaces.yaml           # paystream + paystream-staging
│   ├── base/                     # Rollout, Services, ConfigMap, RBAC, NetworkPolicy, PDB
│   ├── rollouts/                 # AnalysisTemplates (P95 latency, success rate)
│   ├── networking/               # Istio Gateway, VirtualService, DestinationRule
│   ├── secrets/                  # Vault + External Secrets Operator
│   └── monitoring/               # Prometheus, Grafana, alerting rules
├── .github/workflows/            # CI/CD pipelines
│   ├── ci.yaml                   # Build, lint, test, scan, push
│   └── cd.yaml                   # Canary deployment
├── tests/                        # Validation and integration tests
│   ├── validate-manifests.sh     # kubeconform validation
│   ├── integration-test.sh       # Endpoint tests with realistic data
│   └── canary-test.sh            # Canary infrastructure validation
└── docs/                         # Additional documentation
    ├── architecture.md           # Detailed architecture
    └── plans/                    # Implementation plans
```

## Application

The authorization service is a Go HTTP server that simulates payment transaction authorization. It exposes:

| Endpoint | Method | Purpose |
|---|---|---|
| `/v1/authorize` | POST | Process authorization requests through circuit breaker |
| `/health` | GET | Health status with circuit breaker state awareness |
| `/admin/fault-inject` | POST | Dynamic fault injection for canary demos |
| `/metrics` | GET | Prometheus metrics endpoint |

**Key features:**
- Circuit breaker (sony/gobreaker): 5 failures trips, 30s recovery timeout
- Configurable latency and success rate via environment variables
- Prometheus metrics: request duration histogram, request counter, success rate gauge, circuit breaker state
- Multi-stage Dockerfile with distroless base, running as nonroot (UID 65532)

See [DESIGN.md](DESIGN.md) for detailed technical decisions.

## Kubernetes Manifests

### Manifest Application Order

1. `k8s/namespaces.yaml` — Namespaces with Istio ambient labels
2. `k8s/secrets/` — Vault deployment, init job, SecretStore, ExternalSecrets
3. `k8s/base/` — Rollout, Services, ConfigMap, ServiceAccount, RBAC, NetworkPolicy, PDB
4. `k8s/rollouts/` — AnalysisTemplates for canary health validation
5. `k8s/networking/` — Istio Gateway, VirtualService, DestinationRule
6. `k8s/monitoring/` — Prometheus, Grafana, alerting rules, dashboard

### Key Resources

| Resource | File | Purpose |
|---|---|---|
| Rollout | `base/rollout.yaml` | Argo Rollout with canary strategy |
| NetworkPolicy | `base/network-policy.yaml` | Pod-to-pod traffic restriction |
| PDB | `base/pdb.yaml` | 2/3 replicas during disruptions |
| AnalysisTemplate | `rollouts/analysis-template.yaml` | P95 latency + error rate checks |
| VirtualService | `networking/virtualservice.yaml` | Traffic split stable/canary |

## CI/CD Pipeline

### CI (`ci.yaml`)

Triggers on push to `master` and PRs affecting `app/`:

1. **Lint** — golangci-lint on Go source
2. **Test** — `go test` with race detector and coverage
3. **Validate Manifests** — kubeconform with CRD schema support
4. **Build & Push** — Docker multi-stage build, tags with commit SHA + `latest`
5. **Scan Image** — Trivy vulnerability scanner (CRITICAL/HIGH) with SARIF upload

**Required secrets:** `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`

### CD (`cd.yaml`)

Triggers manually (workflow_dispatch) or after successful CI:

1. Updates image tag in Argo Rollout
2. Monitors rollout progress (600s timeout)
3. Verifies pod health and service endpoints
4. Supports multi-environment: production (`paystream`) and staging (`paystream-staging`)

**Required secrets:** `KUBECONFIG` (base64-encoded)

## Canary Deployment Strategy

Progressive canary with SLO-based automated gates:

```
Deploy canary ──► 10% traffic ──► Analysis Gate 1 ──► 50% traffic ──► Analysis Gate 2 ──► 100% traffic
                                       │                                    │
                                  P95 < 2.5s?                         Success > 80%?
                                  Error < 1%?                         CB healthy?
                                       │                                    │
                                  FAIL → Rollback                     FAIL → Rollback
```

### Analysis Gates

| Gate | Metric | Threshold | Interval | Tolerance |
|---|---|---|---|---|
| P95 Latency | `auth_request_duration_seconds` | < 2.5s | 30s, 5 checks | 2 failures allowed |
| Error Rate | `auth_requests_total` | < 1% | 30s, 5 checks | 2 failures allowed |
| Success Rate | `auth_requests_total{status=approved}` | > 80% | 30s, 5 checks | 1 failure allowed |
| Circuit Breaker | `circuit_breaker_state` | < 1 (closed) | 30s, 5 checks | 2 failures allowed |

### Operations

```bash
# Trigger canary deployment
kubectl argo rollouts set image auth-service \
  auth-service=paintoxic/paystream-auth-service:<new-tag> -n paystream

# Monitor progress
kubectl argo rollouts get rollout auth-service -n paystream --watch

# Manual promote (skip analysis)
kubectl argo rollouts promote auth-service -n paystream

# Abort and rollback
kubectl argo rollouts abort auth-service -n paystream
```

## Networking (Istio)

Istio Ambient Mesh provides the networking layer without sidecar injection:

- **Gateway:** HTTP ingress on port 80 (HTTPS config included but commented for dev)
- **VirtualService:** Weighted routing between stable (100%) and canary (0%), dynamically adjusted by Argo Rollouts during deployments
- **DestinationRule:** Connection pooling (100 TCP, 10 req/conn) and outlier detection (5 consecutive 5xx errors triggers ejection)
- **Retries:** 3 attempts, 2s per-try timeout, on 5xx/reset/connect-failure

In production, Istio Ambient provides mTLS between pods via ztunnel without sidecar overhead.

## Secrets Management

### Vault + External Secrets Operator

Secrets are managed through HashiCorp Vault (dev mode) with ESO synchronization:

1. **Vault** runs in-cluster, seeded with mock secrets for prod and staging
2. **SecretStore** per namespace connects ESO to Vault's KV v2 engine
3. **ExternalSecret** syncs `BANK_API_KEY`, `DB_PASSWORD`, `ENCRYPTION_KEY` to K8s Secrets
4. **Refresh interval:** 1 minute (automatic rotation)

**Fallback:** If Vault/ESO is unstable, use K8s native Secrets with SealedSecrets.

## Monitoring & Observability

### Prometheus

- Scrapes auth-service pods every 15s via K8s pod discovery
- 7-day retention
- Alerting rules for SLO violations

### Grafana

- Auto-provisioned Prometheus datasource
- "PayStream Auth Service - Canary Monitor" dashboard with:
  - P95 Latency by version (threshold: 2.5s)
  - Success Rate by version (threshold: 90%)
  - Request Rate by version (stacked)
  - Circuit Breaker state (CLOSED/HALF-OPEN/OPEN)
  - Rollout Progress (total requests per version)

### Alerting Rules

| Alert | Condition | Severity |
|---|---|---|
| AuthServiceHighLatency | P95 > 2.5s for 2 min | critical |
| AuthServiceLowSuccessRate | Success < 90% for 1 min | critical |
| AuthServiceCircuitBreakerOpen | CB state = OPEN for 30s | warning |
| CanaryDegradation | Canary 1.5x slower than stable for 1 min | critical |

## Testing

```bash
# Validate Kubernetes manifests (requires kubeconform)
bash tests/validate-manifests.sh

# Run integration tests against running service
BASE_URL=http://localhost:8080 bash tests/integration-test.sh

# Validate canary infrastructure in cluster
bash tests/canary-test.sh
```

The integration tests use realistic mock data:
- Visa transaction: Maria Garcia, $2,450.00 USD, Amazon Web Services
- Mastercard transaction: Carlos Lopez, EUR189.99, El Corte Ingles
- AMEX transaction: Ana Martinez, $15,000.00 USD, Salesforce Inc

## Design Decisions

See [DESIGN.md](DESIGN.md) for detailed rationale on every technical choice, including:
- Why Go over Node.js/Rust
- Circuit breaker configuration rationale
- Distroless + nonroot security posture
- Argo Rollouts vs Flagger comparison
- Istio Ambient vs sidecar trade-offs
- Production considerations (HPA, tracing, log aggregation)

## Troubleshooting

See [RUNBOOK.md](RUNBOOK.md) for detailed operational procedures. Common issues:

| Symptom | Likely Cause | Action |
|---|---|---|
| Rollout stuck at analysis | Prometheus unreachable | Check `kubectl get svc prometheus -n paystream` |
| Circuit breaker OPEN | Too many failures | Check app logs, reduce fault injection |
| Pods not starting | Missing secrets | Verify Vault init job completed |
| VirtualService not routing | Istio not installed | Run `istioctl verify-install` |
| Image pull errors | DockerHub rate limit | Check secrets, use `imagePullPolicy: IfNotPresent` |
