package handlers

import (
	"encoding/json"
	"net/http"
)

type faultInjectRequest struct {
	Enabled     bool    `json:"enabled"`
	LatencyMS   int     `json:"latency_ms"`
	SuccessRate float64 `json:"success_rate"`
}

type faultInjectConfig struct {
	Enabled     bool    `json:"enabled"`
	LatencyMS   int     `json:"latency_ms"`
	SuccessRate float64 `json:"success_rate"`
}

type faultInjectResponse struct {
	FaultInjection faultInjectConfig `json:"fault_injection"`
}

func FaultInjectHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB limit
	var req faultInjectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	Fault.Set(req.Enabled, req.LatencyMS, req.SuccessRate)

	enabled, latencyMS, successRate := Fault.Get()
	resp := faultInjectResponse{
		FaultInjection: faultInjectConfig{
			Enabled:     enabled,
			LatencyMS:   latencyMS,
			SuccessRate: successRate,
		},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
