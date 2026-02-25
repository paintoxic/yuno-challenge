package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"net/http"
)

var AuthRequestDuration = prometheus.NewHistogramVec(
	prometheus.HistogramOpts{
		Name:    "auth_request_duration_seconds",
		Help:    "Duration of authorization requests in seconds.",
		Buckets: []float64{0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	},
	[]string{"version", "status", "processor"},
)

var AuthRequestsTotal = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Name: "auth_requests_total",
		Help: "Total number of authorization requests.",
	},
	[]string{"version", "status", "processor"},
)

var AuthSuccessRate = prometheus.NewGauge(
	prometheus.GaugeOpts{
		Name: "auth_success_rate",
		Help: "Current authorization success rate (0-1).",
	},
)

var CircuitBreakerState = prometheus.NewGauge(
	prometheus.GaugeOpts{
		Name: "circuit_breaker_state",
		Help: "Current circuit breaker state: 0=closed, 1=half-open, 2=open.",
	},
)

var CircuitBreakerTripsTotal = prometheus.NewCounter(
	prometheus.CounterOpts{
		Name: "circuit_breaker_trips_total",
		Help: "Total number of circuit breaker trips.",
	},
)

func Init() {
	prometheus.MustRegister(
		AuthRequestDuration,
		AuthRequestsTotal,
		AuthSuccessRate,
		CircuitBreakerState,
		CircuitBreakerTripsTotal,
	)
}

func Handler() http.Handler {
	return promhttp.Handler()
}
