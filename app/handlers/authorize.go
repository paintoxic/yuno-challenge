package handlers

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"time"

	"github.com/paintoxic/paystream-auth-service/metrics"
)

// Shared configurable variables (set from main.go via env vars)
var (
	LatencyBaseMS  int     = 200
	SuccessRate    float64 = 0.94
	ServiceVersion string  = "1.0.0"

	FaultInjectionEnabled bool    = false
	FaultLatencyMS        int     = 0
	FaultSuccessRate      float64 = 1.0

	StartTime time.Time
)

// BreakerInterface abstracts the circuit breaker for testability.
type BreakerInterface interface {
	Execute(func() (interface{}, error)) (interface{}, error)
	State() string
	StateValue() float64
}

// CircuitBreaker is set from main.go before handlers are invoked.
var CircuitBreaker BreakerInterface

type authorizeRequest struct {
	CardNumber string  `json:"card_number"`
	Amount     float64 `json:"amount"`
	Currency   string  `json:"currency"`
	Merchant   string  `json:"merchant"`
	Processor  string  `json:"processor"`
}

type authorizeResponse struct {
	TransactionID string  `json:"transaction_id"`
	Status        string  `json:"status"`
	Processor     string  `json:"processor"`
	Amount        float64 `json:"amount"`
	LatencyMS     int64   `json:"latency_ms"`
	Version       string  `json:"version"`
}

type errorResponse struct {
	Error  string `json:"error"`
	Reason string `json:"reason"`
}

func AuthorizeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	var req authorizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	txnID := fmt.Sprintf("txn-%d-%04d", time.Now().UnixNano(), rand.Intn(10000))

	start := time.Now()

	result, cbErr := CircuitBreaker.Execute(func() (interface{}, error) {
		latency := LatencyBaseMS
		if FaultInjectionEnabled && FaultLatencyMS > 0 {
			latency = FaultLatencyMS
		}
		jitter := rand.Intn(101) - 50
		sleepMS := latency + jitter
		if sleepMS < 0 {
			sleepMS = 0
		}
		time.Sleep(time.Duration(sleepMS) * time.Millisecond)

		rate := SuccessRate
		if FaultInjectionEnabled {
			rate = FaultSuccessRate
		}

		if rand.Float64() < rate {
			return "approved", nil
		}
		return "declined", fmt.Errorf("bank declined transaction")
	})

	elapsed := time.Since(start)
	latencyMS := elapsed.Milliseconds()

	if cbErr != nil && CircuitBreaker.State() == "open" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(errorResponse{
			Error:  "service unavailable",
			Reason: "circuit breaker open",
		})
		return
	}

	status := "approved"
	if result == nil || result.(string) != "approved" {
		status = "declined"
	}

	processor := req.Processor
	if processor == "" {
		processor = "unknown"
	}

	metrics.AuthRequestDuration.WithLabelValues(ServiceVersion, status, processor).
		Observe(elapsed.Seconds())
	metrics.AuthRequestsTotal.WithLabelValues(ServiceVersion, status, processor).
		Inc()

	resp := authorizeResponse{
		TransactionID: txnID,
		Status:        status,
		Processor:     processor,
		Amount:        req.Amount,
		LatencyMS:     latencyMS,
		Version:       ServiceVersion,
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
}
