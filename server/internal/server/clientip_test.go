package server

import (
	"net/http/httptest"
	"testing"
)

// The IP header counts only on connections coming from the trusted proxy (S11).
func TestClientIPTrustsOnlyTheProxy(t *testing.T) {
	for _, c := range []struct{ proxy, remote, want string }{
		{"172.20.0.5", "172.20.0.5:40000", "203.0.113.7"},
		{"localhost", "127.0.0.1:40000", "203.0.113.7"},
		{"172.20.0.5", "172.20.0.9:40000", "172.20.0.9"},
		{"", "172.20.0.5:40000", "172.20.0.5"},
		{"nome.invalid", "172.20.0.5:40000", "172.20.0.5"},
	} {
		r := httptest.NewRequest("POST", "/", nil)
		r.RemoteAddr = c.remote
		r.Header.Set("CF-Connecting-IP", "203.0.113.7")
		s := &Server{ipHdr: "CF-Connecting-IP", proxy: c.proxy}
		if got := s.clientIP(r); got != c.want {
			t.Errorf("proxy %q, peer %s: got %s, want %s", c.proxy, c.remote, got, c.want)
		}
	}
}
