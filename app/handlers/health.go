package handlers

import (
	"encoding/json"
	"math"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"

	"github.com/paintoxic/paystream-auth-service/metrics"
)

type healthResponse struct {
	Status         string  `json:"status"`
	LatencyP95MS   float64 `json:"latency_p95_ms"`
	SuccessRate    float64 `json:"success_rate"`
	CircuitBreaker string  `json:"circuit_breaker"`
	Version        string  `json:"version"`
	UptimeSeconds  float64 `json:"uptime_seconds"`
}

// computeP95 reads the P95 latency from the Prometheus histogram.
func computeP95() float64 {
	ch := make(chan prometheus.Metric, 100)
	metrics.AuthRequestDuration.Collect(ch)
	close(ch)

	var totalCount uint64
	var p95Seconds float64

	for m := range ch {
		metric := new(dto.Metric)
		if err := m.Write(metric); err != nil {
			continue
		}
		if metric.Histogram == nil {
			continue
		}
		totalCount += metric.Histogram.GetSampleCount()
		p95Seconds = histogramQuantile(0.95, metric.Histogram)
	}

	if totalCount == 0 {
		return 0
	}
	// Convert seconds to milliseconds
	return math.Round(p95Seconds * 1000)
}

// histogramQuantile computes an approximate quantile from histogram buckets.
func histogramQuantile(q float64, h interface {
	GetBucket() []*dto.Bucket
	GetSampleCount() uint64
}) float64 {
	buckets := h.GetBucket()
	total := float64(h.GetSampleCount())
	if total == 0 {
		return 0
	}
	target := q * total
	var prev float64
	for _, b := range buckets {
		count := float64(b.GetCumulativeCount())
		if count >= target {
			// Linear interpolation within bucket
			upper := b.GetUpperBound()
			if math.IsInf(upper, 1) {
				return prev
			}
			return upper
		}
		prev = b.GetUpperBound()
	}
	return prev
}

func HealthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	status := "healthy"
	cbState := "closed"

	if CircuitBreaker != nil {
		cbState = CircuitBreaker.State()
		switch cbState {
		case "half-open":
			status = "degraded"
		case "open":
			status = "unhealthy"
		default:
			status = "healthy"
		}
	}

	uptime := time.Since(StartTime).Seconds()
	realSuccessRate := ObservedSuccessRate()
	p95 := computeP95()

	resp := healthResponse{
		Status:         status,
		LatencyP95MS:   p95,
		SuccessRate:    realSuccessRate,
		CircuitBreaker: cbState,
		Version:        ServiceVersion,
		UptimeSeconds:  uptime,
	}

	w.Header().Set("Content-Type", "application/json")
	if status == "unhealthy" {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	json.NewEncoder(w).Encode(resp)
}
