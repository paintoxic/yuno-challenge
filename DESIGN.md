# Design Decisions — PayStream Authorization Service

This document captures technical decisions, trade-offs, and rationale as each component is built. It is updated incrementally with each step.

---

## Step 2: Authorization Service (Go)

### Why Go?

- **Low latency:** Go's compiled nature and goroutine model deliver sub-millisecond overhead, critical for a payment authorization path where every millisecond counts.
- **Small binaries:** Compiles to a single static binary (~8MB), perfect for distroless containers.
- **Standard library HTTP:** No framework needed for a REST API with 3 endpoints — `net/http` is production-grade.
- **Prometheus ecosystem:** `client_golang` is the reference Prometheus client, maintained by the Prometheus team.

**Alternatives considered:**
- **Node.js/Express:** Faster to prototype, but GC pauses and single-threaded model are liabilities in a latency-sensitive payment path.
- **Rust:** Better performance ceiling, but slower iteration time for a proof-of-concept.

### Why sony/gobreaker for Circuit Breaker?

- Standard circuit breaker pattern (closed → open → half-open) with configurable thresholds.
- Actively maintained, used in production by Sony and others.
- Simple API: `Execute(fn)` wraps any function call.
- State transitions exposed as callbacks for metrics integration.

**Configuration rationale:**
- 5 consecutive failures to trip: High enough to avoid false positives from transient errors, low enough to react within ~1s at 5 RPS.
- 30s open timeout: Gives the upstream "bank" API time to recover without flooding it immediately.
- 3 half-open requests: Tests recovery gradually rather than slamming all traffic through.

**What we'd do differently in production:**
- Per-processor circuit breakers (Visa, Mastercard, AMEX) instead of one global breaker.
- Sliding window failure rate (e.g., 50% failures in 60s) instead of consecutive failures.
- Circuit breaker state shared across pods via Redis or similar for cluster-wide protection.

### Why Distroless + nonroot?

- **Attack surface:** Distroless has no shell, no package manager, no libc vulnerabilities.
- **Compliance:** Running as nonroot (UID 65532) satisfies PodSecurityStandards restricted profile.
- **Image size:** ~2MB base layer vs ~5MB alpine, ~80MB ubuntu.

### Fault Injection Design

The `/admin/fault-inject` endpoint allows dynamic degradation for demos:
- Configurable latency: Simulates slow database or network issues
- Configurable success rate: Simulates intermittent failures
- Toggle on/off without restart

This is critical for demonstrating canary rollback — inject faults into the canary version and observe Argo Rollouts automatically rolling back.

**Production note:** This endpoint would be behind authentication/authorization and rate-limited. In this exercise, it's open for demo purposes.

---

## Production Considerations (Not Implemented)

These would be part of a production deployment:

- **HPA (Horizontal Pod Autoscaler):** Scale based on CPU/memory or custom metrics (request rate).
- **Distributed Tracing:** Jaeger or Zipkin for end-to-end transaction tracing across services.
- **Log Aggregation:** Loki or EFK stack for centralized log management.
- **Rate Limiting:** Istio rate limiting or application-level rate limiting per client/API key.
- **mTLS:** Istio Ambient provides mTLS by default via ztunnel — document this.
- **Multi-region:** Active-active or active-passive with DNS-based failover.

---

_Updated incrementally as each step is completed._
