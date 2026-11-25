package server_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/testvec"
)

// enrollNew enrolls a vector device as a new user and returns its access token.
func (e *env) enrollNew(name string, ttl time.Duration) string {
	e.t.Helper()
	d := e.device(name)
	e.adv(time.Minute)
	seed := make([]byte, 32)
	_, _ = rand.Read(seed)
	e.addInvite(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey), nil, d.AdminLabel, ttl)
	e.queueIDs(e.randUUIDString(), d.DeviceID)
	if st, o := e.call("POST", "/v1/enroll", "", e.enrollReq(seed, d)); st != 200 {
		e.t.Fatalf("enroll %s: %d %v", name, st, o)
	}
	return e.login(name)
}

func (e *env) randUUIDString() string { return proto.FormatUUID(e.randUUID()) }

func TestWebSocketAuthRules(t *testing.T) {
	e := newEnv(t)
	tok := e.enrollNew("A", time.Hour)

	// bad token -> 4001
	e.wsAuth(proto.B64Encode(make([]byte, 32)), nil).expectClose(4001)
	// first frame not auth -> 4000
	w := e.dial()
	w.write(map[string]any{"type": "ping", "ts": 1})
	w.expectClose(4000)
	// binary frame -> 4000
	w = e.dial()
	_ = w.c.Write(context.Background(), websocket.MessageBinary, []byte{1})
	w.expectClose(4000)
	// scope with unknown conversation -> 4000
	e.wsAuth(tok, []string{"00000000-0000-4000-8000-000000000000"}).expectClose(4000)
	// empty scope list is invalid
	e.wsAuth(tok, []string{}).expectClose(4000)

	// at most 4 connections per device: the 5th closes the oldest with 4009
	var conns []*wsc
	for i := 0; i < 4; i++ {
		c := e.wsAuth(tok, nil)
		c.expect("ready")
		conns = append(conns, c)
	}
	e.wsAuth(tok, nil).expect("ready")
	conns[0].expectClose(4009)
}

func TestTokensAndDeviceState(t *testing.T) {
	e := newEnv(t)
	tok := e.enrollNew("A", 2*time.Hour)

	// at most 5 live tokens per device: oldest is dropped
	toks := []string{tok}
	for i := 0; i < 5; i++ {
		toks = append(toks, e.login("A"))
	}
	if st, _ := e.call("GET", "/v1/directory", toks[0], nil); st != 401 {
		t.Fatalf("oldest token still valid: %d", st)
	}
	if st, _ := e.call("GET", "/v1/directory", toks[5], nil); st != 200 {
		t.Fatal("newest token rejected")
	}
	// token expires after 15 minutes
	e.adv(16 * time.Minute)
	if st, o := e.call("GET", "/v1/directory", toks[5], nil); st != 401 || errCode(o) != "unauthorized" {
		t.Fatalf("expired token: %d %v", st, o)
	}
	// device expiry: login -> device_expired
	tok = e.login("A")
	e.adv(3 * time.Hour)
	if st, o := e.call("GET", "/v1/directory", tok, nil); st != 401 {
		t.Fatalf("token past 15 min: %d %v", st, o)
	}
	if st, o := e.loginRaw(e.device("A")); st != 401 || errCode(o) != "device_expired" {
		t.Fatalf("expired device login: %d %v", st, o)
	}
	// user disabled -> device_revoked with proof
	e.adv(-3 * time.Hour)
	tok = e.login("A")
	if _, err := e.pool.Exec(context.Background(), `UPDATE users SET disabled_at = now()`); err != nil {
		t.Fatal(err)
	}
	if st, o := e.call("GET", "/v1/directory", tok, nil); st != 401 || errCode(o) != "device_revoked" {
		t.Fatalf("disabled user: %d %v", st, o)
	}
	if st, o := e.loginRaw(e.device("A")); st != 401 || o["revoked_sig"] == nil {
		t.Fatalf("disabled user login: %d %v", st, o)
	}
}

func TestRateLimits(t *testing.T) {
	e := newEnv(t)
	e.enrollNew("A", time.Hour)
	// verify: 10 per minute per (IP, device); challenge: only the 30 per minute per IP
	e.adv(time.Minute)
	req := map[string]any{"device_id": e.device("A").DeviceID, "challenge": proto.B64Encode(make([]byte, 32)),
		"sig": proto.B64Encode(make([]byte, 64))}
	for i := range 10 {
		if st, _ := e.call("POST", "/v1/auth/verify", "", req); st != 401 {
			t.Fatalf("verify %d: %d", i, st)
		}
	}
	if st, _ := e.call("POST", "/v1/auth/verify", "", req); st != 429 {
		t.Fatalf("verify not limited per device: %d", st)
	}
	e.adv(time.Minute)
	for i := range 30 {
		if st, _ := e.call("POST", "/v1/auth/challenge", "", map[string]any{"device_id": e.device("A").DeviceID}); st != 200 {
			t.Fatalf("challenge %d: %d", i, st)
		}
	}
	if st, _ := e.call("POST", "/v1/auth/challenge", "", map[string]any{"device_id": e.device("A").DeviceID}); st != 429 {
		t.Fatalf("challenge not limited per IP: %d", st)
	}
	e.adv(time.Minute)
	if st, _ := e.call("POST", "/v1/auth/challenge", "", map[string]any{"device_id": e.device("A").DeviceID}); st != 200 {
		t.Fatal("limit did not refill")
	}
}

func TestServerInfoAndKey(t *testing.T) {
	e := newEnv(t)
	st, o := e.call("GET", "/v1/server-info", "", nil)
	if st != 200 || o["server_sign_pub"] != b64hex(t, e.ch.Servidor.SignPub) || o["escrow_pub"] != b64hex(t, e.ch.Escrow.KexPub) {
		t.Fatalf("server-info: %d %v", st, o)
	}
	var c testvec.Convite
	testvec.Load(t, "convite", &c)
	if c.ServerB64u != o["server_sign_pub"] || c.EscrowB64u != o["escrow_pub"] {
		t.Fatal("server-info differs from the invite vector keys")
	}
	if st, _ := e.call("GET", "/v1/nope", "", nil); st != 404 {
		t.Fatalf("unknown route: %d", st)
	}
}
