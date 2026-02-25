package circuit

import (
	"log"
	"time"

	"github.com/paintoxic/paystream-auth-service/metrics"
	"github.com/sony/gobreaker"
)

type Breaker struct {
	cb *gobreaker.CircuitBreaker
}

func NewBreaker() *Breaker {
	settings := gobreaker.Settings{
		Name:        "bank-api",
		MaxRequests: 3,
		Interval:    60 * time.Second,
		Timeout:     30 * time.Second,

		ReadyToTrip: func(counts gobreaker.Counts) bool {
			return counts.ConsecutiveFailures >= 5
		},

		OnStateChange: func(name string, from gobreaker.State, to gobreaker.State) {
			log.Printf("circuit-breaker %q: %s -> %s", name, from.String(), to.String())
			metrics.CircuitBreakerState.Set(stateToFloat64(to))
			if to == gobreaker.StateOpen {
				metrics.CircuitBreakerTripsTotal.Inc()
			}
		},
	}

	return &Breaker{
		cb: gobreaker.NewCircuitBreaker(settings),
	}
}

func (b *Breaker) Execute(fn func() (interface{}, error)) (interface{}, error) {
	return b.cb.Execute(fn)
}

func (b *Breaker) State() string {
	return b.cb.State().String()
}

func (b *Breaker) StateValue() float64 {
	return stateToFloat64(b.cb.State())
}

func stateToFloat64(s gobreaker.State) float64 {
	switch s {
	case gobreaker.StateClosed:
		return 0
	case gobreaker.StateHalfOpen:
		return 1
	case gobreaker.StateOpen:
		return 2
	default:
		return -1
	}
}
