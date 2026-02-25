# Review #001: Plan Inicial y Estructura del Proyecto

**Fecha:** 2026-02-25
**Commits revisados:** `9160278`, `9bb2845`
**Revisor:** Supervisor
**Estado:** REQUIERE CAMBIOS ANTES DE CONTINUAR

---

## Veredicto

La base es solida. El plan es ambicioso, bien estructurado y los commits siguen convenciones. Sin embargo, hay problemas que deben corregirse **antes de avanzar al Step 2**.

---

## CRITICO — Bloquea la ejecucion

### 1. Falta mapeo explicito de requisitos del challenge

El plan mapea contra la rubrica de puntos pero **no lista los 6 requisitos del challenge**. Esto es peligroso porque se podria omitir un entregable. Agregar una seccion al plan con:

| Requisito | Tipo | Paso |
|---|---|---|
| Canary Deployment Infrastructure | Core | Steps 5, 6, 7 |
| Automated Health Validation | Core | Steps 2, 7 |
| Operational Observability | Core | Step 11 |
| Secrets Management | Stretch | Step 8 |
| Progressive Rollout Automation | Stretch | Step 7 |
| Multi-Environment Strategy | Stretch | **NO CUBIERTO — agregar** |

**Accion:** El stretch goal de Multi-Environment Strategy (staging vs production con aislamiento) no aparece en ningun paso. Debe agregarse aunque sea minimo (ej: Kustomize overlays o namespaces separados).

### 2. Reordenar Vault/ESO — moverlo despues de tests

Vault + ESO es un stretch goal complejo. Si se atora ahi, **bloquea CI/CD, monitoring y tests** que son requisitos core. Reordenar asi:

```
0.  Plan commit (hecho)
1.  Project structure (hecho)
2.  Authorization Service en Go
3.  Setup script
4.  Namespaces + RBAC
5.  Base manifests
6.  Istio networking
7.  Argo Rollouts + AnalysisTemplates
8.  CI pipeline          <-- era Step 9
9.  CD pipeline          <-- era Step 10
10. Monitoring           <-- era Step 11
11. Tests                <-- era Step 12
12. Vault + ESO          <-- era Step 8, ahora seguro como stretch
13. Documentation
```

---

## IMPORTANTE — Deberia corregirse

### 3. Fallback para Vault/ESO

Si Vault/ESO no funciona limpio, tener `SealedSecrets` o Kubernetes Secrets bien documentados como plan B. Sin fallback, los 15 pts de Security quedan en riesgo total.

### 4. Empezar DESIGN.md desde el Step 2

No dejarlo para el Step 13. Es el entregable mas facil de puntuar (15 pts) y si se escribe al final sera superficial y generico. Cada paso deberia agregar una seccion a DESIGN.md explicando:
- Que se hizo
- Por que se eligio esa herramienta/enfoque
- Que trade-offs se consideraron
- Que se haria diferente en produccion

### 5. Agregar image scanning al CI pipeline

El plan dice "build, lint, test, push" pero no menciona escaneo de vulnerabilidades de imagen (Trivy o Grype). Son puntos faciles en Security (15 pts) y CI quality (25 pts).

### 6. Agregar NetworkPolicy y PodDisruptionBudget

Para los 25 pts de Infrastructure Code Quality, estos recursos marcan la diferencia entre mediana (13-18 pts) y top quartile (20-25 pts):
- **NetworkPolicy:** Restringir trafico pod-to-pod (least privilege en networking)
- **PDB:** Garantizar disponibilidad durante disruptions (operational maturity)

### 7. Clarificar dependencia Steps 5 y 7

El `rollout.yaml` del Step 5 probablemente referencia el `AnalysisTemplate` del Step 7. Documentar explicitamente:
- Step 5 crea el Rollout **sin** analysis refs
- Step 7 actualiza el Rollout para agregar analysis refs

### 8. Falta `k8s/rollouts/` en Quick Start del README

La secuencia de `kubectl apply` en el README no incluye:
```bash
kubectl apply -f k8s/rollouts/
```
Debe ir entre base y networking (o clarificar que los rollouts son parte de base/).

---

## SUGERENCIAS — Nice to have

### 9. Definir SLOs concretos en el plan

Los AnalysisTemplates necesitan umbrales. Definirlos desde el plan:
- P95 latency < 2.5s (SLA de PayStream)
- Error rate < 1%
- Availability > 99.9%
- Success rate > 80% (TSR minimo saludable)

### 10. Mencionar en DESIGN.md como consideraciones de produccion
- HPA (Horizontal Pod Autoscaler)
- Distributed tracing (Jaeger/Zipkin)
- Log aggregation (Loki/EFK)
- Rate limiting

### 11. Verificar master vs main

El git status dice main branch es `main` pero se trabaja en `master`. Asegurar consistencia.

### 12. `docs/architecture.md` vs `DESIGN.md`

El CLAUDE.md especifica `docs/architecture.md` en la estructura. El plan lo reemplaza con `DESIGN.md` en root. Esta bien si se documenta la decision, pero asegurarse de no perder puntos por desviacion de la estructura esperada.

### 13. Ampliar .gitignore

Agregar:
```gitignore
# Coverage
coverage.out
coverage.html

# Go binary
app/paystream-auth-service

# Helm (si se usa para Vault/ESO)
charts/
*.tgz
```

---

## Lo que esta BIEN

- 14 commits planificados (supera el minimo de 10)
- Conventional Commits bien formateados con scope y descripcion clara
- Diagrama de arquitectura ASCII claro y profesional en README
- Orden de aplicacion de manifiestos documentado
- .gitignore comprensivo con exclusion de secrets
- Tabla de mapeo contra la rubrica (buena intencion)
- Estructura de directorios limpia y separada por responsabilidad
- Co-Authored-By footer consistente

---

## Accion requerida

Antes de avanzar al Step 2, hacer **un commit de actualizacion del plan** que:

1. Agregue mapeo explicito de los 6 requisitos del challenge
2. Reordene Vault/ESO despues de tests
3. Agregue Multi-Environment Strategy como paso (aunque sea minimo)
4. Defina SLOs concretos
5. Documente fallback para Vault/ESO
6. Agregue image scanning, NetworkPolicy y PDB al plan

Commit sugerido: `docs(plan): update plan with supervisor review feedback`
