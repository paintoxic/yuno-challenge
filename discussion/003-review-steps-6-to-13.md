# Review #003: Pasos 6-13 — Revision General Completa

**Fecha:** 2026-02-25
**Commits revisados:** `05c369a` a `f826de3` (8 commits)
**Revisor:** Supervisor
**Estado:** REQUIERE CORRECCIONES ANTES DE ENTREGAR

---

## Veredicto General

El proyecto tiene buena cobertura: 14 commits, todos los deliverables presentes (IaC, CI/CD, monitoring, tests, DESIGN.md), README completo. Sin embargo, hay **bugs funcionales criticos** que harian que el canary no funcione en un cluster real. Ademas faltan **RUNBOOK.md** y **docs/architecture.md** que estan referenciados en el README pero no existen.

---

## CRITICO — Rompe funcionalidad

### 1. AnalysisTemplate queries no van a matchear datos (`rollout.yaml` + `analysis-template.yaml`)

El `rollout.yaml` pasa el arg `canary-version` asi:

```yaml
args:
  - name: canary-version
    valueFrom:
      podTemplateHashValue: Latest  # Produce algo como "6d9f8b7c5d"
```

Pero los queries en `analysis-template.yaml` filtran por:

```promql
auth_request_duration_seconds_bucket{version="{{args.canary-version}}"}
```

El label `version` en las metricas viene del Go code (`handlers/authorize.go:121`):
```go
metrics.AuthRequestDuration.WithLabelValues(ServiceVersion, status, processor)
```

Donde `ServiceVersion` se setea desde la env var `SERVICE_VERSION` del ConfigMap, que es `"1.0.0"`.

**Resultado:** El query buscara `version="6d9f8b7c5d"` pero el dato real tiene `version="1.0.0"`. Los queries retornan vacio. El AnalysisRun falla con "no data" o pasa vacuamente.

**Accion:** Hay dos opciones:
- **Opcion A (recomendada):** Quitar el arg `canary-version` de los AnalysisTemplates y filtrar por `rollouts-pod-template-hash` label que Argo Rollouts inyecta automaticamente. O usar el label `version` comparando stable vs canary.
- **Opcion B:** Pasar la version como argumento hardcoded desde el Rollout y que el CD pipeline lo actualice junto con la imagen.

### 2. Alerta `CanaryDegradation` nunca va a dispararse (`alerting-rules.yaml:47-52`)

```yaml
expr: |
  (
    histogram_quantile(0.95, sum(rate(auth_request_duration_seconds_bucket{version=~".*canary.*"}[5m])) by (le))
    /
    histogram_quantile(0.95, sum(rate(auth_request_duration_seconds_bucket{version!~".*canary.*"}[5m])) by (le))
  ) > 1.5
```

Filtra por `version=~".*canary.*"` pero el label `version` nunca contiene la palabra "canary" — es "1.0.0", "1.1.0", etc. Esta alerta es **dead code**.

**Accion:** Reescribir para comparar la version del canary actual contra la stable, o usar `rollouts-pod-template-hash` para distinguir.

### 3. Grafana dashboard JSON nunca se monta (`grafana-deploy.yaml`)

El `grafana-deploy.yaml` monta:
- `grafana-datasource` configmap → `/etc/grafana/provisioning/datasources` (OK)
- `grafana-dashboards` configmap → `/etc/grafana/provisioning/dashboards` (OK — contiene el provider config)

El provider config apunta a `path: /var/lib/grafana/dashboards`, pero **no hay ningun volume que monte `grafana-dashboard.json` a esa ruta**. El archivo JSON existe en el repo pero nunca llega al contenedor.

**Accion:** Crear un ConfigMap con el contenido de `grafana-dashboard.json` y montarlo en `/var/lib/grafana/dashboards/`.

### 4. `validate-manifests.sh`: Variable ERRORS en subshell (nunca incrementa)

```bash
find "$PROJECT_ROOT/k8s/base" -name '*.yaml' | while read -r file; do
  # ...
  ERRORS=$((ERRORS + 1))  # <-- Esto modifica la variable del subshell, no del padre
done
```

En bash, `cmd | while read` crea un **subshell**. Las modificaciones a `ERRORS` dentro del while no persisten al script padre. El check final `if [ "$ERRORS" -gt 0 ]` siempre vera `ERRORS=0` sin importar cuantos fallos haya.

**Accion:** Usar process substitution en vez de pipe:
```bash
while read -r file; do
  # ...
done < <(find "$PROJECT_ROOT/k8s/base" -name '*.yaml')
```

---

## ISSUE — Deberia corregirse

### 5. Trivy scan nunca falla el build (`ci.yaml:122`)

```yaml
exit-code: '0'  # Trivy siempre retorna 0, nunca falla el job
```

Con `exit-code: '0'`, Trivy reporta vulnerabilidades pero **nunca rompe el pipeline**. En la rubrica de Security (15 pts) esto resta puntos porque el escaneo es cosmético.

**Accion:** Cambiar a `exit-code: '1'` para que el pipeline falle si hay vulnerabilidades CRITICAL/HIGH. O mover el scan a un job non-blocking pero documentar por que.

### 6. CD pipeline fallback incorrecto (`cd.yaml:88-93`)

```bash
kubectl argo rollouts set image auth-service \
  auth-service="${IMAGE}" \
  -n "${NAMESPACE}" || \
kubectl set image rollout/auth-service \
  auth-service="${IMAGE}" \
  -n "${NAMESPACE}"
```

El fallback `kubectl set image rollout/auth-service` no funciona — `kubectl set image` solo soporta `deployment/`, `statefulset/`, `daemonset/`, `replicaset/`, `cronjob/`, `job/`. No soporta el CRD `rollout/`.

**Accion:** Eliminar el fallback o reemplazar con `kubectl patch` directamente:
```bash
kubectl patch rollout auth-service -n "${NAMESPACE}" \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"'"${IMAGE}"'"}]'
```

### 7. Vault token hardcoded en Secret manifest (`secret-store.yaml:32-33`)

```yaml
stringData:
  token: "root"
```

Esto guarda el token de Vault en texto plano en un manifiesto que esta en el repo Git. La paradoja es que Vault+ESO existen para evitar exactamente esto.

**Accion:** Documentar en DESIGN.md que esto es solo para dev mode. En produccion se usaria Vault Agent Injector con K8s auth method (sin token estatico). No es bloqueante pero un evaluador atento lo va a notar.

### 8. RUNBOOK.md no existe

El README referencia `RUNBOOK.md` en linea 312 y el plan lo lista como deliverable del paso 13. El archivo **no existe**. Esto es un deliverable requerido por el challenge:

> **Deployment Runbook — RUNBOOK.md with step-by-step instructions for deploying canary, checking health, promoting, and rolling back**

**Accion:** Crear RUNBOOK.md con procedimientos operacionales.

### 9. `docs/architecture.md` no existe

El README (linea 123) lista `docs/architecture.md` en la estructura del proyecto pero el archivo no existe.

**Accion:** Crear el archivo o remover la referencia del README.

### 10. DESIGN.md solo cubre Step 2

DESIGN.md tiene excelente contenido para las decisiones del Go service (Step 2), pero **no documenta ningun otro paso**:
- Falta: Por que Argo Rollouts vs Flagger
- Falta: Por que Istio Ambient vs sidecar vs Linkerd
- Falta: Trade-offs de Vault+ESO vs SealedSecrets vs SOPS
- Falta: Justificacion de umbrales de AnalysisTemplates
- Falta: Failure scenarios y como el sistema los maneja
- Falta: Que se haria diferente en produccion vs este ejercicio

Esto es **15 puntos** de la rubrica (Design Decisions Document). El evaluador busca:
> "Demonstrates deep understanding through nuanced discussion of trade-offs, failure modes, and what compromises were made for the 2-hour scope vs. production needs."

**Accion:** Expandir DESIGN.md con secciones para cada componente.

---

## WARNING — Tomar nota

### 11. Prometheus relabel rule es misleading (`prometheus-config.yaml:27-30`)

```yaml
- source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
  regex: (.+)
  target_label: __address__
  replacement: ${1}:8080
```

Si la anotacion `prometheus.io/port` existiera con valor "9090", el `__address__` se reemplazaria con `"9090:8080"` (el valor de la anotacion seguido de :8080). Esto es un bug potencial. La anotacion no esta seteada en el pod template del Rollout, asi que es un no-op ahora, pero es codigo confuso.

**Accion:** O quitar esta regla, o corregirla para usar `__meta_kubernetes_pod_ip`:
```yaml
- source_labels: [__meta_kubernetes_pod_ip]
  target_label: __address__
  replacement: ${1}:8080
```

### 12. Grafana admin password hardcoded (`grafana-deploy.yaml:70`)

```yaml
- name: GF_SECURITY_ADMIN_PASSWORD
  value: "admin"
```

Para un ejercicio esta bien, pero deberia mencionarse en DESIGN.md como algo que cambiaria en produccion (usando secretRef o Vault).

### 13. Vault en dev mode con root token (`vault.yaml:24`)

```
args: ["server", "-dev", "-dev-root-token-id=root", "-dev-listen-address=0.0.0.0:8200"]
```

Dev mode = in-memory storage, no persistence, token "root". Esto es correcto para el ejercicio pero debe documentarse explicitamente en DESIGN.md que en produccion se usaria:
- HA mode con Raft storage
- Auto-unseal con KMS
- K8s auth method en vez de token estatico

### 14. Muchas ramas de worktree huerfanas

```
worktree-agent-a15a549e, worktree-agent-a23c3e0c, worktree-agent-a2dbc615,
worktree-agent-a708561e, worktree-agent-abf65c34, worktree-agent-abf840e2,
worktree-agent-ad9f44e1, worktree-agent-ae276530, worktree-agent-ae4cd1ed,
worktree-agent-af81bc18
```

10 ramas de worktree de agentes. Deben limpiarse antes de entregar:
```bash
git worktree prune
git branch | grep worktree-agent | xargs git branch -D
```

### 15. `health.go` no retorna `latency_p95_ms` como pide el challenge

El challenge especifica:
> GET /health — returns 200 OK with JSON like `{"status":"healthy","latency_p95_ms":450,"success_rate":0.94}`

Pero `health.go` retorna:
```json
{"status":"healthy","version":"1.0.0","circuit_breaker":"closed","success_rate":0.94,"uptime_seconds":123.4}
```

Falta el campo `latency_p95_ms`. Es un campo especifico que el challenge menciona explicitamente.

**Accion:** Agregar `latency_p95_ms` al health response. Puede calcularse internamente o hardcodearse para el mock.

---

## Lo que esta BIEN HECHO

| Area | Detalle |
|---|---|
| **CI Pipeline** | Lint + test + validate + build + scan. Buena secuencia con `needs` y condicionales. |
| **CD Pipeline** | workflow_dispatch + workflow_run trigger. Multi-environment con namespace mapping. |
| **Alerting Rules** | 4 alertas bien definidas: latency SLO, success rate, circuit breaker, canary degradation (excepto el bug de version). |
| **Grafana Dashboard** | 5 paneles relevantes con thresholds alineados a SLOs. Variable template para filtrar por version. |
| **Integration Tests** | Data realista (Maria Garcia, Carlos Lopez, Ana Martinez). Cubre happy path, error cases y fault injection. |
| **Canary Test** | Verifica rollout, services, VirtualService, AnalysisTemplates y Prometheus. Buena cobertura. |
| **Setup Script** | 580 lineas, bien estructurado con deteccion de OS, verificaciones previas, colores, manejo de errores. |
| **Secrets Architecture** | Vault + ESO + SecretStore per namespace + ExternalSecret con refresh interval. Patron correcto. |
| **README** | Completo, bien estructurado, con tablas, diagramas, y operaciones documentadas. |
| **NetworkPolicy Fix** | El fix del review anterior (OR → AND para Prometheus) fue aplicado correctamente. |
| **Rollout Args Fix** | El fix de `{{templates.X.args.Y}}` → `podTemplateHashValue: Latest` fue aplicado correctamente. |

---

## Resumen de Acciones por Prioridad

### Prioridad 1 — Bloquean la funcionalidad del canary
1. **[C1]** Corregir mismatch version label vs podTemplateHash en AnalysisTemplates
2. **[C3]** Montar grafana-dashboard.json como ConfigMap en Grafana deployment
3. **[C4]** Corregir subshell bug en validate-manifests.sh

### Prioridad 2 — Impactan puntuacion significativamente
4. **[I8]** Crear RUNBOOK.md (deliverable requerido)
5. **[I10]** Expandir DESIGN.md con decisiones de todos los componentes (15 pts)
6. **[I5]** Cambiar Trivy exit-code a '1' o documentar por que es '0'
7. **[C2]** Corregir alerta CanaryDegradation para usar labels reales

### Prioridad 3 — Mejoran calidad
8. **[I6]** Eliminar fallback incorrecto en CD pipeline
9. **[I9]** Crear docs/architecture.md o remover referencia
10. **[W15]** Agregar `latency_p95_ms` al health endpoint
11. **[W14]** Limpiar ramas worktree huerfanas
12. **[I7]** Documentar la paradoja del vault token en DESIGN.md

---

## Puntaje Estimado Actual vs Potencial

| Criterio | Puntos Max | Estimado Actual | Con Fixes |
|---|---|---|---|
| Infrastructure Code Quality | 25 | 18-20 | 22-24 |
| Canary Deployment | 20 | 10-12 (canary no funciona) | 17-19 |
| Health Validation | 15 | 10-11 | 13-14 |
| Security | 15 | 11-12 | 13-14 |
| Observability | 10 | 5-6 (dashboard no carga, RUNBOOK falta) | 8-9 |
| Design Decisions | 15 | 7-8 (solo Step 2) | 12-14 |
| **TOTAL** | **100** | **~61-69** | **~85-94** |

Los fixes de Prioridad 1 y 2 pueden subir el puntaje estimado de ~65 a ~90.
