package server

import (
	"testing"

	"github.com/nettotech/direct/server/internal/proto"
)

func TestSlots(t *testing.T) {
	s := newSlots(3, 2)
	a, b := proto.UUID{1}, proto.UUID{2}
	if !s.Take(a) || !s.Take(a) || s.Take(a) {
		t.Fatal("per user cap")
	}
	if !s.Take(b) || s.Take(b) {
		t.Fatal("total cap")
	}
	s.Release(a)
	if !s.Take(b) {
		t.Fatal("slot not returned")
	}
}
