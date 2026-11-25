package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/server"
	"github.com/nettotech/direct/server/internal/store"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
	"rsc.io/qr"
)

const password = "uma senha bem comprida para o teste"

// env is a real directd plus the CLI, both on a private schema of DIRECT_TEST_DB_URL.
type env struct {
	t        *testing.T
	pool     *pgxpool.Pool
	url      string   // directd base URL
	password string   // what the CLI "types"
	answers  []string // answers to confirmations, in order; empty = "sim"
	prompts  []string // what the CLI printed before each confirmation
}

func newEnv(t *testing.T) *env {
	t.Helper()
	dbURL := os.Getenv("DIRECT_TEST_DB_URL")
	if dbURL == "" {
		t.Skip("DIRECT_TEST_DB_URL not set; start Postgres (see server/README.md)")
	}
	ctx, cancel := context.WithCancel(context.Background())
	admin, err := pgxpool.New(ctx, dbURL)
	must(t, err)
	var b [6]byte
	_, _ = rand.Read(b[:])
	schema := "cli_" + strings.ToLower(strings.NewReplacer("-", "x", "_", "y").Replace(proto.B64Encode(b[:])))
	_, err = admin.Exec(ctx, "CREATE SCHEMA "+schema)
	must(t, err)
	cfg, err := pgxpool.ParseConfig(dbURL)
	must(t, err)
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := store.Open(ctx, cfg)
	must(t, err)
	must(t, store.Migrate(ctx, pool))
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	srv, err := server.New(ctx, server.Config{Pool: pool, SignKey: key, Log: slog.New(slog.NewTextHandler(io.Discard, nil))})
	must(t, err)
	srv.Run(ctx)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() {
		srv.CloseAll()
		ts.Close()
		cancel()
		pool.Close()
		_, _ = admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
		admin.Close()
	})
	return &env{t: t, pool: pool, url: ts.URL, password: password}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func (e *env) cli(args ...string) (string, error) {
	var out bytes.Buffer
	a := &app{pool: e.pool, out: &out, now: time.Now, host: "direct.exemplo.com.br",
		password: func(string) ([]byte, error) { return []byte(e.password), nil },
		ask: func(string) (string, error) {
			e.prompts = append(e.prompts, out.String())
			if len(e.answers) == 0 {
				return "sim", nil
			}
			a := e.answers[0]
			e.answers = e.answers[1:]
			return a, nil
		}}
	err := a.run(context.Background(), args)
	return out.String(), err
}

func (e *env) mustCLI(args ...string) string {
	e.t.Helper()
	out, err := e.cli(args...)
	if err != nil {
		e.t.Fatalf("%v: %v\n%s", args, err, out)
	}
	return out
}

func (e *env) raw(method, path, token, contentType string, body []byte) (int, []byte) {
	e.t.Helper()
	req, _ := http.NewRequest(method, e.url+path, bytes.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", contentType)
	resp, err := http.DefaultClient.Do(req)
	must(e.t, err)
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func (e *env) call(method, path, token string, body any) (int, map[string]any) {
	e.t.Helper()
	var b []byte
	if body != nil {
		b, _ = json.Marshal(body)
	}
	st, raw := e.raw(method, path, token, "application/json", b)
	var out map[string]any
	if len(raw) > 0 {
		must(e.t, json.Unmarshal(raw, &out))
	}
	return st, out
}

// phone is what the app holds after reading the QR and enrolling.
type phone struct {
	id, user, token   string
	sign              ed25519.PrivateKey
	kexPub, kexSK     [32]byte
	serverPub, escrow []byte
}

var inviteRE = regexp.MustCompile(`direct://enroll\?\S+`)

// enroll creates an invite with the CLI and enrolls using only what the QR text carries.
func (e *env) enroll(model string, args ...string) *phone {
	e.t.Helper()
	out := e.mustCLI(append([]string{"token", "create"}, args...)...)
	if !strings.Contains(out, "▀") || !strings.Contains(out, "código:") {
		e.t.Fatalf("no QR or code in output:\n%s", out)
	}
	u, err := url.Parse(inviteRE.FindString(out))
	must(e.t, err)
	q := u.Query()
	dec := func(k string) []byte {
		b, err := proto.B64Fixed(q.Get(k), 32)
		must(e.t, err)
		return b
	}
	p := &phone{serverPub: dec("s"), escrow: dec("e")}
	invite := ed25519.NewKeyFromSeed(dec("t"))
	invitePub := invite.Public().(ed25519.PublicKey)
	signPub, sign, _ := ed25519.GenerateKey(rand.Reader)
	kexPub, kexSK, _ := box.GenerateKey(rand.Reader)
	p.sign, p.kexPub, p.kexSK = sign, *kexPub, *kexSK
	eb := proto.EnrollBytes(invitePub, signPub, kexPub[:])
	st, res := e.call("POST", "/v1/enroll", "", map[string]any{
		"invite_pub": proto.B64Encode(invitePub), "sign_pub": proto.B64Encode(signPub), "kex_pub": proto.B64Encode(kexPub[:]),
		"platform": "android", "model": model, "os_version": "15", "app_version": "1.0.0",
		"invite_sig": proto.B64Encode(ed25519.Sign(invite, eb)), "proof": proto.B64Encode(ed25519.Sign(sign, eb)),
	})
	if st != 200 {
		e.t.Fatalf("enroll: %d %v", st, res)
	}
	cert := res["cert"].(map[string]any)
	p.id, p.user = cert["device_id"].(string), cert["user_id"].(string)
	st, res = e.login(p)
	if st != 200 {
		e.t.Fatalf("login: %d %v", st, res)
	}
	p.token = res["access_token"].(string)
	return p
}

func (e *env) login(p *phone) (int, map[string]any) {
	e.t.Helper()
	st, ch := e.call("POST", "/v1/auth/challenge", "", map[string]any{"device_id": p.id})
	if st != 200 {
		e.t.Fatalf("challenge: %d %v", st, ch)
	}
	chal, _ := proto.B64Decode(ch["challenge"].(string))
	sig := ed25519.Sign(p.sign, proto.AuthBytes(p.serverPub, id(e.t, p.id), chal))
	return e.call("POST", "/v1/auth/verify", "", map[string]any{"device_id": p.id, "challenge": ch["challenge"], "sig": proto.B64Encode(sig)})
}

func id(t *testing.T, s string) proto.UUID {
	t.Helper()
	u, err := proto.ParseUUID(s)
	must(t, err)
	return u
}

func random(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

// createEpoch does what the sending app does (protocolo 9).
func (e *env) createEpoch(conv string, creator *phone, members ...*phone) []byte {
	e.t.Helper()
	return e.createEpochN(conv, 1, creator, members...)
}

func (e *env) createEpochN(conv string, n uint32, creator *phone, members ...*phone) []byte {
	e.t.Helper()
	k := random(32)
	commit := proto.EpochKeyCommitment(id(e.t, conv), n, k)
	seal := func(pub *[32]byte) string {
		w, err := box.SealAnonymous(nil, k, pub, rand.Reader)
		must(e.t, err)
		return proto.B64Encode(w)
	}
	var ids []proto.UUID
	var recipients []string
	var wraps []map[string]string
	slices.SortFunc(members, func(a, b *phone) int { return strings.Compare(a.id, b.id) })
	for _, m := range members {
		ids = append(ids, id(e.t, m.id))
		recipients = append(recipients, m.id)
		wraps = append(wraps, map[string]string{"device_id": m.id, "wrapped_key": seal(&m.kexPub)})
	}
	var esc [32]byte
	copy(esc[:], creator.escrow)
	sig := ed25519.Sign(creator.sign, proto.EpochBytes(id(e.t, conv), n, id(e.t, creator.id), commit[:], creator.escrow, ids))
	st, res := e.call("POST", "/v1/conversations/"+conv+"/epochs", creator.token, map[string]any{
		"epoch": n, "creator_device_id": creator.id, "key_commitment": proto.B64Encode(commit[:]),
		"recipients": recipients, "wraps": wraps, "escrow_wrap": seal(&esc), "signature": proto.B64Encode(sig)})
	if st != 201 {
		e.t.Fatalf("epoch: %d %v", st, res)
	}
	return k
}

// send encrypts a message as in protocolo 10 and delivers it over the WebSocket.
func (e *env) send(conv string, k []byte, p *phone, plain string) {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(e.url, "http")+"/v1/ws", nil)
	must(e.t, err)
	defer c.CloseNow()
	write := func(v any) {
		b, _ := json.Marshal(v)
		must(e.t, c.Write(ctx, websocket.MessageText, b))
	}
	write(map[string]any{"type": "auth", "access_token": p.token})

	padded := append([]byte(plain), 0x80)
	padded = append(padded, make([]byte, (256-len(padded)%256)%256)...)
	mid := random(16)
	sentAt := uint64(time.Now().UnixMilli())
	header := proto.MsgHeader(id(e.t, conv), 1, id(e.t, p.id), proto.UUID(mid), sentAt)
	aead, err := chacha20poly1305.NewX(k)
	must(e.t, err)
	nonce := random(24)
	ct := aead.Seal(nil, nonce, padded, proto.MsgAAD(header))
	write(map[string]any{"type": "send", "req_id": "r", "message": map[string]any{
		"conversation_id": conv, "epoch": 1, "sender_device_id": p.id, "message_id": proto.FormatUUID(proto.UUID(mid)),
		"sent_at": sentAt, "nonce": proto.B64Encode(nonce), "ciphertext": proto.B64Encode(ct),
		"signature": proto.B64Encode(ed25519.Sign(p.sign, proto.MsgSigBytes(header, nonce, ct)))}})
	for {
		_, b, err := c.Read(ctx)
		must(e.t, err)
		var f map[string]any
		must(e.t, json.Unmarshal(b, &f))
		switch f["type"] {
		case "ack":
			return
		case "error":
			e.t.Fatalf("send: %v", f)
		}
	}
}

// history reads the conversation as a device: epoch key from epochs/mine, then decrypts every message.
func (e *env) history(conv string, p *phone) (texts []string, key []byte) {
	e.t.Helper()
	st, mine := e.call("GET", "/v1/epochs/mine?after=0", p.token, nil)
	if st != 200 {
		e.t.Fatalf("epochs/mine: %d %v", st, mine)
	}
	for _, raw := range mine["items"].([]any) {
		it := raw.(map[string]any)
		w, _ := proto.B64Decode(it["wrapped_key"].(string))
		k, ok := box.OpenAnonymous(nil, w, &p.kexPub, &p.kexSK)
		commit := proto.EpochKeyCommitment(id(e.t, conv), 1, k)
		if !ok || proto.B64Encode(commit[:]) != it["key_commitment"] {
			e.t.Fatal("wrap does not open or commitment differs")
		}
		key = k
	}
	if key == nil {
		return nil, nil
	}
	aead, err := chacha20poly1305.NewX(key)
	must(e.t, err)
	st, h := e.call("GET", "/v1/conversations/"+conv+"/messages?after=0", p.token, nil)
	if st != 200 {
		e.t.Fatalf("history: %d %v", st, h)
	}
	for _, raw := range h["messages"].([]any) {
		m := raw.(map[string]any)
		nonce, _ := proto.B64Decode(m["nonce"].(string))
		ct, _ := proto.B64Decode(m["ciphertext"].(string))
		header := proto.MsgHeader(id(e.t, conv), 1, id(e.t, m["sender_device_id"].(string)),
			id(e.t, m["message_id"].(string)), uint64(m["sent_at"].(float64)))
		plain, err := aead.Open(nil, nonce, ct, proto.MsgAAD(header))
		must(e.t, err)
		texts = append(texts, string(plain[:bytes.LastIndexByte(plain, 0x80)]))
	}
	return texts, key
}

// moderator init runs without a database and writes the key file of protocolo-grupos 3.1.
func TestModeratorInitOffline(t *testing.T) {
	var out bytes.Buffer
	pw := "curta"
	a := &app{out: &out, now: time.Now, password: func(string) ([]byte, error) { return []byte(pw), nil }}
	keyFile := filepath.Join(t.TempDir(), "moderador.key")
	run := func() error { return a.run(context.Background(), []string{"moderator", "init", "--out", keyFile}) }
	if err := run(); err == nil {
		t.Fatal("short password accepted")
	}
	pw = password
	must(t, run())
	file, err := os.ReadFile(keyFile)
	must(t, err)
	info, err := os.Stat(keyFile)
	must(t, err)
	if len(file) != proto.EscrowFileLen || string(file[:16]) != "direct-modkey-v1" || info.Mode().Perm() != 0o600 {
		t.Fatalf("key file: %d bytes, mode %v", len(file), info.Mode())
	}
	if _, err := proto.OpenEscrow(file, []byte(password)); err == nil {
		t.Fatal("moderator key opened as escrow key")
	}
	seed, err := proto.OpenModKey(file, []byte(password))
	must(t, err)
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	if !strings.Contains(out.String(), "mod_sign_pub: "+proto.B64Encode(pub)+"\n") {
		t.Fatalf("public key not printed:\n%s", out.String())
	}
	if err := run(); err == nil {
		t.Fatal("existing file overwritten")
	}
	if again, err := os.ReadFile(keyFile); err != nil || !bytes.Equal(again, file) {
		t.Fatalf("key file changed: %v", err)
	}
}

func TestModeratorFlows(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	keyFile := filepath.Join(t.TempDir(), "escrow.key")

	// ---- escrow init ----
	if _, err := e.cli("token", "create", "--new-user", "Cedo"); err == nil {
		t.Fatal("token create without escrow key accepted")
	}
	e.password = "curta"
	if _, err := e.cli("escrow", "init", "--out", keyFile); err == nil {
		t.Fatal("short password accepted")
	}
	e.password = password
	must(t, os.WriteFile(keyFile, []byte("x"), 0o600))
	if _, err := e.cli("escrow", "init", "--out", keyFile); err == nil {
		t.Fatal("existing file overwritten")
	}
	if k, err := store.GetKeys(ctx, e.pool); err != nil || k.EscrowPub != nil {
		t.Fatalf("public key registered without a key file: %v", err)
	}
	must(t, os.Remove(keyFile))
	e.mustCLI("escrow", "init", "--out", keyFile)
	file, err := os.ReadFile(keyFile)
	must(t, err)
	info, err := os.Stat(keyFile)
	must(t, err)
	sk, err := proto.OpenEscrow(file, []byte(password))
	must(t, err)
	pub, _ := curve25519.X25519(sk, curve25519.Basepoint)
	keys, err := store.GetKeys(ctx, e.pool)
	must(t, err)
	if info.Mode().Perm() != 0o600 || !bytes.Equal(pub, keys.EscrowPub) {
		t.Fatalf("key file mode %v or public key mismatch", info.Mode())
	}
	var dump string
	must(t, e.pool.QueryRow(ctx, `SELECT server_keys::text FROM server_keys`).Scan(&dump))
	if strings.Contains(dump, strings.ToLower(hexString(sk))) {
		t.Fatal("escrow secret key in the database")
	}
	if _, err := e.cli("escrow", "init", "--out", keyFile+"2"); err == nil {
		t.Fatal("second escrow init accepted")
	}

	// With the database at hand, "moderator init" also prints the code of protocolo-grupos 3.3.
	modOut := e.mustCLI("moderator", "init", "--out", keyFile+".mod")
	modFile, err := os.ReadFile(keyFile + ".mod")
	must(t, err)
	seed, err := proto.OpenModKey(modFile, []byte(password))
	must(t, err)
	modCode := proto.ServerCodeMod(keys.ServerSignPub, keys.EscrowPub, ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey))
	if !strings.Contains(modOut, "Código de verificação: "+modCode) {
		t.Fatalf("moderator code:\n%s", modOut)
	}

	// ---- two users, a conversation with a text and a photo ----
	ana := e.enroll("Pixel\x1b[2J", "--new-user", "Ana - Compras")
	bia := e.enroll("Pixel 8", "--new-user", "Bia - Financeiro", "--ttl", "1h", "--device-ttl", "30d")
	var ttlDays float64
	must(t, e.pool.QueryRow(ctx, `SELECT extract(epoch FROM expires_at - enrolled_at)/86400 FROM devices WHERE id = $1`, id(t, bia.id)).Scan(&ttlDays))
	if ttlDays < 29.9 || ttlDays > 30.1 {
		t.Fatalf("device ttl: %v days", ttlDays)
	}
	st, conv := e.call("POST", "/v1/conversations", ana.token, map[string]any{"kind": "direct", "peer_user_id": bia.user})
	if st != 200 {
		t.Fatalf("conversation: %d %v", st, conv)
	}
	convID := conv["conversation_id"].(string)
	k := e.createEpoch(convID, ana, ana, bia)
	e.send(convID, k, ana, `{"type":"text","text":"Olá, Bia!"}`)

	photo := random(5000)
	blobKey, nonce := random(32), random(24)
	aead, err := chacha20poly1305.NewX(blobKey)
	must(t, err)
	cid := id(t, convID)
	aad := append([]byte("direct/v1/blob\x00"), cid[:]...)
	blob := aead.Seal(bytes.Clone(nonce), nonce, photo, aad)
	st, raw := e.raw("POST", "/v1/blobs?conversation_id="+convID, ana.token, "application/octet-stream", blob)
	var up map[string]any
	must(t, json.Unmarshal(raw, &up))
	if st != 201 {
		t.Fatalf("upload: %d %s", st, raw)
	}
	sum := sha256.Sum256(blob)
	img, _ := json.Marshal(map[string]any{"type": "image", "blob_id": up["blob_id"], "key": proto.B64Encode(blobKey), "sha256": proto.B64Encode(sum[:])})
	e.send(convID, k, ana, string(img))

	st, save := e.call("POST", "/v1/media/saves", bia.token, map[string]any{"conversation_id": convID, "seq": 2})
	if st != 201 {
		t.Fatalf("save: %d %v", st, save)
	}
	saveID := save["save_id"].(string)

	// ---- lost phone: list, revoke, 401 ----
	out := e.mustCLI("device", "list", "--user", bia.user)
	for _, want := range []string{bia.id, "Pixel 8", "android", "ÚLTIMO ACESSO", time.Now().UTC().Format("2006-01-02")} {
		if !strings.Contains(out, want) {
			t.Fatalf("device list misses %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, ana.id) {
		t.Fatalf("--user filter ignored:\n%s", out)
	}
	if out := e.mustCLI("device", "list"); strings.Contains(out, "\x1b") || !strings.Contains(out, "Pixel?[2J") {
		t.Fatalf("terminal escape from the device model not neutralized: %q", out)
	}
	wsCtx, wsCancel := context.WithTimeout(ctx, 5*time.Second)
	defer wsCancel()
	live, _, err := websocket.Dial(wsCtx, "ws"+strings.TrimPrefix(e.url, "http")+"/v1/ws", nil)
	must(t, err)
	defer live.CloseNow()
	frame, _ := json.Marshal(map[string]any{"type": "auth", "access_token": bia.token})
	must(t, live.Write(wsCtx, websocket.MessageText, frame))
	_, _, err = live.Read(wsCtx) // ready
	must(t, err)

	e.mustCLI("device", "revoke", bia.id)

	for {
		if _, _, err := live.Read(wsCtx); err != nil {
			if websocket.CloseStatus(err) != 4003 {
				t.Fatalf("revoked socket: %v", err)
			}
			break
		}
	}
	for _, path := range []string{"/v1/directory", "/v1/epochs/mine?after=0", "/v1/conversations/" + convID + "/messages?after=0"} {
		if st, res := e.call("GET", path, bia.token, nil); st != 401 {
			t.Fatalf("revoked device on %s: %d %v", path, st, res)
		}
	}
	st, res := e.login(bia)
	if st != 401 || res["error"].(map[string]any)["code"] != "device_revoked" || res["revoked_sig"] == nil {
		t.Fatalf("revoked login: %d %v", st, res)
	}
	if _, err := e.cli("escrow", "rewrap", "--device", bia.id, "--key", keyFile); err == nil {
		t.Fatal("rewrap to a revoked device accepted")
	}

	// ---- new phone for the same user, then rewrap ----
	bia2 := e.enroll("Pixel 9", "--user", bia.user)
	if bia2.user != bia.user || bia2.id == bia.id {
		t.Fatalf("token --user made %s/%s", bia2.user, bia2.id)
	}
	if texts, _ := e.history(convID, bia2); texts != nil {
		t.Fatal("new device had keys before rewrap")
	}
	e.password = "senha errada, mas comprida"
	if _, err := e.cli("escrow", "rewrap", "--device", bia2.id, "--key", keyFile); !errors.Is(err, proto.ErrEscrowOpen) {
		t.Fatalf("wrong password: %v", err)
	}
	e.password = password

	// A statement that does not match is reported and skipped, not wrapped.
	_, err = e.pool.Exec(ctx, `UPDATE epochs SET signature = set_byte(signature, 0, get_byte(signature, 0) # 1)`)
	must(t, err)
	if out := e.mustCLI("escrow", "rewrap", "--device", bia2.id, "--key", keyFile); !strings.Contains(out, "reembrulhadas: 0") || !strings.Contains(out, "assinatura do criador") {
		t.Fatalf("tampered epoch:\n%s", out)
	}
	_, err = e.pool.Exec(ctx, `UPDATE epochs SET signature = set_byte(signature, 0, get_byte(signature, 0) # 1)`)
	must(t, err)

	// ---- confirmations: device fingerprint, then the list of conversations (S1) ----
	wraps := func() (n int) {
		must(t, e.pool.QueryRow(ctx, `SELECT count(*) FROM epoch_key_wraps WHERE recipient_device_id = $1`, id(t, bia2.id)).Scan(&n))
		return n
	}
	code := proto.DeviceCode(bia2.sign.Public().(ed25519.PublicKey), bia2.kexPub[:])
	for _, answers := range [][]string{{"não"}, {"sim", ""}} {
		e.answers, e.prompts = answers, nil
		if _, err := e.cli("escrow", "rewrap", "--device", bia2.id, "--key", keyFile); err == nil || wraps() != 0 {
			t.Fatalf("rewrap with answers %q: %v, %d wraps", answers, err, wraps())
		}
		if len(e.prompts) != len(answers) || !strings.Contains(e.prompts[0], code) {
			t.Fatalf("device code %s not shown before confirming:\n%v", code, e.prompts)
		}
		if len(answers) == 2 && (!strings.Contains(e.prompts[1], convID) || !strings.Contains(e.prompts[1], "Ana - Compras")) {
			t.Fatalf("conversations not listed before confirming:\n%s", e.prompts[1])
		}
	}

	// A conversation the database says the user belongs to, but whose signed recipients never
	// included them, is not rewrapped (an intruder adding a membership row).
	caioPhone := e.enroll("Pixel", "--new-user", "Caio - TI")
	st, other := e.call("POST", "/v1/conversations", ana.token, map[string]any{"kind": "direct", "peer_user_id": caioPhone.user})
	if st != 200 {
		t.Fatalf("conversation: %d %v", st, other)
	}
	otherID := other["conversation_id"].(string)
	e.createEpoch(otherID, ana, ana, caioPhone)
	_, err = e.pool.Exec(ctx, `INSERT INTO conversation_members (conversation_id, user_id, joined_at) VALUES ($1,$2,now())`,
		id(t, otherID), id(t, bia.user))
	must(t, err)

	if out := e.mustCLI("escrow", "rewrap", "--device", bia2.id, "--key", keyFile); !strings.Contains(out, "reembrulhadas: 1") || !strings.Contains(out, "Com falha: 0") || !strings.Contains(out, "inclua o usuário): 1") || strings.Contains(out, otherID) {
		t.Fatalf("rewrap:\n%s", out)
	}
	var foreign int
	must(t, e.pool.QueryRow(ctx, `SELECT count(*) FROM epoch_key_wraps WHERE recipient_device_id = $1 AND conversation_id = $2`,
		id(t, bia2.id), id(t, otherID)).Scan(&foreign))
	if foreign != 0 {
		t.Fatal("epoch of a foreign conversation rewrapped")
	}
	_, err = e.pool.Exec(ctx, `DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`, id(t, otherID), id(t, bia.user))
	must(t, err)
	if out := e.mustCLI("escrow", "rewrap", "--device", bia2.id, "--key", keyFile); !strings.Contains(out, "reembrulhadas: 0") || !strings.Contains(out, "já tinha): 1") {
		t.Fatalf("second rewrap:\n%s", out)
	}
	texts, got := e.history(convID, bia2)
	if !bytes.Equal(got, k) || len(texts) != 2 || !strings.Contains(texts[0], "Olá, Bia!") {
		t.Fatalf("history on the new device: %v", texts)
	}
	var ref struct {
		BlobID string `json:"blob_id"`
		Key    string `json:"key"`
	}
	must(t, json.Unmarshal([]byte(texts[1]), &ref))
	st, down := e.raw("GET", "/v1/blobs/"+ref.BlobID, bia2.token, "", nil)
	if st != 200 {
		t.Fatalf("blob: %d", st)
	}
	rk, _ := proto.B64Decode(ref.Key)
	open, err := chacha20poly1305.NewX(rk)
	must(t, err)
	if plain, err := open.Open(nil, down[:24], down[24:], aad); err != nil || !bytes.Equal(plain, photo) {
		t.Fatalf("photo on the new device: %v", err)
	}

	// ---- orphan uploads ----
	st, raw = e.raw("POST", "/v1/blobs?conversation_id="+convID, bia2.token, "application/octet-stream", random(64))
	if st != 201 {
		t.Fatalf("orphan upload: %d %s", st, raw)
	}
	if out := e.mustCLI("media", "prune", "--older", "24h"); !strings.Contains(out, "apagados: 0 ") {
		t.Fatalf("fresh upload pruned:\n%s", out)
	}
	// everything two days old: the photo was followed by its message, the other upload by none
	_, err = e.pool.Exec(ctx, `UPDATE blobs SET created_at = created_at - interval '2 days'`)
	must(t, err)
	_, err = e.pool.Exec(ctx, `UPDATE messages SET created_at = created_at - interval '2 days'`)
	must(t, err)
	if out := e.mustCLI("media", "prune", "--older", "24h"); !strings.Contains(out, "apagados: 1 (64 bytes)") {
		t.Fatalf("prune:\n%s", out)
	}
	if st, _ := e.raw("GET", "/v1/blobs/"+ref.BlobID, bia2.token, "", nil); st != 200 {
		t.Fatalf("photo in use pruned: %d", st)
	}
	if _, err := e.cli("media", "prune", "--older", "1h"); err == nil {
		t.Fatal("prune below 24h accepted")
	}
	if _, err := e.cli("token", "create", "--new-user", "x", "--ttl", "8d"); err == nil {
		t.Fatal("invite valid for more than 7 days")
	}

	// ---- saved photos ----
	for _, out := range []string{e.mustCLI("media", "saves"), e.mustCLI("media", "saves", "--user", bia.user)} {
		if !strings.Contains(out, saveID) || !strings.Contains(out, "Bia - Financeiro") {
			t.Fatalf("media saves:\n%s", out)
		}
	}
	if out := e.mustCLI("media", "saves", "--user", ana.user); strings.Contains(out, saveID) {
		t.Fatalf("media saves of another user:\n%s", out)
	}
	out = e.mustCLI("media", "lookup", saveID)
	for _, want := range []string{saveID, "Bia - Financeiro", bia.id, "Pixel 8", convID, "seq 2", "Ana - Compras", ana.id} {
		if !strings.Contains(out, want) {
			t.Fatalf("media lookup misses %q:\n%s", want, out)
		}
	}
	if _, err := e.cli("media", "lookup", "00000000-0000-4000-8000-000000000000"); err == nil {
		t.Fatal("unknown save_id accepted")
	}

	// ---- pending invites, users, disable ----
	e.mustCLI("token", "create", "--user", ana.user)
	e.mustCLI("token", "create", "--new-user", "Davi")
	toks, err := store.ListTokens(ctx, e.pool)
	must(t, err)
	var caio, used string
	for _, tk := range toks {
		if tk.AdminLabel == "Davi" {
			caio = proto.FormatUUID(tk.ID)
		}
		if tk.UsedAt != nil {
			used = proto.FormatUUID(tk.ID)
		}
	}
	if out := e.mustCLI("token", "list"); !strings.Contains(out, "pendente") || !strings.Contains(out, "usado") || !strings.Contains(out, caio) {
		t.Fatalf("token list:\n%s", out)
	}
	e.mustCLI("token", "revoke", caio)
	if _, err := e.cli("token", "revoke", caio); err == nil {
		t.Fatal("revoked token revoked twice")
	}
	if _, err := e.cli("token", "revoke", used); err == nil {
		t.Fatal("used token revoked")
	}
	if out := e.mustCLI("user", "list"); !strings.Contains(out, "Ana - Compras") || !strings.Contains(out, "Bia - Financeiro") {
		t.Fatalf("user list:\n%s", out)
	}
	if out := e.mustCLI("user", "show", bia.user); !strings.Contains(out, "Aparelhos ativos: 1") || !strings.Contains(out, "revogado") || !strings.Contains(out, bia2.id) {
		t.Fatalf("user show:\n%s", out)
	}
	e.mustCLI("user", "disable", ana.user)
	if st, _ := e.call("GET", "/v1/directory", ana.token, nil); st != 401 {
		t.Fatalf("disabled user: %d", st)
	}
	if _, res := e.login(ana); res["error"].(map[string]any)["code"] != "device_revoked" {
		t.Fatalf("disabled login: %v", res)
	}
	if _, err := e.cli("token", "create", "--user", ana.user); err == nil {
		t.Fatal("invite for a disabled user")
	}
	toks, err = store.ListTokens(ctx, e.pool)
	must(t, err)
	for _, tk := range toks {
		if tk.UsedAt == nil && tk.RevokedAt == nil {
			t.Fatalf("pending invite of a disabled user survived: %s", tk.AdminLabel)
		}
	}
}

// Messages sent while the user had no active device are in epochs that do not list them; they
// come back because another epoch of the same direct conversation, signed by its creator, does.
func TestRewrapRecoversEpochsFromWhileWithoutDevice(t *testing.T) {
	e := newEnv(t)
	keyFile := filepath.Join(t.TempDir(), "escrow.key")
	e.mustCLI("escrow", "init", "--out", keyFile)
	ana := e.enroll("Pixel 7", "--new-user", "Ana - Compras")
	bia := e.enroll("Pixel 8", "--new-user", "Bia - Financeiro")
	st, conv := e.call("POST", "/v1/conversations", ana.token, map[string]any{"kind": "direct", "peer_user_id": bia.user})
	if st != 200 {
		t.Fatalf("conversation: %d %v", st, conv)
	}
	convID := conv["conversation_id"].(string)
	e.createEpoch(convID, ana, ana, bia)
	e.mustCLI("device", "revoke", bia.id)
	k2 := e.createEpochN(convID, 2, ana, ana) // Bia has no device at all
	bia2 := e.enroll("Pixel 9", "--user", bia.user)

	out := e.mustCLI("escrow", "rewrap", "--device", bia2.id, "--key", keyFile)
	if !strings.Contains(out, "reembrulhadas: 2") || !strings.Contains(out, "Com falha: 0") {
		t.Fatalf("rewrap:\n%s", out)
	}
	var wrapped []byte
	must(t, e.pool.QueryRow(context.Background(), `SELECT wrapped_key FROM epoch_key_wraps
		WHERE recipient_device_id = $1 AND epoch = 2`, id(t, bia2.id)).Scan(&wrapped))
	if k, ok := box.OpenAnonymous(nil, wrapped, &bia2.kexPub, &bia2.kexSK); !ok || !bytes.Equal(k, k2) {
		t.Fatal("the new device does not get the key of the epoch it missed")
	}
}

func hexString(b []byte) string {
	const digits = "0123456789abcdef"
	var s strings.Builder
	for _, c := range b {
		s.WriteByte(digits[c>>4])
		s.WriteByte(digits[c&15])
	}
	return s.String()
}

func TestArguments(t *testing.T) {
	a := &app{now: time.Now, out: io.Discard, host: "a.example"}
	for _, args := range [][]string{
		nil, {"token"}, {"token", "burn"}, {"token", "create"}, {"token", "create", "--new-user", "x", "--user", "y"},
		{"device", "revoke"}, {"device", "revoke", "a", "b"}, {"user", "list", "x"}, {"escrow", "init"},
		{"escrow", "rewrap", "--device", "x"}, {"media", "lookup"}, {"media", "prune", "x"},
	} {
		if err := a.run(context.Background(), args); !errors.Is(err, errUsage) {
			t.Errorf("%v: %v", args, err)
		}
	}
	for s, want := range map[string]time.Duration{"24h": 24 * time.Hour, "180d": 180 * 24 * time.Hour, "90m": 90 * time.Minute} {
		if d, err := parseDuration(s); err != nil || d != want {
			t.Errorf("%s: %v %v", s, d, err)
		}
	}
	for _, s := range []string{"", "0", "-1h", "0d", "-3d", "1.5d", "999999d", "d"} {
		if _, err := parseDuration(s); err == nil {
			t.Errorf("duration %q accepted", s)
		}
	}
}

func TestAuditLog(t *testing.T) {
	var log bytes.Buffer
	a := &app{now: time.Now}
	err := audited(&log, "maria", a, []string{"device", "revoke", "x\ny"}, func() error {
		if !strings.Contains(log.String(), "start") {
			t.Fatal("not recorded before running")
		}
		return errors.New("falhou")
	})
	if err == nil || strings.Count(log.String(), "\n") != 2 || !strings.Contains(log.String(), `operator="maria"`) || !strings.Contains(log.String(), `error="falhou"`) {
		t.Fatalf("log: %q %v", log.String(), err)
	}
	ran := false
	if err := audited(failWriter{}, "maria", a, nil, func() error { ran = true; return nil }); err == nil || ran {
		t.Fatal("command ran without a log")
	}
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("disk full") }

// The drawing must reproduce the code module by module, with the quiet zone.
func TestRenderQR(t *testing.T) {
	const text = "direct://enroll?v=1&h=direct.exemplo.com.br&t=7sOlGr-R9hKcLOkbnoFSBCC7izpx9DSAIfTKET2geMQ"
	out, err := renderQR(text)
	must(t, err)
	c, err := qr.Encode(text, qr.M)
	must(t, err)
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	halves := map[rune][2]bool{'█': {true, true}, '▀': {true, false}, '▄': {false, true}, ' ': {false, false}}
	for i, line := range lines {
		cells := []rune(strings.TrimSuffix(strings.TrimPrefix(line, "\x1b[40;97m"), "\x1b[0m"))
		if len(cells) != c.Size+2*quiet {
			t.Fatalf("line %d has %d cells", i, len(cells))
		}
		for j, r := range cells {
			for half, light := range halves[r] {
				if light == c.Black(j-quiet, 2*i+half-quiet) {
					t.Fatalf("module %d,%d wrong", j, 2*i+half)
				}
			}
		}
	}
	if 2*len(lines) < c.Size+2*quiet {
		t.Fatal("bottom quiet zone missing")
	}
}
