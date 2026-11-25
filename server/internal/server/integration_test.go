package server_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/testvec"
)

func b64hex(t *testing.T, h string) string { return proto.B64Encode(testvec.Hex(t, h)) }

// addInvite inserts an enrollment token as the future CLI would (invite_pub only).
func (e *env) addInvite(pub []byte, userID *string, label string, ttl time.Duration) {
	e.t.Helper()
	var uid any
	if userID != nil {
		uid = uuidArg(e.t, *userID)
	}
	_, err := e.pool.Exec(context.Background(), `INSERT INTO enrollment_tokens (id, invite_pub, user_id, admin_label, expires_at, device_ttl)
		VALUES ($1,$2,$3,$4,$5,$6::interval)`, e.randUUID(), pub, uid, label, e.now().Add(24*time.Hour),
		intervalSecs(ttl))
	if err != nil {
		e.t.Fatal(err)
	}
}

func intervalSecs(d time.Duration) string { return itoa(int64(d/time.Second)) + " seconds" }

func itoa(v int64) string { b, _ := json.Marshal(v); return string(b) }

func uuidArg(t *testing.T, s string) [16]byte { return uid(t, s) }

// enrollReq builds a valid /v1/enroll body with the given invite seed and device vector keys.
func (e *env) enrollReq(inviteSeed []byte, d testvec.Device) map[string]any {
	ik := ed25519.NewKeyFromSeed(inviteSeed)
	ipub := ik.Public().(ed25519.PublicKey)
	sk := ed25519.NewKeyFromSeed(testvec.Hex(e.t, d.SignSeed))
	eb := proto.EnrollBytes(ipub, testvec.Hex(e.t, d.SignPub), testvec.Hex(e.t, d.KexPub))
	return map[string]any{
		"invite_pub": proto.B64Encode(ipub), "sign_pub": b64hex(e.t, d.SignPub), "kex_pub": b64hex(e.t, d.KexPub),
		"platform": "ios", "model": "iPhone", "os_version": "18", "app_version": "1.0.0",
		"invite_sig": proto.B64Encode(ed25519.Sign(ik, eb)), "proof": proto.B64Encode(ed25519.Sign(sk, eb)),
	}
}

func (e *env) certVector(name string) testvec.Cert {
	var cad testvec.Cadastro
	testvec.Load(e.t, "cadastro", &cad)
	for _, c := range cad.Certs {
		if c.Aparelho == name {
			return c
		}
	}
	e.t.Fatal("cert vector")
	return testvec.Cert{}
}

func (e *env) wantCert(got any, name string) {
	e.t.Helper()
	c := e.certVector(name)
	want := map[string]any{
		"device_id": c.JSON.DeviceID, "user_id": c.JSON.UserID, "admin_label": c.JSON.AdminLabel,
		"sign_pub": c.JSON.SignPub, "kex_pub": c.JSON.KexPub,
		"enrolled_at": float64(c.JSON.EnrolledAt), "expires_at": float64(c.JSON.ExpiresAt), "sig": c.JSON.Sig,
	}
	if !reflect.DeepEqual(got, want) {
		e.t.Fatalf("cert %s differs from vector\n got %v\nwant %v", name, got, want)
	}
}

func TestEndToEndWithVectors(t *testing.T) {
	e := newEnv(t)
	a, b := e.device("A"), e.device("B")
	var cad testvec.Cadastro
	testvec.Load(t, "cadastro", &cad)

	// ---- enrollment of A: the vector request must produce the vector certificate byte for byte ----
	e.setMs(int64(e.certVector("A").EnrolledAt))
	e.queueIDs(a.UserID, a.DeviceID)
	e.addInvite(testvec.Hex(t, cad.InvitePub), nil, a.AdminLabel, 180*24*time.Hour)
	reqA := map[string]any{}
	for k, v := range cad.Req {
		reqA[k] = v
	}
	st, out := e.call("POST", "/v1/enroll", "", reqA)
	if st != 200 || out["new_user"] != true {
		t.Fatalf("enroll A: %d %v", st, out)
	}
	e.wantCert(out["cert"], "A")

	// retry by the same key is idempotent
	st, out2 := e.call("POST", "/v1/enroll", "", reqA)
	if st != 200 || !reflect.DeepEqual(out["cert"], out2["cert"]) {
		t.Fatalf("idempotent retry: %d %v", st, out2)
	}
	// someone else with the used invite
	bad := e.enrollReq(testvec.Hex(t, cad.InviteSeed), b)
	if st, o := e.call("POST", "/v1/enroll", "", bad); st != 401 || errCode(o) != "invite_invalid" {
		t.Fatalf("used invite: %d %v", st, o)
	}
	// unknown invite, tampered proof, low-order kex: all invite_invalid
	seed := make([]byte, 32)
	_, _ = rand.Read(seed)
	if st, o := e.call("POST", "/v1/enroll", "", e.enrollReq(seed, b)); st != 401 || errCode(o) != "invite_invalid" {
		t.Fatalf("unknown invite: %d %v", st, o)
	}
	e.queueIDs(b.UserID, b.DeviceID)
	e.addInvite(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey), nil, b.AdminLabel, 180*24*time.Hour)
	tam := e.enrollReq(seed, b)
	tam["proof"] = tam["invite_sig"]
	if st, o := e.call("POST", "/v1/enroll", "", tam); st != 401 || errCode(o) != "invite_invalid" {
		t.Fatalf("bad proof: %d %v", st, o)
	}
	e.adv(time.Minute) // refill the enroll rate limit
	for _, lo := range cad.LowOrder {
		lw := e.enrollReq(seed, b)
		lw["kex_pub"] = b64hex(t, lo)
		ik := ed25519.NewKeyFromSeed(seed)
		sk := ed25519.NewKeyFromSeed(testvec.Hex(t, b.SignSeed))
		eb := proto.EnrollBytes(ik.Public().(ed25519.PublicKey), testvec.Hex(t, b.SignPub), testvec.Hex(t, lo))
		lw["invite_sig"], lw["proof"] = proto.B64Encode(ed25519.Sign(ik, eb)), proto.B64Encode(ed25519.Sign(sk, eb))
		if st, o := e.call("POST", "/v1/enroll", "", lw); st != 401 {
			t.Fatalf("low-order kex %s accepted: %d %v", lo, st, o)
		}
	}
	if st, o := e.call("POST", "/v1/enroll", "", map[string]any{"invite_pub": "x"}); st != 400 {
		t.Fatalf("malformed: %d %v", st, o)
	}

	// ---- enrollment of B (an hour later; rate limit refilled) ----
	e.setMs(int64(e.certVector("B").EnrolledAt))
	st, out = e.call("POST", "/v1/enroll", "", e.enrollReq(seed, b))
	if st != 200 {
		t.Fatalf("enroll B: %d %v", st, out)
	}
	e.wantCert(out["cert"], "B")
	// A's key under another invite -> 409 key_in_use
	seed2 := make([]byte, 32)
	_, _ = rand.Read(seed2)
	e.addInvite(ed25519.NewKeyFromSeed(seed2).Public().(ed25519.PublicKey), nil, "Outro", time.Hour)
	if st, o := e.call("POST", "/v1/enroll", "", e.enrollReq(seed2, a)); st != 409 || errCode(o) != "key_in_use" {
		t.Fatalf("key_in_use: %d %v", st, o)
	}

	// ---- login ----
	tokA, tokB := e.login("A"), e.login("B")
	if st, o := e.call("GET", "/v1/directory", "", nil); st != 401 {
		t.Fatalf("no token: %d %v", st, o)
	}
	if st, _ := e.call("GET", "/v1/directory", "garbage", nil); st != 401 {
		t.Fatal("garbage token accepted")
	}
	// bad signature and replayed challenge
	e.adv(15 * time.Second)
	_, ch := e.call("POST", "/v1/auth/challenge", "", map[string]any{"device_id": a.DeviceID})
	wrong := proto.B64Encode(make([]byte, 64))
	if st, o := e.call("POST", "/v1/auth/verify", "", map[string]any{"device_id": a.DeviceID, "challenge": ch["challenge"], "sig": wrong}); st != 401 || errCode(o) != "auth_failed" {
		t.Fatalf("bad sig: %d %v", st, o)
	}
	chal, _ := proto.B64Decode(ch["challenge"].(string))
	good := proto.B64Encode(ed25519.Sign(ed25519.NewKeyFromSeed(testvec.Hex(t, a.SignSeed)),
		proto.AuthBytes(testvec.Hex(t, e.ch.Servidor.SignPub), uid(t, a.DeviceID), chal)))
	if st, o := e.call("POST", "/v1/auth/verify", "", map[string]any{"device_id": a.DeviceID, "challenge": ch["challenge"], "sig": good}); st != 401 {
		t.Fatalf("challenge reused after failure: %d %v", st, o)
	}
	// unknown device still gets a challenge
	if st, _ := e.call("POST", "/v1/auth/challenge", "", map[string]any{"device_id": "00000000-0000-4000-8000-000000000000"}); st != 200 {
		t.Fatal("unknown device challenge")
	}
	// the token is stored only as a hash
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM access_tokens WHERE token_hash = $1`, []byte(tokA)).Scan(&n)
	if n != 0 {
		t.Fatal("token stored in clear")
	}
	raw, _ := proto.B64Decode(tokA)
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM access_tokens WHERE token_hash = $1`, proto.TokenHash(raw)).Scan(&n)
	if n != 1 {
		t.Fatal("token hash not stored")
	}

	// ---- profile and directory ----
	if st, _ := e.call("PUT", "/v1/me/profile", tokA, map[string]any{"display_name": "Ana", "status": "online"}); st != 204 {
		t.Fatal("profile")
	}
	if st, _ := e.call("PUT", "/v1/me/profile", tokB, map[string]any{"display_name": "", "status": ""}); st != 400 {
		t.Fatal("empty display_name accepted")
	}
	st, dir := e.call("GET", "/v1/directory", tokB, nil)
	users := dir["users"].([]any)
	if st != 200 || len(users) != 2 {
		t.Fatalf("directory: %d %v", st, dir)
	}
	first := users[0].(map[string]any)
	if first["admin_label"] != a.AdminLabel || first["display_name"] != "Ana" {
		t.Fatalf("directory user: %v", first)
	}
	e.wantCert(first["devices"].([]any)[0], "A")
	if st, o := e.call("GET", "/v1/devices?ids="+a.DeviceID+","+b.DeviceID, tokA, nil); st != 200 || len(o["devices"].([]any)) != 2 {
		t.Fatalf("devices: %d %v", st, o)
	}

	// ---- conversation ----
	e.queueIDs("a0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d")
	wsA := e.wsAuth(tokA, nil)
	wsA.expect("ready")
	wsB := e.wsAuth(tokB, nil)
	wsB.expect("ready")
	st, conv := e.call("POST", "/v1/conversations", tokA, map[string]any{"kind": "direct", "peer_user_id": b.UserID})
	var ep testvec.Epoca
	testvec.Load(t, "epoca", &ep)
	if st != 200 || conv["created"] != true || conv["conversation_id"] != ep.ConversationID {
		t.Fatalf("create conv: %d %v", st, conv)
	}
	if f := wsB.expect("conversation"); f["conversation"].(map[string]any)["conversation_id"] != ep.ConversationID {
		t.Fatal("conversation event")
	}
	if st, c2 := e.call("POST", "/v1/conversations", tokB, map[string]any{"kind": "direct", "peer_user_id": a.UserID}); st != 200 || c2["created"] != false || c2["conversation_id"] != ep.ConversationID {
		t.Fatalf("idempotent conv: %d %v", st, c2)
	}
	if st, _ := e.call("POST", "/v1/conversations", tokA, map[string]any{"kind": "direct", "peer_user_id": a.UserID}); st != 400 {
		t.Fatal("conversation with self")
	}
	if st, l := e.call("GET", "/v1/conversations", tokB, nil); st != 200 || len(l["conversations"].([]any)) != 1 {
		t.Fatalf("list: %d %v", st, l)
	}

	// ---- messages before any epoch ----
	var m testvec.Mensagem
	testvec.Load(t, "mensagem", &m)
	var frame map[string]any
	_ = json.Unmarshal(m.Frame, &frame)
	wsA.write(frame)
	if f := wsA.expect("error"); f["code"] != "epoch_required" || f["req_id"] != "r1" {
		t.Fatalf("no epoch yet: %v", f)
	}

	// ---- epoch (vector declaration, wraps and signature) ----
	epochBody := func() map[string]any {
		wraps := []map[string]string{}
		for _, w := range ep.Embrulhos {
			if w.Destino != "escrow" {
				wraps = append(wraps, map[string]string{"device_id": w.DeviceID, "wrapped_key": b64hex(t, w.WrappedKey)})
			}
		}
		esc := ""
		for _, w := range ep.Embrulhos {
			if w.Destino == "escrow" {
				esc = b64hex(t, w.WrappedKey)
			}
		}
		return map[string]any{"epoch": 1, "creator_device_id": a.DeviceID, "key_commitment": b64hex(t, ep.Commitment),
			"recipients": ep.Recipients, "wraps": wraps, "escrow_wrap": esc, "signature": b64hex(t, ep.StatementSig)}
	}
	path := "/v1/conversations/" + ep.ConversationID + "/epochs"
	tamper := epochBody()
	s := testvec.Hex(t, ep.StatementSig)
	s[5] ^= 1
	tamper["signature"] = proto.B64Encode(s)
	if st, o := e.call("POST", path, tokA, tamper); st != 400 || errCode(o) != "bad_signature" {
		t.Fatalf("tampered epoch signature: %d %v", st, o)
	}
	if st, o := e.call("POST", path, tokB, epochBody()); st != 403 {
		t.Fatalf("creator != caller: %d %v", st, o)
	}
	short := epochBody()
	short["recipients"] = ep.Recipients[:1]
	short["wraps"] = short["wraps"].([]map[string]string)[:1]
	if st, o := e.call("POST", path, tokA, short); st != 409 || errCode(o) != "device_set_changed" {
		t.Fatalf("missing recipient: %d %v", st, o)
	}
	skip := epochBody()
	skip["epoch"] = 3
	if st, o := e.call("POST", path, tokA, skip); st != 409 || errCode(o) != "epoch_conflict" {
		t.Fatalf("epoch gap: %d %v", st, o)
	}
	if st, o := e.call("POST", path, tokA, epochBody()); st != 201 {
		t.Fatalf("epoch vector rejected: %d %v", st, o)
	}
	if st, o := e.call("POST", path, tokA, epochBody()); st != 409 || errCode(o) != "epoch_conflict" {
		t.Fatalf("duplicate epoch: %d %v", st, o)
	}
	// each recipient gets exactly its own wrap, escrow never leaves the server
	for name, tok := range map[string]string{"A": tokA, "B": tokB} {
		_, mine := e.call("GET", "/v1/epochs/mine?after=0", tok, nil)
		items := mine["items"].([]any)
		if len(items) != 1 || mine["has_more"] != false {
			t.Fatalf("%s epochs/mine: %v", name, mine)
		}
		it := items[0].(map[string]any)
		want := ""
		for _, w := range ep.Embrulhos {
			if w.Destino == name {
				want = b64hex(t, w.WrappedKey)
			}
		}
		if it["wrapped_key"] != want || it["signature"] != b64hex(t, ep.StatementSig) || it["creator_device_id"] != a.DeviceID {
			t.Fatalf("%s epoch item: %v", name, it)
		}
	}
	if f := wsB.expect("epoch"); f["item"].(map[string]any)["epoch"] != float64(1) {
		t.Fatal("epoch event")
	}
	wsA.expect("epoch")
	_, mine := e.call("GET", "/v1/epochs/mine?after=999", tokB, nil)
	if len(mine["items"].([]any)) != 0 {
		t.Fatal("after filter")
	}

	// ---- send: vector message ----
	wsA.write(frame)
	ack := wsA.expect("ack")
	if ack["seq"] != float64(1) || ack["message_id"] != m.MessageID || ack["req_id"] != "r1" {
		t.Fatalf("ack: %v", ack)
	}
	got := wsB.expect("message")["message"].(map[string]any)
	fm := frame["message"].(map[string]any)
	for _, k := range []string{"conversation_id", "sender_device_id", "message_id", "nonce", "ciphertext", "signature"} {
		if got[k] != fm[k] {
			t.Fatalf("delivered %s differs", k)
		}
	}
	if got["seq"] != float64(1) || got["epoch"] != float64(1) || got["sent_at"] != float64(m.SentAt) {
		t.Fatalf("delivered message: %v", got)
	}
	// retry with same message_id: same ack, nothing delivered again
	wsA.write(frame)
	if ack2 := wsA.expect("ack"); ack2["seq"] != float64(1) || ack2["created_at"] != ack["created_at"] {
		t.Fatalf("retry ack: %v", ack2)
	}
	// Frames are ordered per connection: a pong after the retry proves nothing else was queued before it.
	wsB.write(map[string]any{"type": "ping", "ts": 777})
	for {
		f, _ := wsB.read(5 * time.Second)
		if f == nil {
			t.Fatal("wsB ended")
		}
		if f["type"] == "message" {
			t.Fatalf("duplicate delivered: %v", f)
		}
		if f["type"] == "pong" {
			break
		}
	}
	// tampered signature (new message_id so it is not a retry)
	badMsg := map[string]any{}
	for k, v := range fm {
		badMsg[k] = v
	}
	badMsg["message_id"] = "6f1e2d3c-4b5a-4968-a7b6-c5d4e3f2a1b1"
	wsA.write(map[string]any{"type": "send", "req_id": "r2", "message": badMsg})
	if f := wsA.expect("error"); f["code"] != "bad_signature" || f["req_id"] != "r2" {
		t.Fatalf("bad message signature: %v", f)
	}
	// sender_device_id of someone else
	imp := map[string]any{}
	for k, v := range fm {
		imp[k] = v
	}
	imp["sender_device_id"] = b.DeviceID
	wsA.write(map[string]any{"type": "send", "req_id": "r3", "message": imp})
	if f := wsA.expect("error"); f["code"] != "forbidden" {
		t.Fatalf("impersonation: %v", f)
	}
	// stale epoch
	stale := map[string]any{}
	for k, v := range fm {
		stale[k] = v
	}
	stale["epoch"], stale["message_id"] = 2, "6f1e2d3c-4b5a-4968-a7b6-c5d4e3f2a1b2"
	wsA.write(map[string]any{"type": "send", "req_id": "r4", "message": stale})
	if f := wsA.expect("error"); f["code"] != "epoch_required" || f["latest_epoch"] != float64(1) {
		t.Fatalf("stale epoch: %v", f)
	}
	// ping
	wsA.write(map[string]any{"type": "ping", "ts": 12345})
	if f := wsA.expect("pong"); f["ts"] != float64(12345) {
		t.Fatalf("pong: %v", f)
	}

	// ---- history ----
	st, h := e.call("GET", "/v1/conversations/"+ep.ConversationID+"/messages?after=0", tokB, nil)
	msgs := h["messages"].([]any)
	if st != 200 || len(msgs) != 1 || h["has_more"] != false {
		t.Fatalf("history: %d %v", st, h)
	}
	hm := msgs[0].(map[string]any)
	if hm["ciphertext"] != fm["ciphertext"] || hm["signature"] != fm["signature"] || hm["seq"] != float64(1) {
		t.Fatalf("history item: %v", hm)
	}
	if _, h2 := e.call("GET", "/v1/conversations/"+ep.ConversationID+"/messages?after=1", tokB, nil); len(h2["messages"].([]any)) != 0 {
		t.Fatal("after=1 not empty")
	}
	_, lst := e.call("GET", "/v1/conversations", tokA, nil)
	if c := lst["conversations"].([]any)[0].(map[string]any); c["last_seq"] != float64(1) || c["latest_epoch"] != float64(1) {
		t.Fatalf("conversation counters: %v", c)
	}

	// ---- outsider cannot read ----
	e.queueIDs("5a5a5a5a-1111-4222-8333-444444444444", e.device("C").DeviceID)
	seedC := make([]byte, 32)
	_, _ = rand.Read(seedC)
	e.addInvite(ed25519.NewKeyFromSeed(seedC).Public().(ed25519.PublicKey), nil, "Intruso", time.Hour)
	e.adv(time.Minute)
	if st, o := e.call("POST", "/v1/enroll", "", e.enrollReq(seedC, e.device("C"))); st != 200 {
		t.Fatalf("enroll C: %d %v", st, o)
	}
	tokC := e.login("C")
	if st, _ := e.call("GET", "/v1/conversations/"+ep.ConversationID+"/messages", tokC, nil); st != 403 {
		t.Fatalf("outsider history: %d", st)
	}
	if st, _ := e.call("GET", "/v1/conversations/00000000-0000-4000-8000-000000000000/messages", tokC, nil); st != 404 {
		t.Fatalf("missing conversation: %d", st)
	}
	e.wsAuth(tokC, []string{ep.ConversationID}).expectClose(4000)
	// new device in the directory invalidates the epoch for the next send
	wsA.expect("directory_changed")
	wsB.expect("directory_changed")
	tokA = e.login("A")
	wsA2 := e.wsAuth(tokA, []string{ep.ConversationID}) // floating-chat style scope
	wsA2.expect("ready")

	// ---- revocation: B revoked via the CLI's SQL + NOTIFY ----
	ctx := context.Background()
	_, _ = e.pool.Exec(ctx, `UPDATE devices SET revoked_at = $2 WHERE id = $1`, uid(t, b.DeviceID), e.now())
	_, _ = e.pool.Exec(ctx, `DELETE FROM access_tokens WHERE device_id = $1`, uid(t, b.DeviceID))
	if _, err := e.pool.Exec(ctx, `SELECT pg_notify('device_revoked', $1)`, b.DeviceID); err != nil {
		t.Fatal(err)
	}
	wsB.expectClose(4003)
	wsA.expect("directory_changed")
	if st, o := e.call("GET", "/v1/directory", tokB, nil); st != 401 {
		t.Fatalf("revoked token: %d %v", st, o)
	}
	st, rv := e.loginRaw(b)
	if st != 401 || errCode(rv) != "device_revoked" {
		t.Fatalf("revoked login: %d %v", st, rv)
	}
	proof, _ := proto.B64Decode(rv["revoked_sig"].(string))
	if !proto.Verify(testvec.Hex(t, e.ch.Servidor.SignPub), proto.RevokedBytes(uid(t, b.DeviceID), rv["_chal"].([]byte)), proof) {
		t.Fatal("revocation proof does not verify")
	}
	// A's next send needs a new epoch (set of active devices changed)
	wsA.write(frame2(frame, "6f1e2d3c-4b5a-4968-a7b6-c5d4e3f2a1b3", "r5"))
	if f := wsA.expect("error"); f["code"] != "epoch_required" {
		t.Fatalf("send after revocation: %v", f)
	}
	_, dev := e.call("GET", "/v1/devices?ids="+b.DeviceID, tokA, nil)
	if dev["devices"].([]any)[0].(map[string]any)["revoked_at"] == nil {
		t.Fatal("revoked_at missing from /v1/devices")
	}
	_, dir = e.call("GET", "/v1/directory", tokA, nil)
	for _, u := range dir["users"].([]any) {
		if u.(map[string]any)["user_id"] == b.UserID && len(u.(map[string]any)["devices"].([]any)) != 0 {
			t.Fatal("revoked device still in directory")
		}
	}
}

func frame2(frame map[string]any, mid, req string) map[string]any {
	m := map[string]any{}
	for k, v := range frame["message"].(map[string]any) {
		m[k] = v
	}
	m["message_id"] = mid
	return map[string]any{"type": "send", "req_id": req, "message": m}
}
