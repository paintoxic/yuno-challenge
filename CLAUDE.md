# CLAUDE.md - Prueba Tecnica DevOps

## Contexto

Este repositorio es para una prueba tecnica de DevOps. Todo el trabajo debe demostrar conocimientos solidos en infraestructura, CI/CD, networking y despliegues progresivos.

---

## Rol de Sesion

**Al iniciar cada sesion, preguntar al usuario:**

> "Hola! Que rol tiene esta sesion: **supervisor** o **trabajador**?"

### Supervisor

- Tu unica tarea es revisar continuamente el trabajo realizado por el trabajador.
- Revisa commits, manifiestos, scripts, documentacion y estructura del proyecto.
- Identifica errores, mejoras y desviaciones del plan.
- No implementes codigo; solo revisa, comenta y sugiere correcciones.
- Usa el agente `superpowers:code-reviewer` despues de cada revision.

### Trabajador

- Formula un plan detallado para cumplir el objetivo de la prueba.
- Presenta el plan al usuario para discutirlo y aprobarlo antes de ejecutar.
- Ejecuta el plan paso a paso, haciendo commits por cada tarea completada.
- **Despues de cada commit, hacer push inmediatamente al remoto.**
- **Antes de cada push, explicar al usuario que se hizo, por que se hizo y que impacto tiene en el proyecto.**
- Sigue todas las directrices de este CLAUDE.md al pie de la letra.

---

## Verificacion de Repositorio Git

**ANTES de hacer cualquier cosa, verificar:**

1. Ejecutar `git status` para comprobar si estamos en un repositorio Git.
2. Si **SI** es un repo Git: verificar que tenga remote configurado (`git remote -v`).
3. Si **NO** es un repo Git: preguntar al usuario por la URL del repositorio de GitHub antes de continuar.
4. No iniciar ninguna tarea hasta confirmar que el repositorio esta correctamente configurado.

---

## Stack Tecnologico

| Componente | Herramienta |
|---|---|
| Orquestacion local | **Minikube** |
| Manifiestos | **Kubernetes YAML** (sin Helm salvo que se requiera) |
| CI/CD | **GitHub Actions** |
| Registry | **DockerHub** |
| Despliegues progresivos | **Argo Rollouts** (canary, blue-green) |
| Service Mesh / Networking | **Istio Ambient Mesh** |
| IaC (si aplica) | **Terragrunt** (wrapper sobre Terraform, DRY configs) |

---

## Estructura del Proyecto

```
/
├── CLAUDE.md
├── README.md                    # Documentacion completa del proyecto
├── setup.sh                     # Script de instalacion y configuracion
├── k8s/                         # Manifiestos de Kubernetes
│   ├── base/                    # Recursos base (deployments, services, configmaps)
│   ├── networking/              # Configuracion de Istio (gateways, virtual services)
│   ├── rollouts/                # Configuraciones de Argo Rollouts
│   └── namespaces.yaml
├── .github/
│   └── workflows/               # Pipelines de GitHub Actions
│       ├── ci.yaml              # Build, test, lint
│       └── cd.yaml              # Deploy
├── infra/                       # Terragrunt / Terraform (si aplica IaC)
│   ├── terragrunt.hcl           # Config raiz de Terragrunt
│   └── modules/                 # Modulos Terraform reutilizables
├── app/                         # Codigo fuente de la aplicacion (si aplica)
│   ├── Dockerfile
│   └── ...
├── tests/                       # Tests con data mockeada realista
│   └── ...
└── docs/                        # Documentacion adicional si es necesario
    └── architecture.md
```

---

## Script de Setup (setup.sh)

El script `setup.sh` debe:

1. **Detectar el SO** (macOS/Linux).
2. **Verificar e instalar** las siguientes herramientas si no estan presentes:
   - `docker`
   - `minikube`
   - `kubectl`
   - `istioctl`
   - `kubectl-argo-rollouts` (plugin de Argo Rollouts)
   - `terraform`
   - `terragrunt`
   - `gh` (GitHub CLI)
   - `jq`, `curl`, `git`
3. **Iniciar Minikube** con recursos adecuados (minimo 4 CPUs, 8GB RAM).
4. **Instalar Istio** en modo Ambient Mesh.
5. **Instalar Argo Rollouts** en el cluster.
6. **Verificar** que todos los componentes estan corriendo correctamente.
7. **Mostrar un resumen** del estado del cluster al finalizar.

Cada paso debe tener:
- Verificacion previa (no reinstalar lo que ya existe).
- Mensajes claros de progreso.
- Manejo de errores con mensajes descriptivos.
- Colores en la salida para mejor legibilidad.

---

## Politica de Commits

### Formato: Conventional Commits

```
<tipo>(<alcance>): <descripcion>

[cuerpo opcional]

[footer opcional]
```

### Tipos permitidos

| Tipo | Uso |
|---|---|
| `feat` | Nueva funcionalidad |
| `fix` | Correccion de errores |
| `docs` | Solo documentacion |
| `ci` | Cambios en CI/CD |
| `infra` | Cambios en infraestructura/manifiestos |
| `test` | Agregar o modificar tests |
| `refactor` | Refactorizacion sin cambio funcional |
| `chore` | Tareas de mantenimiento |
| `script` | Scripts de automatizacion |

### Reglas

- **Minimo 10 commits** en total, todos claros y concisos.
- **Un commit por tarea completada**, nunca agrupar multiples tareas en un commit.
- Los mensajes deben ser descriptivos y en ingles.
- Ejemplos:
  - `infra(k8s): add base deployment and service manifests for api`
  - `ci(gh-actions): configure build and push pipeline to dockerhub`
  - `infra(istio): configure ambient mesh with gateway and virtual services`
  - `feat(rollouts): add canary strategy with argo rollouts for api`
  - `script(setup): add automated cluster setup with dependency checks`
  - `docs(readme): add architecture overview and setup instructions`
  - `test(api): add integration tests with realistic mock data`

---

## Manifiestos de Kubernetes

- Todos los manifiestos van en el directorio `k8s/`.
- Usar `apiVersion` correctos y actualizados.
- Incluir `resources` (requests/limits) en todos los deployments.
- Incluir `readinessProbe` y `livenessProbe` donde aplique.
- Usar `labels` consistentes para facilitar el debugging.
- Separar por responsabilidad: base, networking, rollouts.
- El README debe explicar el orden de aplicacion de los manifiestos.

---

## CI/CD con GitHub Actions

- Pipeline de **CI**: build, lint, test, push de imagen a DockerHub.
- Pipeline de **CD**: deploy al cluster (documentar como se conecta al cluster).
- Usar secretos de GitHub para credenciales de DockerHub.
- Tagear imagenes con el SHA del commit y `latest`.
- Incluir step de verificacion de imagen.

---

## Argo Rollouts

- Usar `Rollout` en lugar de `Deployment` para los servicios que requieran despliegue progresivo.
- Configurar estrategia canary o blue-green segun el caso.
- Integrar con Istio para traffic splitting.
- Incluir `AnalysisTemplate` para validaciones automaticas si aplica.
- Documentar como promover o hacer rollback.

---

## Istio Ambient Mesh

- Instalar Istio en modo **ambient** (sin sidecars).
- Configurar `Gateway` y `VirtualService` para routing.
- Usar `waypoint proxies` donde sea necesario para L7 policies.
- Documentar la topologia de red en el README.

---

## Testing

- Los tests deben usar **data mockeada pero realista**.
- Evitar datos genericos como "test", "foo", "bar".
- Usar nombres, valores y estructuras que reflejen escenarios reales.
- Incluir tests de:
  - Funcionamiento de la aplicacion.
  - Conectividad de servicios.
  - Configuracion de manifiestos (kubeval/kubeconform si aplica).

---

## Documentacion (README.md)

El README debe incluir:

1. **Titulo y descripcion** del proyecto.
2. **Arquitectura** con diagrama (puede ser ASCII o mermaid).
3. **Prerequisitos** del sistema.
4. **Guia de instalacion** paso a paso usando `setup.sh`.
5. **Estructura del proyecto** explicada.
6. **Como aplicar los manifiestos** (orden y comandos).
7. **Pipeline de CI/CD** explicado.
8. **Estrategia de despliegue** (canary/blue-green) explicada.
9. **Networking** (Istio) explicado.
10. **Como ejecutar tests**.
11. **Decisiones tecnicas** - justificar cada herramienta elegida.
12. **Troubleshooting** comun.

---

## Metodologia de Trabajo

1. **Planificar**: Crear un plan detallado con pasos numerados antes de escribir codigo.
2. **Discutir**: Presentar el plan al usuario para aprobacion.
3. **Ejecutar**: Implementar paso a paso, commit por tarea.
4. **Documentar**: Actualizar README conforme se avanza.
5. **Verificar**: Validar que cada paso funciona antes de avanzar al siguiente.
6. **Revisar**: El supervisor revisa el trabajo del trabajador periodicamente.

---

## Uso de Agentes Paralelos

**OBLIGATORIO: Maximizar el uso de agentes paralelos para acelerar la ejecucion de tareas.**

### Reglas

- Cuando una tarea se pueda descomponer en subtareas **independientes** (sin dependencias entre si), despachar multiples agentes en paralelo usando el skill `superpowers:dispatching-parallel-agents` o la herramienta `Task`.
- Lanzar los agentes en un **unico mensaje** con multiples llamadas a `Task` para que se ejecuten concurrentemente.
- Usar el tipo de agente adecuado segun la subtarea:
  - `general-purpose`: Tareas complejas que requieren investigacion y ejecucion.
  - `Explore`: Busqueda y exploracion rapida del codebase.
  - `Plan`: Diseno de planes de implementacion.
  - `superpowers:code-reviewer`: Revision de codigo tras completar pasos del plan.
- Usar **worktrees aislados** (`isolation: "worktree"`) cuando multiples agentes necesiten modificar archivos simultaneamente para evitar conflictos.

### Cuando usar agentes paralelos

| Escenario | Ejemplo |
|---|---|
| Crear multiples archivos independientes | Manifiestos K8s de diferentes servicios, workflows de CI y CD |
| Investigar multiples temas a la vez | Buscar docs de Istio, Argo Rollouts y GitHub Actions simultaneamente |
| Escribir codigo + tests al mismo tiempo | Un agente escribe la app, otro prepara los tests |
| Revisar + implementar en paralelo | Un agente revisa el paso anterior mientras otro avanza al siguiente |
| Crear estructura del proyecto | Multiples agentes creando archivos en diferentes directorios |

### Cuando NO usar agentes paralelos

- Cuando una tarea **depende del resultado** de otra (ejecutar secuencialmente).
- Cuando se modifica el **mismo archivo** desde multiples agentes (riesgo de conflicto).
- Para tareas triviales que se resuelven en una sola operacion.

### Flujo recomendado

1. Identificar las subtareas del paso actual del plan.
2. Clasificar cuales son independientes y cuales tienen dependencias.
3. Lanzar todas las independientes en paralelo.
4. Esperar resultados y consolidar.
5. Ejecutar las dependientes secuencialmente.
6. Verificar el resultado integrado antes de hacer commit.

---

## Alternativas y Escalabilidad

- Si una herramienta no funciona o no es la mejor opcion, proponer alternativas.
- Las alternativas deben ser:
  - Mantenidas activamente por la comunidad.
  - Escalables para produccion.
  - Bien documentadas.
- Documentar la razon del cambio en el commit y README.

---

## Mejores Practicas DevOps a Destacar

- **Infrastructure as Code**: Todo reproducible desde el repositorio.
- **GitOps**: El estado deseado esta en Git.
- **Immutable Infrastructure**: Imagenes inmutables, sin cambios en runtime.
- **Observabilidad**: Mencionar como se podria agregar monitoring (Prometheus, Grafana).
- **Seguridad**: Imagenes base minimas, no correr como root, escaneo de vulnerabilidades.
- **12-Factor App**: Configuracion por variables de entorno, logs a stdout.
- **Least Privilege**: RBAC donde aplique.
