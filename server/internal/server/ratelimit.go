package server

import (
	"sync"
	"time"

	"github.com/nettotech/direct/server/internal/proto"
)

// limiter is a token bucket per key (rate tokens/second, burst capacity).
type limiter struct {
	rate  float64
	burst float64
	now   func() time.Time

	mu    sync.Mutex
	m     map[string]*bucket
	calls int
}

type bucket struct {
	tokens float64
	last   time.Time
}

func newLimiter(rate, burst float64) *limiter {
	return &limiter{rate: rate, burst: burst, now: time.Now, m: map[string]*bucket{}}
}

func (l *limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if l.calls++; l.calls%1024 == 0 {
		for k, b := range l.m {
			if now.Sub(b.last) > 10*time.Minute {
				delete(l.m, k)
			}
		}
	}
	b := l.m[key]
	if b == nil {
		b = &bucket{tokens: l.burst, last: now}
		l.m[key] = b
	}
	if d := now.Sub(b.last).Seconds(); d > 0 {
		b.tokens = min(l.burst, b.tokens+d*l.rate)
		b.last = now
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// slots caps work in flight, in total and per user.
type slots struct {
	max, perUser int

	mu    sync.Mutex
	total int
	m     map[proto.UUID]int
}

func newSlots(max, perUser int) *slots {
	return &slots{max: max, perUser: perUser, m: map[proto.UUID]int{}}
}

// Take reserves a slot for user, to be returned with Release; false if none is free.
func (s *slots) Take(user proto.UUID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.total >= s.max || s.m[user] >= s.perUser {
		return false
	}
	s.total++
	s.m[user]++
	return true
}

func (s *slots) Release(user proto.UUID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.total--
	if s.m[user]--; s.m[user] == 0 {
		delete(s.m, user)
	}
}
