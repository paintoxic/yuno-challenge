# Plan: PayStream Authorization Service — Canary Infrastructure

## Context

PayStream procesa 2.4M transacciones diarias. Un deploy reciente causó timeouts en 3% de transacciones Visa, afectando 12,000 clientes antes de detectarse (40 min). Se necesita infraestructura canary con validación automática de salud antes de Black Friday.

Este plan implementa: canary deployments con Argo Rollouts, traffic splitting con Istio Ambient Mesh, circuit breaker a nivel aplicación, observabilidad con Prometheus/Grafana, secrets management con Vault + External Secrets Operator, y CI/CD con GitHub Actions.

**Repo:** `paintoxic/yuno-challenge` | **Registry:** `paintoxic/paystream-auth-service`

---

## Estructura de Archivos Final

```
/
├── CLAUDE.md
├── README.md
├── DESIGN.md
├── RUNBOOK.md
├── setup.sh
├── app/
│   ├── main.go
│   ├── go.mod / go.sum
│   ├── handlers/
│   │   ├── authorize.go      # POST /v1/authorize
│   │   ├── health.go         # GET /health
│   │   └── fault_inject.go   # POST /admin/fault-inject
│   ├── circuit/
│   │   └── breaker.go        # Circuit breaker con sony/gobreaker
│   ├── metrics/
│   │   └── prometheus.go     # Métricas Prometheus
│   ├── Dockerfile
│   └── .dockerignore
├── k8s/
│   ├── namespaces.yaml
│   ├── base/
│   │   ├── rollout.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   ├── serviceaccount.yaml
│   │   └── rbac.yaml
│   ├── networking/
│   │   ├── gateway.yaml
│   │   ├── virtualservice.yaml
│   │   └── destination-rule.yaml
│   ├── rollouts/
│   │   ├── analysis-template.yaml
│   │   └── analysis-success.yaml
│   ├── secrets/
│   │   ├── vault.yaml
│   │   ├── secret-store.yaml
│   │   ├── external-secret.yaml
│   │   └── vault-init-job.yaml
│   └── monitoring/
│       ├── prometheus-config.yaml
│       ├── prometheus-deploy.yaml
│       ├── grafana-deploy.yaml
│       ├── grafana-dashboard.json
│       └── alerting-rules.yaml
├── .github/
│   └── workflows/
│       ├── ci.yaml
│       └── cd.yaml
├── tests/
│   ├── validate-manifests.sh
│   ├── integration-test.sh
│   └── canary-test.sh
└── docs/
    └── architecture.md
```

---

## Plan de Ejecución (14 Pasos / 14+ Commits)

### Paso 0: Plan como primer commit
- Commit: `docs(plan): add implementation plan as first rock planning`
- Guardar este plan en `docs/plans/`

### Paso 1: Estructura del proyecto
- Commit: `chore(project): initialize project structure and documentation base`
- README.md skeleton, .gitignore, directorios

### Paso 2: Authorization Service en Go
- Commit: `feat(app): add authorization service mock with prometheus metrics and circuit breaker`
- main.go, handlers, circuit breaker, metrics, Dockerfile

### Paso 3: Setup script
- Commit: `script(setup): add automated cluster setup with dependency checks`
- setup.sh completo

### Paso 4: Namespaces y RBAC
- Commit: `infra(k8s): add namespaces, service accounts and RBAC configuration`

### Paso 5: Base manifests
- Commit: `infra(k8s): add base rollout, services and configmap for auth service`

### Paso 6: Istio networking
- Commit: `infra(istio): configure ambient mesh with gateway and virtual services`

### Paso 7: Argo Rollouts canary
- Commit: `feat(rollouts): add canary strategy with progressive rollout and analysis templates`

### Paso 8: Vault + ESO
- Commit: `infra(secrets): add vault and external secrets operator configuration`

### Paso 9: CI pipeline
- Commit: `ci(gh-actions): configure build, test and push pipeline to dockerhub`

### Paso 10: CD pipeline
- Commit: `ci(gh-actions): configure canary deployment pipeline to cluster`

### Paso 11: Monitoring
- Commit: `infra(monitoring): add prometheus rules, grafana dashboard and alerting configuration`

### Paso 12: Tests
- Commit: `test(infra): add manifest validation and integration tests`

### Paso 13: Documentation
- Commit: `docs(project): add design decisions, runbook and complete documentation`

---

## Métricas de Éxito vs Rúbrica

| Criterio (pts) | Lo que entregamos |
|---|---|
| Infrastructure Code Quality (25) | IaC limpio, parametrizado, separado por concerns, sin hardcoding |
| Canary Deployment (20) | Argo Rollouts + Istio traffic split + auto-promotion + auto-rollback |
| Health Validation (15) | Health checks ligados a SLOs, circuit breaker, AnalysisTemplate, auto traffic shift |
| Security (15) | Vault + ESO + rotación + RBAC + distroless images + no root |
| Observability (10) | Prometheus rules + Grafana dashboard + alertas SLO-based + RUNBOOK claro |
| Design Decisions (15) | DESIGN.md con trade-offs reales, failure modes, prod vs exercise |
