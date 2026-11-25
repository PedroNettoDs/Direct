package server_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/server"
	"github.com/nettotech/direct/server/internal/store"
	"github.com/nettotech/direct/server/internal/testvec"
)

// env is a directd instance on a private schema of a real PostgreSQL (DIRECT_TEST_DB_URL).
type env struct {
	t    *testing.T
	pool *pgxpool.Pool
	srv  *server.Server
	ts   *httptest.Server
	ch   testvec.Chaves

	mu    sync.Mutex
	clock time.Time
	ids   []proto.UUID
}

func (e *env) now() time.Time { e.mu.Lock(); defer e.mu.Unlock(); return e.clock }
func (e *env) setMs(v int64)  { e.mu.Lock(); e.clock = time.UnixMilli(v); e.mu.Unlock() }
func (e *env) adv(d time.Duration) {
	e.mu.Lock()
	e.clock = e.clock.Add(d)
	e.mu.Unlock()
}
func (e *env) queueIDs(ss ...string) {
	for _, s := range ss {
		u, err := proto.ParseUUID(s)
		if err != nil {
			e.t.Fatal(err)
		}
		e.mu.Lock()
		e.ids = append(e.ids, u)
		e.mu.Unlock()
	}
}
func (e *env) randUUID() proto.UUID {
	var u proto.UUID
	_, _ = rand.Read(u[:])
	u[6], u[8] = u[6]&0x0f|0x40, u[8]&0x3f|0x80
	return u
}

func (e *env) newUUID() proto.UUID {
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.ids) > 0 {
		u := e.ids[0]
		e.ids = e.ids[1:]
		return u
	}
	var u proto.UUID
	_, _ = rand.Read(u[:])
	u[6], u[8] = u[6]&0x0f|0x40, u[8]&0x3f|0x80
	return u
}

func newEnv(t *testing.T, opts ...func(*server.Config)) *env {
	t.Helper()
	url := os.Getenv("DIRECT_TEST_DB_URL")
	if url == "" {
		t.Skip("DIRECT_TEST_DB_URL not set; start Postgres (see server/README.md)")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	var b [6]byte
	_, _ = rand.Read(b[:])
	schema := fmt.Sprintf("t_%x", b)
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	cfg, _ := pgxpool.ParseConfig(url)
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := store.Open(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	e := &env{t: t, pool: pool, clock: time.UnixMilli(1795000000000)}
	testvec.Load(t, "chaves", &e.ch)
	key := ed25519.NewKeyFromSeed(testvec.Hex(t, e.ch.Servidor.SignSeed))
	conf := server.Config{Pool: pool, SignKey: key, Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Now: e.now, NewUUID: e.newUUID}
	for _, o := range opts {
		o(&conf)
	}
	e.srv, err = server.New(ctx, conf)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE server_keys SET escrow_pub = $1`, testvec.Hex(t, e.ch.Escrow.KexPub)); err != nil {
		t.Fatal(err)
	}
	rctx, cancel := context.WithCancel(ctx)
	e.srv.Run(rctx)
	e.ts = httptest.NewServer(e.srv.Handler())
	t.Cleanup(func() {
		e.srv.CloseAll()
		e.ts.Close()
		cancel()
		pool.Close()
		_, _ = admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
		admin.Close()
	})
	return e
}

// call performs an HTTP request and decodes the JSON answer into a generic map.
func (e *env) call(method, path, token string, body any) (int, map[string]any) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.ts.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(resp.Body)
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &out); err != nil {
			e.t.Fatalf("%s %s: bad json %q", method, path, raw)
		}
	}
	return resp.StatusCode, out
}

func errCode(m map[string]any) string {
	if inner, ok := m["error"].(map[string]any); ok {
		s, _ := inner["code"].(string)
		return s
	}
	return ""
}

func (e *env) device(name string) testvec.Device {
	for _, d := range e.ch.Aparelhos {
		if d.Nome == name {
			return d
		}
	}
	e.t.Fatalf("no device %s", name)
	return testvec.Device{}
}

func uid(t *testing.T, s string) proto.UUID {
	u, err := proto.ParseUUID(s)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// login runs challenge/verify with a vector device key; returns the answer of verify.
func (e *env) loginRaw(d testvec.Device) (int, map[string]any) {
	e.t.Helper()
	e.adv(15 * time.Second) // stays under the auth rate limit
	st, ch := e.call("POST", "/v1/auth/challenge", "", map[string]any{"device_id": d.DeviceID})
	if st != 200 {
		e.t.Fatalf("challenge: %d %v", st, ch)
	}
	chal, _ := proto.B64Decode(ch["challenge"].(string))
	srvPub := testvec.Hex(e.t, e.ch.Servidor.SignPub)
	sig := ed25519.Sign(ed25519.NewKeyFromSeed(testvec.Hex(e.t, d.SignSeed)), proto.AuthBytes(srvPub, uid(e.t, d.DeviceID), chal))
	st, out := e.call("POST", "/v1/auth/verify", "", map[string]any{
		"device_id": d.DeviceID, "challenge": ch["challenge"], "sig": proto.B64Encode(sig)})
	if out != nil {
		out["_chal"] = chal
	}
	return st, out
}

func (e *env) login(name string) string {
	e.t.Helper()
	st, out := e.loginRaw(e.device(name))
	if st != 200 {
		e.t.Fatalf("login %s: %d %v", name, st, out)
	}
	return out["access_token"].(string)
}

// wsc is a test WebSocket client.
type wsc struct {
	t *testing.T
	c *websocket.Conn
}

func (e *env) dial() *wsc {
	e.t.Helper()
	c, _, err := websocket.Dial(context.Background(), "ws"+strings.TrimPrefix(e.ts.URL, "http")+"/v1/ws", nil)
	if err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() { c.CloseNow() })
	return &wsc{t: e.t, c: c}
}

func (w *wsc) write(v any) {
	w.t.Helper()
	b, _ := json.Marshal(v)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := w.c.Write(ctx, websocket.MessageText, b); err != nil {
		w.t.Fatal(err)
	}
}

// read returns the next frame, or (nil, close code) when the connection closed.
func (w *wsc) read(d time.Duration) (map[string]any, int) {
	w.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	_, b, err := w.c.Read(ctx)
	if err != nil {
		if code := websocket.CloseStatus(err); code != -1 {
			return nil, int(code)
		}
		return nil, 0 // timeout
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		w.t.Fatalf("bad frame %q", b)
	}
	return m, -1
}

func (w *wsc) expect(typ string) map[string]any {
	w.t.Helper()
	for i := 0; i < 20; i++ { // skips unrelated events (directory_changed, conversation, ...)
		m, code := w.read(5 * time.Second)
		if m == nil {
			w.t.Fatalf("want frame %q, connection ended (close %d)", typ, code)
		}
		if m["type"] == typ {
			return m
		}
	}
	w.t.Fatalf("frame %q never arrived", typ)
	return nil
}

func (w *wsc) expectClose(code int) {
	w.t.Helper()
	for i := 0; i < 5; i++ {
		m, c := w.read(5 * time.Second)
		if m == nil {
			if c != code {
				w.t.Fatalf("want close %d, got %d", code, c)
			}
			return
		}
	}
	w.t.Fatalf("no close %d", code)
}

func (e *env) wsAuth(token string, scope []string) *wsc {
	e.t.Helper()
	w := e.dial()
	fr := map[string]any{"type": "auth", "access_token": token}
	if scope != nil {
		fr["conversations"] = scope
	}
	w.write(fr)
	return w
}
