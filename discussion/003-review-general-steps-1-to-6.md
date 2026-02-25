# Review #003: Revision General Pasos 1 al 6

**Fecha:** 2026-02-25
**Commits revisados:** `9160278` a `f826de3` (15 commits)
**Revisor:** Supervisor
**Estado:** REQUIERE CORRECCIONES URGENTES

---

## Resumen Ejecutivo

El proyecto tiene una base estructural solida: buena organizacion, Dockerfile ejemplar, circuit breaker bien implementado, labels consistentes, RBAC scoped. Sin embargo, hay **un bug de integracion critico** que hace que todo el sistema de canary analysis sea no funcional, y el DESIGN.md (15 pts) esta al 30% de completitud. Si no se corrigen estos dos temas, el proyecto pierde ~25-30 puntos de los 100.

---

## HALLAZGO #1: BUG CRITICO DE INTEGRACION — AnalysisTemplates no funcionan

**Severidad: CRITICA — Afecta Canary Deployment (20pts) + Health Validation (15pts)**

### El problema

Hay un mismatch entre como el Rollout pasa la version al AnalysisTemplate y como la app emite metricas:

1. **Rollout** (`k8s/base/rollout.yaml` lineas 86-88) pasa `canary-version` usando:
   ```yaml
   valueFrom:
     podTemplateHashValue: Latest  # Resuelve a algo como "6b7d8f9abc"
   ```

2. **AnalysisTemplates** (`k8s/rollouts/analysis-template.yaml` linea 23) filtran por:
   ```promql
   version="{{args.canary-version}}"  # Busca version="6b7d8f9abc"
   ```

3. **La app Go** (`app/handlers/authorize.go` linea 170) emite metricas con:
   ```go
   "version", handlers.ServiceVersion  # Emite version="1.0.0"
   ```

**Resultado:** Las queries PromQL buscan `version="6b7d8f9abc"` pero las metricas tienen `version="1.0.0"`. **Todas las analysis queries retornan datos vacios.** El canary analysis es completamente no funcional.

### Fix propuesto

Opcion A (recomendada): Cambiar el Rollout para pasar la version semantica en vez del hash:
```yaml
args:
  - name: canary-version
    value: "{{templates.podTemplateHash}}"  # NO — esto es lo que ya fallo
```

Opcion B (mas robusta): Hacer que la app use el pod template hash como label de version, leyendo de una variable de entorno inyectada por el Rollout. Pero esto requiere cambios en la app y el ConfigMap.

Opcion C (pragmatica): Quitar el filtro de `version` de las queries PromQL y filtrar por `pod=~"canary.*"` usando los labels que Argo Rollouts inyecta automaticamente en los pods canary. Esto es mas simple y no depende de version labels.

**Accion requerida:** Elegir una opcion e implementarla. Sin esto, los 20 pts de Canary Deployment y parte de los 15 pts de Health Validation se pierden.

---

## HALLAZGO #2: DestinationRule no aplica al trafico real

**Severidad: CRITICA**

**Archivo:** `k8s/networking/destination-rule.yaml` linea 25

El DestinationRule tiene `host: auth-service` (servicio primario). Pero durante canary rollouts, el VirtualService rutea trafico a `auth-service-stable` y `auth-service-canary`. El DestinationRule NO aplica a estos servicios porque son hosts diferentes.

**Resultado:** Connection pooling, outlier detection y todas las traffic policies son decorativas — nunca se aplican al trafico real.

### Fix

Crear DestinationRules para los servicios stable y canary:
```yaml
# Para auth-service-stable
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: auth-service-stable
spec:
  host: auth-service-stable
  trafficPolicy: ...

# Para auth-service-canary
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: auth-service-canary
spec:
  host: auth-service-canary
  trafficPolicy: ...
```

---

## HALLAZGO #3: DESIGN.md al 30% — 15 puntos en riesgo

**Severidad: CRITICA para puntuacion**

DESIGN.md fue creado en commit `e897b20` y **nunca actualizado desde entonces**. Solo cubre el Step 2 (Go service). Faltan secciones para:

| Paso | Seccion faltante en DESIGN.md |
|---|---|
| 3 | Setup.sh: por que check-and-install, por que esos recursos de Minikube |
| 4 | RBAC/NetworkPolicy: por que namespace-scoped, por que esas reglas de egress |
| 5 | Argo Rollout: por que Argo Rollouts sobre Flagger, por que 10/50/100 |
| 6 | Istio: por que Ambient sobre sidecars, por que no Kubernetes Gateway API |
| 7 | AnalysisTemplates: por que esos umbrales, por que esas metricas |
| 8-9 | CI/CD: por que Trivy, por que SHA+latest tagging, por que manual CD |
| 10 | Monitoring: por que Prometheus/Grafana sobre alternativas |
| 11 | Tests: por que kubeconform, estrategia de testing |
| 12 | Secrets: por que Vault+ESO, fallback a SealedSecrets |
| N/A | Failure scenarios: que pasa si Prometheus cae, si Vault falla, si nodo reinicia |

**El README hace promesas falsas** — dice que DESIGN.md contiene "Argo Rollouts vs Flagger comparison" e "Istio Ambient vs sidecar trade-offs". Ninguno existe.

**Estimacion actual: 6-8/15 pts.** La seccion de Go es top-quartile pero el documento se detiene ahi. Para llegar a 12-15 pts, cada paso necesita una seccion con la misma profundidad.

---

## HALLAZGO #4: RUNBOOK.md no existe

**Severidad: CRITICA**

El README (linea 311) dice: "See [RUNBOOK.md](RUNBOOK.md) for detailed operational procedures."

El plan lista `RUNBOOK.md` como entregable.

**El archivo no existe.** Es un broken link que un evaluador detecta inmediatamente.

El RUNBOOK.md es un entregable explicito del challenge y afecta:
- Observability & Operational Usability (10 pts)
- Canary Deployment (20 pts) — requiere instrucciones de promote/rollback

---

## HALLAZGO #5: Prometheus scrape target mal configurado

**Severidad: CRITICA**

La config de Prometheus (`k8s/monitoring/prometheus-config.yaml`) tiene un relabel rule que busca la annotation `prometheus.io/port` en los pods. Pero el Rollout pod template **NO tiene esa annotation**.

**Resultado:** Prometheus puede no scrapear correctamente las metricas de los pods del auth-service. Si Prometheus no tiene metricas, los AnalysisTemplates no pueden evaluar nada.

### Fix

Agregar annotations al pod template del Rollout:
```yaml
template:
  metadata:
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "8080"
      prometheus.io/path: "/metrics"
```

---

## HALLAZGO #6: Gateway puede no funcionar en Ambient Mesh

**Severidad: IMPORTANTE**

- `gateway.yaml` usa el API clasico `networking.istio.io/v1beta1` con `selector: istio: ingressgateway`
- En modo ambient, la instalacion por defecto NO despliega `istio-ingressgateway`
- El script setup.sh no instala explicitamente el ingress gateway component

**Resultado:** El Gateway resource puede no tener un controller que lo procese.

### Fix

Opciones:
1. Agregar `istioctl install --set components.ingressGateways[0].enabled=true` al setup.sh
2. Migrar a Kubernetes Gateway API (`gateway.networking.k8s.io/v1`) que si funciona con ambient
3. Documentar en DESIGN.md por que se eligio el API clasico y el requisito del ingress gateway

---

## HALLAZGO #7: Health endpoint — mejoras aplicadas pero incompletas

### Lo que se corrigio (bien hecho)
- Health endpoint ahora retorna `latency_p95_ms` (campo requerido por el challenge)
- Retorna HTTP 503 cuando circuit breaker esta abierto
- `FaultConfig` ahora usa `sync.RWMutex` (race condition corregida)
- `http.MaxBytesReader` aplicado en endpoints POST (body size limits)

### Lo que aun falta
- **P95 computation tiene edge case:** Cuando hay multiples combinaciones de labels (version, status, processor), el loop sobreescribe `p95Seconds` en cada iteracion. Solo se retorna el P95 del ultimo histograma procesado, no un agregado
- **`auth_success_rate` gauge** — verificar si se actualiza o sigue siendo dead code
- **Zero unit tests** — ningun `*_test.go` en todo el directorio `app/`
- **No graceful shutdown** — `http.ListenAndServe` sin manejo de SIGTERM. Pods canary que se terminan durante rollback dropean requests in-flight
- **No HTTP server timeouts** — vulnerable a slowloris
- **`/admin/fault-inject` sin autenticacion** — cualquiera puede sabotear el servicio

---

## HALLAZGO #8: setup.sh — problemas de robustez

### Criticos
| Issue | Detalle |
|---|---|
| `kubectl wait || true` | En lineas 367, 391, 416 — si Istio/Argo/ESO nunca arrancan, el script reporta exito |
| No Docker daemon check | Minikube con `--driver=docker` fallara si Docker no esta corriendo |
| No Homebrew check (macOS) | Todas las instalaciones macOS usan `brew` sin verificar que existe |
| ESO install desde `main` branch | URLs inestables + `2>/dev/null || true` = instalacion silenciosamente rota |

### Importantes
| Issue | Detalle |
|---|---|
| Sin version pinning | Todas las herramientas usan `latest` — no reproducible |
| `curl \| sh` para Istio | Con `2>/dev/null` que oculta errores |
| Linux = Ubuntu only | Hardcoded para apt-get/dpkg sin documentar la limitacion |
| Istio check no verifica ambient | Solo cuenta pods, no confirma que sea modo ambient |

---

## HALLAZGO #9: NetworkPolicy — mejorada pero con remanentes

- **Fix aplicado correctamente:** OR→AND en regla de Prometheus (commit `f826de3`)
- **Aun pendiente:** DNS egress duplicado (regla generica en lineas 43-46 + regla especifica a kube-system en 55-61)
- **Aun pendiente:** Egress intra-namespace demasiado amplio (`podSelector: {}` sin restriccion de puertos)

---

## HALLAZGO #10: PDB puede causar deadlocks durante canary

`minAvailable: 2` con 3 replicas. Durante canary rollout, el selector `app: auth-service` matchea TANTO stable como canary pods. Si hay node drain + canary rollout simultaneamente, el PDB puede bloquear evictions.

**Fix:** Cambiar a `maxUnavailable: 1` que escala mejor.

---

## HALLAZGO #11: Canary weight progression agresiva

El Rollout salta de 10% directamente a 50%. Para un servicio de autorizacion de pagos que procesa 2.4M txn/dia:
- 10% = 240K transacciones
- 50% = 1.2M transacciones

Un salto de 10% a 50% sin paso intermedio es riesgoso. Considerar: 10% → 25% → 50% → 100%.

---

## HALLAZGO #12: Thresholds inconsistentes

| Metrica | Plan/SLO | AnalysisTemplate | Alerting Rule | Grafana |
|---|---|---|---|---|
| Success Rate | > 80% | > 0.80 | < 0.90 (alert) | 90% |
| P95 Latency | < 2.5s | < 2.5 | < 2500ms | N/A |

El canary gate usa 80% pero la alerta dispara a 90%. Un canary con 85% success rate pasaria el analysis pero dispararia alertas. Esto deberia estar documentado en DESIGN.md como decision intencional o corregirse.

---

## HALLAZGO #13: CanaryDegradation alert no va a matchear

`alerting-rules.yaml` linea 49 filtra con `version=~".*canary.*"`. Pero la app emite `version="1.0.0"` (semver). Ningun pod canary tiene "canary" en su version label. La alerta nunca disparara.

---

## HALLAZGO #14: Commits — Steps 4 y 5 fusionados

El plan decia 2 commits separados. Se fusionaron en `291783c`. Esto viola "Un commit por tarea completada" del CLAUDE.md. El conteo actual (15 commits) supera el minimo de 10, asi que no es critico, pero es una desviacion del plan.

---

## HALLAZGO #15: Staging namespace vacio

`paystream-staging` existe en `namespaces.yaml` pero no tiene manifiestos de workload (solo secrets). Para el stretch goal de Multi-Environment Strategy, deberia tener al menos un ConfigMap diferenciado o documentar que es reserved for future use.

---

## RESUMEN: Impacto estimado en puntuacion

| Criterio | Max | Estimado Actual | Despues de Fixes |
|---|---|---|---|
| Infrastructure Code Quality | 25 | 18 | 22 |
| Canary Deployment | 20 | 8* | 17 |
| Health Validation & Reliability | 15 | 10 | 13 |
| Security Practices | 15 | 11 | 13 |
| Observability & Operational Usability | 10 | 5** | 8 |
| Design Decisions Document | 15 | 6*** | 13 |
| **TOTAL** | **100** | **58** | **86** |

\* Canary analysis es no funcional por version mismatch
\** RUNBOOK.md no existe
\*** DESIGN.md solo cubre 1 de 13 pasos

---

## PRIORIDAD DE FIXES

### BLOQUE 1 — Hacer AHORA (recupera ~28 puntos)

| # | Fix | Puntos que recupera |
|---|---|---|
| 1 | **Fix version label mismatch** en AnalysisTemplates/Rollout/App | ~10 pts (Canary + Health) |
| 2 | **Completar DESIGN.md** con secciones para todos los pasos | ~7 pts (Design Decisions) |
| 3 | **Crear RUNBOOK.md** con deploy canary, check health, promote, rollback | ~4 pts (Observability) |
| 4 | **Agregar Prometheus annotations** al pod template del Rollout | ~3 pts (Canary + Health) |
| 5 | **Fix DestinationRule** para aplicar a stable/canary services | ~2 pts (Infrastructure) |
| 6 | **Fix README** — quitar referencias falsas a contenido inexistente | ~2 pts (Design Decisions) |

### BLOQUE 2 — Hacer PRONTO (recupera ~5-8 puntos)

| # | Fix |
|---|---|
| 7 | Fix CanaryDegradation alert regex |
| 8 | Fix Gateway para ambient mesh (agregar ingress gateway o migrar a K8s Gateway API) |
| 9 | Agregar graceful shutdown a la app Go |
| 10 | Fix PDB: `maxUnavailable: 1` en vez de `minAvailable: 2` |
| 11 | Reconciliar thresholds 80% vs 90% |
| 12 | Agregar paso intermedio al canary (10% → 25% → 50% → 100%) |

### BLOQUE 3 — Hacer si hay tiempo

| # | Fix |
|---|---|
| 13 | setup.sh: quitar `|| true` de waits criticos |
| 14 | setup.sh: agregar Docker daemon y Homebrew checks |
| 15 | setup.sh: version pinning |
| 16 | Agregar unit tests a la app Go |
| 17 | Limpiar NetworkPolicy (DNS duplicado, egress amplio) |
| 18 | Poblar staging namespace con ConfigMap diferenciado |

---

## LO QUE ESTA BIEN

Para que conste: hay mucho trabajo bien hecho.

- Dockerfile es ejemplar (distroless, nonroot, multi-stage, stripped binary)
- Circuit breaker con sony/gobreaker bien configurado
- RBAC genuinamente least-privilege (resourceNames scoped)
- Labels consistentes `app.kubernetes.io/*` en todos los recursos
- Patron de 3 Services para Argo Rollouts + Istio correcto
- DestinationRule con outlier detection y connection pooling (concepto correcto, host incorrecto)
- setup.sh idempotente con colored output y architecture-aware
- Conventional Commits consistentes y descriptivos
- Supervisor feedback fue incorporado (commit de fix)
- Metricas Prometheus con labels que habilitan canary analysis (version, status, processor)
- DESIGN.md seccion Go es genuinamente top-quartile

El proyecto tiene la arquitectura correcta. Los problemas son de **integracion** (las piezas no encajan entre si) y **completitud** (DESIGN.md, RUNBOOK.md). Corregir el Bloque 1 sube el score estimado de 58 a ~86.
