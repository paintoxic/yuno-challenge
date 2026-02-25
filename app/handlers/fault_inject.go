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

	var req faultInjectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	FaultInjectionEnabled = req.Enabled
	FaultLatencyMS = req.LatencyMS
	FaultSuccessRate = req.SuccessRate

	resp := faultInjectResponse{
		FaultInjection: faultInjectConfig{
			Enabled:     FaultInjectionEnabled,
			LatencyMS:   FaultLatencyMS,
			SuccessRate: FaultSuccessRate,
		},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
