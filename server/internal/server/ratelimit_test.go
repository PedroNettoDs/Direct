package server

import (
	"testing"
	"time"
)

func TestLimiterRefill(t *testing.T) {
	now := time.Unix(1000, 0)
	l := newLimiter(1, 3)
	l.now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if !l.Allow("k") {
			t.Fatalf("burst call %d denied", i)
		}
	}
	if l.Allow("k") {
		t.Fatal("4th call allowed")
	}
	if !l.Allow("other") {
		t.Fatal("keys must be independent")
	}
	now = now.Add(2 * time.Second)
	if !l.Allow("k") || !l.Allow("k") || l.Allow("k") {
		t.Fatal("refill of 2 tokens expected")
	}
}
