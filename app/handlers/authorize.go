package handlers

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/paintoxic/paystream-auth-service/metrics"
)

// Shared configurable variables (set from main.go via env vars)
var (
	LatencyBaseMS  int     = 200
	SuccessRate    float64 = 0.94
	ServiceVersion string  = "1.0.0"

	StartTime time.Time
)

// FaultConfig holds fault injection state with mutex protection to avoid
// data races between the fault-inject handler and authorize goroutines.
type FaultConfig struct {
	mu          sync.RWMutex
	Enabled     bool
	LatencyMS   int
	SuccessRate float64
}

var Fault = &FaultConfig{SuccessRate: 1.0}

func (f *FaultConfig) Get() (bool, int, float64) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.Enabled, f.LatencyMS, f.SuccessRate
}

func (f *FaultConfig) Set(enabled bool, latencyMS int, successRate float64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Enabled = enabled
	f.LatencyMS = latencyMS
	f.SuccessRate = successRate
}

// BreakerInterface abstracts the circuit breaker for testability.
type BreakerInterface interface {
	Execute(func() (interface{}, error)) (interface{}, error)
	State() string
	StateValue() float64
}

// CircuitBreaker is set from main.go before handlers are invoked.
var CircuitBreaker BreakerInterface

// Request counters for computing real success rate and P95.
var (
	totalRequests   atomic.Int64
	approvedRequests atomic.Int64
)

// ObservedSuccessRate returns the real success rate from counters.
func ObservedSuccessRate() float64 {
	total := totalRequests.Load()
	if total == 0 {
		return 1.0
	}
	return float64(approvedRequests.Load()) / float64(total)
}

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

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB limit
	var req authorizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	txnID := fmt.Sprintf("txn-%d-%04d", time.Now().UnixNano(), rand.Intn(10000))

	start := time.Now()

	faultEnabled, faultLatency, faultRate := Fault.Get()

	result, cbErr := CircuitBreaker.Execute(func() (interface{}, error) {
		latency := LatencyBaseMS
		if faultEnabled && faultLatency > 0 {
			latency = faultLatency
		}
		jitter := rand.Intn(101) - 50
		sleepMS := latency + jitter
		if sleepMS < 0 {
			sleepMS = 0
		}
		time.Sleep(time.Duration(sleepMS) * time.Millisecond)

		rate := SuccessRate
		if faultEnabled {
			rate = faultRate
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

	// Update atomic counters for real success rate
	totalRequests.Add(1)
	if status == "approved" {
		approvedRequests.Add(1)
	}

	// Update Prometheus success rate gauge with observed value
	metrics.AuthSuccessRate.Set(ObservedSuccessRate())

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
