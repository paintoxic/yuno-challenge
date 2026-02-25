# Review #002: Pasos 5 y 6 — Base Manifests e Istio Networking

**Fecha:** 2026-02-25
**Commits revisados:** `291783c`, `05c369a`
**Revisor:** Supervisor
**Estado:** REQUIERE CORRECCIONES

---

## Veredicto

Buen trabajo en general. Labels consistentes, RBAC con least privilege, buena integracion Rollout/VirtualService y documentacion profesional en los headers de Istio. Sin embargo, hay **un bug critico en rollout.yaml** que va a romper el canary en runtime y **un error logico en la NetworkPolicy** que abre acceso indebido.

---

## CRITICO — Debe corregirse antes de continuar

### 1. Sintaxis invalida en AnalysisTemplate args (`rollout.yaml:86-87, 94-95`)

```yaml
args:
  - name: canary-version
    value: "{{templates.auth-service-health.args.canary-version}}"
```

La sintaxis `{{templates.X.args.Y}}` **no existe en Argo Rollouts**. Esto va a causar un error cuando el Rollout Controller intente crear el AnalysisRun.

**Formas validas:**
- `valueFrom: { podTemplateHashValue: Latest }` — para identificar el canary
- `value: "{{args.canary-version}}"` — referencia a args definidos en el Rollout
- Valor estatico directo

**Accion:** Reemplazar ambas ocurrencias (lineas 86-87 y 94-95). La forma mas comun para canary analysis es:

```yaml
args:
  - name: canary-hash
    valueFrom:
      podTemplateHashValue: Latest
```

O si se necesita la version como string, pasarla como argumento del Rollout:

```yaml
# En el Rollout spec:
analysis:
  args:
    - name: service-version
      value: "1.1.0"  # El CD pipeline actualiza esto
```

### 2. NetworkPolicy con OR en vez de AND para Prometheus (`network-policy.yaml:33-42`)

El YAML actual:

```yaml
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: paystream
    - podSelector:
        matchLabels:
          app: prometheus
```

Esto son **dos items separados** en la lista `from`, lo que Kubernetes interpreta como **OR**:
- Cualquier pod del namespace `paystream` puede acceder, **O**
- Cualquier pod con label `app: prometheus` en **cualquier namespace** puede acceder

**Accion:** Combinar ambos selectores en un solo item (AND):

```yaml
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: paystream
      podSelector:
        matchLabels:
          app: prometheus
```

(Sin el `-` antes de `podSelector` — ambos selectores dentro del mismo item de la lista)

---

## WARNING — Deberia corregirse

### 3. Server HTTPS sin bloque TLS (`gateway.yaml:75-84`)

Se define un server con `protocol: HTTPS` en el puerto 443, pero el bloque `tls` esta comentado. En Istio, un server HTTPS sin configuracion TLS:
- Puede ser rechazado por validacion del webhook
- Sera ignorado silenciosamente si pasa validacion

**Accion:** Comentar el bloque HTTPS **entero** (lineas 71-84), no solo el tls. Dejar un comentario indicando que se habilita en produccion:

```yaml
# --- HTTPS (production only) ---
# Uncomment and configure TLS when deploying to production:
# - port:
#     number: 443
#     name: https
#     protocol: HTTPS
#   hosts:
#     - "paystream.local"
#   tls:
#     mode: SIMPLE
#     credentialName: paystream-tls
```

### 4. Steps 4+5 combinados en un solo commit

El plan tenia Step 4 (namespaces/RBAC) y Step 5 (base manifests) como commits separados. Se combinaron en `291783c`. El CLAUDE.md dice "un commit por tarea completada, nunca agrupar multiples tareas en un commit." No es bloqueante pero tomar nota para los pasos restantes.

---

## Lo que esta BIEN HECHO

| Aspecto | Detalle |
|---|---|
| Labels consistentes | `app.kubernetes.io/*` en todos los manifiestos (name, component, part-of, managed-by) |
| RBAC least privilege | Secrets scoped a `auth-service-secrets` por `resourceNames` |
| PDB | `minAvailable: 2` con 3 replicas — correcto para servicio critico de pagos |
| Istio VirtualService | Ruta `primary` alineada con referencia en `rollout.yaml:79` |
| Retries | 3 intentos, 2s perTryTimeout, retryOn 5xx/reset/connect-failure — solido |
| Outlier detection | 5 consecutive 5xx, 30s ejection, 50% max ejection — bien calibrado |
| DestinationRule | Connection pooling (100 TCP, 10 req/conn) razonable |
| Multi-environment | Namespace `paystream-staging` con mismos labels de ambient |
| Gateway docs | Kubernetes Gateway API como alternativa documentada en comentarios |
| Mesh gateway | VirtualService incluye `mesh` gateway para trafico pod-to-pod |

---

## Accion requerida

El worker debe **antes de avanzar** al siguiente paso:

1. **[CRITICO]** Corregir la sintaxis de args en `rollout.yaml` (lineas 86-87 y 94-95)
2. **[CRITICO]** Corregir la NetworkPolicy para que los selectores de Prometheus sean AND, no OR
3. **[WARNING]** Comentar el bloque HTTPS entero en `gateway.yaml` o agregar TLS de desarrollo

Estas correcciones pueden ir en un commit tipo:
```
fix(k8s): correct rollout analysis args syntax and network policy selectors
```
