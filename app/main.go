package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/paintoxic/paystream-auth-service/circuit"
	"github.com/paintoxic/paystream-auth-service/handlers"
	"github.com/paintoxic/paystream-auth-service/metrics"
)

func main() {
	metrics.Init()

	port := envOrDefault("PORT", "8080")
	handlers.ServiceVersion = envOrDefault("SERVICE_VERSION", "1.0.0")
	handlers.StartTime = time.Now()

	if v, err := strconv.Atoi(envOrDefault("LATENCY_BASE_MS", "200")); err == nil {
		handlers.LatencyBaseMS = v
	}
	if v, err := strconv.ParseFloat(envOrDefault("SUCCESS_RATE", "0.94"), 64); err == nil {
		handlers.SuccessRate = v
	}

	cb := circuit.NewBreaker()
	handlers.CircuitBreaker = cb

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/authorize", handlers.AuthorizeHandler)
	mux.HandleFunc("/health", handlers.HealthHandler)
	mux.HandleFunc("/admin/fault-inject", handlers.FaultInjectHandler)
	mux.Handle("/metrics", metrics.Handler())

	log.Printf("paystream-auth-service %s starting on :%s", handlers.ServiceVersion, port)
	if err := http.ListenAndServe(fmt.Sprintf(":%s", port), mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
