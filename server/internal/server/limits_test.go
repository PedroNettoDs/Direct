package server_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/server"
	"github.com/nettotech/direct/server/internal/testvec"
)

// pair enrolls A and B, valid for 90 days, and opens their conversation. It returns A's token.
func (e *env) pair() (token, conv string) {
	e.t.Helper()
	token = e.enrollNew("A", 90*24*time.Hour)
	e.enrollNew("B", 90*24*time.Hour)
	st, c := e.call("POST", "/v1/conversations", token, map[string]any{"kind": "direct",
		"peer_user_id": proto.FormatUUID(e.userOf(e.device("B").DeviceID))})
	if st != 200 {
		e.t.Fatalf("conversation: %d %v", st, c)
	}
	return token, c["conversation_id"].(string)
}

// newEpoch posts epoch 1 created by device from, for from and to. The server checks the signature
// and the sizes, not what is inside the wraps.
func (e *env) newEpoch(token, conv, from, to string) (int, map[string]any) {
	e.t.Helper()
	creator := e.device(from)
	ids := []string{creator.DeviceID, e.device(to).DeviceID}
	slices.Sort(ids)
	var recips []proto.UUID
	var wraps []map[string]string
	for _, id := range ids {
		recips = append(recips, uid(e.t, id))
		wraps = append(wraps, map[string]string{"device_id": id, "wrapped_key": proto.B64Encode(make([]byte, 80))})
	}
	commit := make([]byte, 32)
	sig := ed25519.Sign(ed25519.NewKeyFromSeed(testvec.Hex(e.t, creator.SignSeed)),
		proto.EpochBytes(uid(e.t, conv), 1, uid(e.t, creator.DeviceID), commit, testvec.Hex(e.t, e.ch.Escrow.KexPub), recips))
	return e.call("POST", "/v1/conversations/"+conv+"/epochs", token, map[string]any{
		"epoch": 1, "creator_device_id": creator.DeviceID, "key_commitment": proto.B64Encode(commit),
		"recipients": ids, "wraps": wraps, "escrow_wrap": proto.B64Encode(make([]byte, 80)), "signature": proto.B64Encode(sig)})
}

// from performs a POST as if it came from another client IP.
func (e *env) from(ip, path string, body any) (int, map[string]any) {
	e.t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", e.ts.URL+path, bytes.NewReader(b))
	req.Header.Set("X-Test-IP", ip)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// Knowing a device id must not be enough to lock that device out (S3).
func TestAuthLimitNotSharedBetweenClients(t *testing.T) {
	e := newEnv(t, func(c *server.Config) { c.TrustedIPHeader, c.TrustedProxy = "X-Test-IP", "127.0.0.1" })
	e.enrollNew("A", time.Hour)
	victim := e.device("A")
	for range 14 {
		st, ch := e.from("10.6.6.6", "/v1/auth/challenge", map[string]any{"device_id": victim.DeviceID})
		if st != 200 {
			t.Fatalf("challenge: %d %v", st, ch)
		}
		e.from("10.6.6.6", "/v1/auth/verify", map[string]any{"device_id": victim.DeviceID,
			"challenge": ch["challenge"], "sig": proto.B64Encode(make([]byte, 64))})
	}
	// loginRaw advances the clock by 15 s, which alone would refill only 2 of 10 tokens.
	if st, out := e.loginRaw(victim); st != 200 {
		t.Fatalf("victim locked out: %d %v", st, out)
	}
}

func (e *env) upload(token, conv string, n int) (int, map[string]any) {
	e.t.Helper()
	b := make([]byte, n)
	_, _ = rand.Read(b)
	req, _ := http.NewRequest("POST", e.ts.URL+"/v1/blobs?conversation_id="+conv, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(resp.Body)
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

func TestBlobQuotaAndDownloadLimit(t *testing.T) {
	e := newEnv(t, func(c *server.Config) { c.BlobDayQuota = 150 })
	a, id := e.pair()
	st, up := e.upload(a, id, 100)
	if st != 201 {
		t.Fatalf("upload: %d %v", st, up)
	}
	if st, out := e.upload(a, id, 100); st != 429 || errCode(out) != "rate_limited" {
		t.Fatalf("over quota: %d %v", st, out)
	}
	e.adv(25 * time.Hour)
	a = e.login("A")
	if st, out := e.upload(a, id, 100); st != 201 {
		t.Fatalf("next day: %d %v", st, out)
	}

	get := func() int {
		req, _ := http.NewRequestWithContext(context.Background(), "GET", e.ts.URL+"/v1/blobs/"+up["blob_id"].(string), nil)
		req.Header.Set("Authorization", "Bearer "+a)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, resp.Body)
		return resp.StatusCode
	}
	for i := range 120 {
		if st := get(); st != 200 {
			t.Fatalf("download %d: %d", i, st)
		}
	}
	if st := get(); st != 429 {
		t.Fatalf("download beyond the limit: %d", st)
	}
}

func TestProfileLimitAndCoalescing(t *testing.T) {
	e := newEnv(t)
	a, b := e.enrollNew("A", time.Hour), e.enrollNew("B", time.Hour)
	w := e.wsAuth(b, nil)
	w.expect("ready")
	for i := range 6 {
		st, out := e.call("PUT", "/v1/me/profile", a, map[string]any{"display_name": "Ana", "status": ""})
		if i < 5 && st != 204 {
			t.Fatalf("profile %d: %d %v", i, st, out)
		}
		if i == 5 && st != 429 {
			t.Fatalf("sixth profile change: %d", st)
		}
	}
	// one frame at once, one merged frame later, nothing else
	got := 0
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		m, _ := w.read(time.Until(deadline))
		if m == nil {
			break
		}
		if m["type"] == "directory_changed" {
			got++
		}
	}
	if got != 2 {
		t.Fatalf("5 changes produced %d directory_changed frames", got)
	}
}

// A new epoch must not commit while a writer holding a lower wrap_id is still open (S4).
func TestEpochWaitsForOpenWrapWriters(t *testing.T) {
	e := newEnv(t)
	a, conv := e.pair()
	ctx := context.Background()
	other, err := e.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Rollback(ctx)
	// the table lock an uncommitted insert holds
	if _, err := other.Exec(ctx, `LOCK TABLE epoch_key_wraps IN ROW EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	done := make(chan int, 1)
	go func() {
		st, _ := e.newEpoch(a, conv, "A", "B")
		done <- st
	}()
	select {
	case st := <-done:
		t.Fatalf("epoch committed (%d) ahead of an open writer", st)
	case <-time.After(700 * time.Millisecond):
	}
	if err := other.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case st := <-done:
		if st != 201 {
			t.Fatalf("epoch: %d", st)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("epoch never finished")
	}
}
