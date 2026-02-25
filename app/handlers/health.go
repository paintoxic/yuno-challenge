package handlers

import (
	"encoding/json"
	"net/http"
	"time"
)

type healthResponse struct {
	Status         string  `json:"status"`
	Version        string  `json:"version"`
	CircuitBreaker string  `json:"circuit_breaker"`
	SuccessRate    float64 `json:"success_rate"`
	UptimeSeconds  float64 `json:"uptime_seconds"`
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

	resp := healthResponse{
		Status:         status,
		Version:        ServiceVersion,
		CircuitBreaker: cbState,
		SuccessRate:    SuccessRate,
		UptimeSeconds:  uptime,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
