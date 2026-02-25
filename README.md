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
│   ├── circuit/                  # Circuit breaker implementation
│   ├── metrics/                  # Prometheus metrics
│   └── Dockerfile                # Multi-stage build
├── k8s/                          # Kubernetes manifests
│   ├── base/                     # Core resources (Rollout, Services, ConfigMap)
│   ├── networking/               # Istio Gateway, VirtualService, DestinationRule
│   ├── rollouts/                 # Argo Rollouts AnalysisTemplates
│   ├── secrets/                  # Vault + External Secrets Operator
│   └── monitoring/               # Prometheus + Grafana
├── .github/workflows/            # CI/CD pipelines
├── tests/                        # Validation and integration tests
└── docs/                         # Additional documentation
```

_Sections below are completed as each component is implemented._

## Application

_See [DESIGN.md](DESIGN.md) for detailed technical decisions._

## Kubernetes Manifests

### Manifest Application Order

1. `k8s/namespaces.yaml` — Namespaces with Istio ambient labels
2. `k8s/secrets/` — Vault + External Secrets Operator
3. `k8s/base/` — Rollout, Services, ConfigMap, RBAC, NetworkPolicy, PDB
4. `k8s/rollouts/` — Argo Rollouts AnalysisTemplates
5. `k8s/networking/` — Istio Gateway, VirtualService, DestinationRule
6. `k8s/monitoring/` — Prometheus, Grafana, alerting rules

## CI/CD Pipeline

_Documented after pipeline implementation._

## Canary Deployment Strategy

_Documented after Argo Rollouts configuration._

## Networking (Istio)

_Documented after Istio configuration._

## Secrets Management

_Documented after Vault + ESO configuration._

## Monitoring & Observability

_Documented after monitoring stack setup._

## Testing

```bash
# Validate Kubernetes manifests
bash tests/validate-manifests.sh

# Run integration tests
bash tests/integration-test.sh

# Test full canary flow
bash tests/canary-test.sh
```

## Design Decisions

_See [DESIGN.md](DESIGN.md) for full rationale._

## Troubleshooting

_See [RUNBOOK.md](RUNBOOK.md) for operational procedures._
