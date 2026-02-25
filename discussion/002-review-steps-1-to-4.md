# Review #002: Pasos 1 al 4 — App, Setup, K8s Manifests

**Fecha:** 2026-02-25
**Commits revisados:** `2d60f6a`, `6abb8f0`, `291783c`, `e897b20`
**Revisor:** Supervisor
**Estado:** REQUIERE CORRECCIONES

---

## Resumen Ejecutivo

Los pasos 1-4 demuestran trabajo solido: buena estructura Go, Dockerfile seguro, setup.sh funcional, manifiestos K8s bien organizados. Sin embargo, hay **7 issues criticos** que afectan directamente los criterios de evaluacion y deben corregirse antes de avanzar mucho mas.

---

## CRITICO — Afecta puntuacion directamente

### C1. Health endpoint NO retorna `latency_p95_ms` (Archivo: `app/handlers/health.go`)

El challenge dice textualmente que `/health` debe retornar `{"status":"healthy","latency_p95_ms":450,"success_rate":0.94}`. La implementacion actual retorna `uptime_seconds` en lugar de `latency_p95_ms`, y el `success_rate` devuelve el valor **configurado** (estatico), no el **observado** real.

**Impacto:** Viola un requisito explicito del challenge. Puntos en Health Validation (15pts).

**Fix:**
- Agregar sliding window o leer del histograma Prometheus para calcular P95 real
- Computar success rate real desde los contadores `auth_requests_total`
- Mantener `uptime_seconds` y `circuit_breaker` como campos extra

### C2. Health endpoint retorna HTTP 200 incluso cuando unhealthy (Archivo: `app/handlers/health.go`)

El handler siempre retorna 200, incluso cuando el circuit breaker esta abierto y status es `"unhealthy"`. Los readiness/liveness probes en K8s usan httpGet que chequea 2xx. Resultado: **Kubernetes nunca detectara un pod enfermo**.

**Impacto:** Socava completamente el criterio Health Validation (15pts). Los probes son decorativos.

**Fix:**
```go
if status == "unhealthy" {
    w.WriteHeader(http.StatusServiceUnavailable) // 503
}
```

### C3. Race conditions en estado global de fault injection (Archivos: `app/handlers/authorize.go`, `app/handlers/fault_inject.go`)

Las variables globales `FaultInjectionEnabled`, `FaultLatencyMS`, `FaultSuccessRate` se leen/escriben sin sincronizacion. Go ejecuta cada request HTTP en su propia goroutine. Esto es un data race que `go test -race` flaggearia.

**Fix:** Usar `sync.RWMutex` o `sync/atomic`:
```go
type FaultConfig struct {
    mu          sync.RWMutex
    Enabled     bool
    LatencyMS   int
    SuccessRate float64
}
```

### C4. Syntax invalido en analysis template args del Rollout (Archivo: `k8s/base/rollout.yaml`)

Los analysis steps referencian argumentos con self-referential templates que no resuelven:
```yaml
args:
  - name: canary-version
    value: "{{templates.auth-service-health.args.canary-version}}"
```

Esta sintaxis es invalida en Argo Rollouts. Fallara en runtime y las queries Prometheus no matchearan nada.

**Fix:**
```yaml
args:
  - name: canary-version
    valueFrom:
      podTemplateHashValue: Latest
```

### C5. NetworkPolicy usa logica OR en vez de AND (Archivo: `k8s/base/network-policy.yaml`)

La regla de Prometheus tiene `namespaceSelector` y `podSelector` como items separados bajo `from:`. En K8s NetworkPolicy, items separados = OR. Cualquier pod en el namespace `paystream` O cualquier pod `app: prometheus` en cualquier namespace puede acceder.

**Fix:** Combinar en un solo entry `from:`:
```yaml
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: paystream
      podSelector:
        matchLabels:
          app: prometheus
```

### C6. setup.sh: `kubectl wait || true` en paths criticos (Archivo: `setup.sh`)

Los waits de Istio y Argo Rollouts tienen `|| true`:
```bash
kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=300s || true
```

Si los pods nunca arrancan, el script continua feliz y reporta exito. Esto enmascara fallos de instalacion.

**Fix:** Quitar `|| true` y manejar el error descriptivamente:
```bash
if ! kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=300s; then
    error_exit "Istio pods failed to become ready within 300 seconds"
fi
```

### C7. setup.sh: ESO se instala desde `main` branch con errores suprimidos (Archivo: `setup.sh`)

```bash
kubectl apply -f https://raw.githubusercontent.com/.../main/deploy/... 2>/dev/null || true
```

URLs de `main` branch pueden cambiar/romperse. Peor: `2>/dev/null || true` suprime todo error. ESO podria no instalarse y nadie lo sabria.

**Fix:** Usar Helm con version pinneada (metodo oficial de ESO) o quitar `2>/dev/null || true`.

---

## IMPORTANTE — Deberia corregirse

### I1. `defer r.Body.Close()` despues de leer el body (`app/handlers/authorize.go`)

El `defer` esta despues del `Decode`. Si decode falla y retorna early, el body no se cierra. Mover antes del Decode o eliminar (net/http lo maneja automaticamente en server handlers).

### I2. Declined transactions retornan HTTP 200 (`app/handlers/authorize.go`)

Tanto approved como declined retornan 200. Si los AnalysisTemplates usan metricas de Istio basadas en HTTP status codes (`istio_requests_total{response_code="200"}`), no podran distinguir canary sano de canary con declines.

**Recomendacion:** Decidir y documentar en DESIGN.md: o usar HTTP 402/422 para declines, o asegurar que AnalysisTemplate use exclusivamente las metricas custom `auth_requests_total{status="approved"}`.

### I3. `auth_success_rate` gauge nunca se actualiza (`app/metrics/prometheus.go`)

La metrica se declara y registra pero nunca se setea. Siempre reportara 0. Es dead code que puede confundir.

**Fix:** O popular la gauge periodicamente, o eliminarla si el AnalysisTemplate computara el rate via PromQL.

### I4. No hay unit tests en `app/` — ningun `*_test.go`

El CLAUDE.md requiere tests con data realista. La interfaz `BreakerInterface` se disenio explicitamente para testabilidad, pero no hay tests. El criterio Health Validation evalua testabilidad.

### I5. Sin limites de body size en endpoints POST (`app/handlers/authorize.go`, `fault_inject.go`)

Un request malicioso podria enviar GB de data causando OOM.

**Fix:** `r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB`

### I6. setup.sh: Sin version pinning — nada es reproducible

Todas las herramientas se instalan con `latest`. En 6 meses las versiones podrian ser incompatibles. Contradice el principio de Infrastructure as Code.

**Fix:** Variables al inicio del script:
```bash
MINIKUBE_VERSION="v1.34.0"
KUBECTL_VERSION="v1.31.4"
ISTIO_VERSION="1.24.2"
ARGO_ROLLOUTS_VERSION="v1.7.2"
```

### I7. setup.sh: Verificacion de Istio no confirma modo ambient

Chequea si hay pods en `istio-system` pero no verifica que sea ambient mode. Si habia una instalacion previa con sidecars, el script la acepta.

**Fix:** Verificar el DaemonSet `ztunnel` que es unico de ambient mode:
```bash
if kubectl get daemonset ztunnel -n istio-system &>/dev/null; then
    success "Istio Ambient Mesh is already installed"
    return
fi
```

### I8. setup.sh: No verifica Docker daemon corriendo

En macOS, `brew install --cask docker` instala Docker Desktop pero no lo inicia. Minikube con `--driver=docker` fallara.

**Fix:**
```bash
if ! docker info &>/dev/null; then
    error_exit "Docker daemon is not running. Start Docker Desktop first."
fi
```

### I9. setup.sh: No verifica Homebrew en macOS

Todas las instalaciones macOS usan `brew` pero nunca se chequea si esta instalado.

### I10. PDB `minAvailable: 2` puede ser problematico durante rollouts (`k8s/base/pdb.yaml`)

Con 3 replicas y `minAvailable: 2`, durante canary rollout donde hay stable + canary pods, el efecto del PDB es impredecible.

**Mejor:** `maxUnavailable: 1`

### I11. Steps 4 y 5 se fusionaron en un solo commit

El plan decia 2 commits separados. Esto viola "Un commit por tarea completada" del CLAUDE.md y reduce el conteo total de commits. Con el minimo de 10, cada commit cuenta.

### I12. El Rollout ya incluye analysis refs que aun no existen

El plan decia "Step 5 crea Rollout SIN analysis refs, Step 7 los agrega". Pero el rollout actual ya referencia AnalysisTemplates que se crean en Step 7. Si alguien aplica los manifiestos en este punto, Argo Rollouts fallaria.

---

## SUGERENCIAS — Nice to have

| # | Tema | Detalle |
|---|---|---|
| S1 | Graceful shutdown | `app/main.go` usa `http.ListenAndServe` sin soporte de shutdown. En K8s, SIGTERM deberia drenar requests |
| S2 | `/admin/fault-inject` sin auth | Cualquiera puede sabotear el servicio. Agregar shared-secret o env var gate |
| S3 | Transaction IDs con `math/rand` | Usar `crypto/rand` o UUID para look realista |
| S4 | `.gitkeep` en directorios no vacios | `app/circuit/`, `app/handlers/`, `app/metrics/` ya tienen archivos. Limpiar los .gitkeep |
| S5 | `startupProbe` ausente en rollout | Sin el, liveness probe puede matar pods que tardan en iniciar |
| S6 | Staging namespace vacio | `paystream-staging` existe pero no tiene manifiestos |
| S7 | Egress NetworkPolicy muy amplio | Permite todo trafico dentro del namespace |
| S8 | DNS egress duplicado | Dos reglas DNS: una generica y una a kube-system. La generica hace la otra redundante |
| S9 | setup.sh: `--dry-run` mode | Util para que usuarios vean que se instalaria sin instalar |
| S10 | setup.sh: Elapsed time tracking | Script tarda 10-15 min, mostrar tiempo por paso mejora UX |
| S11 | `curl` y `git` ausentes del summary del setup.sh | Se instalan pero no aparecen en el resumen final |

---

## Lo que esta BIEN

- **Dockerfile ejemplar:** Multi-stage, distroless, nonroot, CGO disabled, stripped binary. Top quartile en Security
- **Circuit breaker bien implementado:** `sony/gobreaker` con config razonable para pagos (5 failures, 30s timeout)
- **Metricas Prometheus bien disenadas:** Labels `version`, `status`, `processor` habilitan comparacion canary vs stable
- **RBAC genuinamente least-privilege:** Secrets scoped por nombre especifico, solo verbos get/list
- **Labels consistentes:** `app.kubernetes.io/*` en todos los recursos
- **3 Services para traffic splitting:** Patron correcto para Argo Rollouts + Istio
- **DESIGN.md de alta calidad:** Trade-offs especificos, cuantificados y contextuales a PayStream
- **setup.sh idempotente:** Guards en cada funcion, architecture-aware, colores
- **Feedback del supervisor atendido:** 11 de 13 items del review #001 fueron implementados

---

## Prioridad de Fixes

### Bloque 1 — Hacer AHORA (afecta scoring directamente)
1. **C1** — Health endpoint: agregar `latency_p95_ms` y success rate real
2. **C2** — Health endpoint: retornar 503 cuando unhealthy
3. **C4** — Fix syntax de analysis template args en rollout.yaml

### Bloque 2 — Hacer PRONTO (afecta calidad del codigo)
4. **C3** — Fix race conditions en fault injection
5. **C5** — Fix logica OR/AND en NetworkPolicy
6. **I3** — Popular o eliminar gauge `auth_success_rate`
7. **I2** — Documentar estrategia de HTTP status codes para declined

### Bloque 3 — Hacer cuando se pueda (mejora robustez)
8. **C6/C7** — Fix `|| true` y ESO install en setup.sh
9. **I6** — Version pinning en setup.sh
10. **I4** — Agregar unit tests
11. **I7/I8/I9** — Pre-checks en setup.sh

### Nota sobre commits
El conteo actual es 7 commits. Quedan Steps 7-13 por hacer (6-7 commits mas). Con la fusion de Steps 4/5, el total seria ~13. Esta dentro del minimo de 10 pero ya no hay margen para mas fusiones.

---

**Commit sugerido para fixes:** `fix(app): address health endpoint, race conditions and manifest issues`
