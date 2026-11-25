package server_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
	"github.com/nettotech/direct/server/internal/testvec"
	"golang.org/x/crypto/curve25519"
)

// ---- a client of the group API ----

// member is an enrolled device and what its app holds.
type member struct {
	e            *env
	id, user     string
	label, token string
	sign         ed25519.PrivateKey
	kex          []byte
	invite       []byte // seed
}

func (e *env) exec(sql string, args ...any) {
	e.t.Helper()
	if _, err := e.pool.Exec(context.Background(), sql, args...); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) count(sql string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

func randb(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

// grant inserts an access token, so that tests do not spend the login rate limits.
func (e *env) grant(device string) string {
	e.t.Helper()
	raw := randb(32)
	e.exec(`INSERT INTO access_tokens (token_hash, device_id, created_at, expires_at) VALUES ($1,$2,$3,$4)`,
		proto.TokenHash(raw), uid(e.t, device), e.now(), e.now().Add(1000*time.Hour))
	return proto.B64Encode(raw)
}

// enrollWith enrolls a new device with an invite seed through /v1/enroll.
func (e *env) enrollWith(seed []byte) (*member, int, map[string]any) {
	e.t.Helper()
	e.adv(time.Minute) // enroll rate limit
	invite := ed25519.NewKeyFromSeed(seed)
	ipub := invite.Public().(ed25519.PublicKey)
	signPub, sign, _ := ed25519.GenerateKey(rand.Reader)
	kex := randb(32)
	kexPub, err := curve25519.X25519(kex, curve25519.Basepoint)
	if err != nil {
		e.t.Fatal(err)
	}
	eb := proto.EnrollBytes(ipub, signPub, kexPub)
	st, out := e.call("POST", "/v1/enroll", "", map[string]any{
		"invite_pub": proto.B64Encode(ipub), "sign_pub": proto.B64Encode(signPub), "kex_pub": proto.B64Encode(kexPub),
		"platform": "android", "model": "m", "os_version": "1", "app_version": "1",
		"invite_sig": proto.B64Encode(ed25519.Sign(invite, eb)), "proof": proto.B64Encode(ed25519.Sign(sign, eb))})
	if st != 200 {
		return nil, st, out
	}
	cert := out["cert"].(map[string]any)
	m := &member{e: e, id: cert["device_id"].(string), user: cert["user_id"].(string),
		label: cert["admin_label"].(string), sign: sign, kex: kex, invite: seed}
	m.token = e.grant(m.id)
	return m, st, out
}

func (e *env) invite(user *string, label string) []byte {
	e.t.Helper()
	seed := randb(32)
	e.addInvite(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey), user, label, 180*24*time.Hour)
	return seed
}

func (e *env) newMember(label string) *member {
	e.t.Helper()
	m, st, out := e.enrollWith(e.invite(nil, label))
	if m == nil {
		e.t.Fatalf("enroll %s: %d %v", label, st, out)
	}
	return m
}

// another enrolls one more device of the same user.
func (m *member) another() *member {
	m.e.t.Helper()
	n, st, out := m.e.enrollWith(m.e.invite(&m.user, m.label))
	if n == nil {
		m.e.t.Fatalf("enroll again: %d %v", st, out)
	}
	return n
}

func (m *member) call(method, path string, body any) (int, map[string]any) {
	m.e.t.Helper()
	return m.e.call(method, path, m.token, body)
}

// grp is a client's view of one group: the verified chain.
type grp struct {
	e    *env
	conv proto.UUID
	id   string
	st   *proto.GroupState
	meta []byte // current meta JSON
}

func (e *env) newGrp() *grp {
	conv := e.randUUID()
	return &grp{e: e, conv: conv, id: proto.FormatUUID(conv), st: proto.NewGroupState(conv)}
}

func (g *grp) change(m *member, kind uint32, body []byte) proto.SignedChange {
	return proto.SignChange(proto.GroupChange{Conv: g.conv, N: g.st.N + 1, Prev: g.st.Head, Kind: kind,
		AuthorType: proto.AuthorDevice, AuthorDevice: uid(g.e.t, m.id), AuthorUser: uid(g.e.t, m.user),
		CreatedAt: uint64(g.e.now().UnixMilli()), Body: body}, m.sign)
}

func wire(r proto.SignedChange) map[string]any {
	return map[string]any{"change_bytes": proto.B64Encode(r.Bytes), "signature": proto.B64Encode(r.Sig)}
}

// applied follows the chain on the client side after the server accepted rec.
func (g *grp) applied(rec proto.SignedChange) {
	g.e.t.Helper()
	keys, err := store.ChainKeys(context.Background(), g.e.pool, []proto.SignedChange{rec})
	if err != nil {
		g.e.t.Fatal(err)
	}
	if err := g.st.Apply(rec, keys); err != nil {
		g.e.t.Fatal(err)
	}
}

func devices(ms ...*member) []*member {
	slices.SortFunc(ms, func(a, b *member) int { return strings.Compare(a.id, b.id) })
	return ms
}

// epochBody builds the group epoch statement for chain position (n, head). Wraps are random: the
// server cannot open them.
func (g *grp) epochBody(creator *member, epoch uint32, n uint64, head [32]byte, to ...*member) map[string]any {
	var ids []proto.UUID
	recips := []string{}
	wraps := []map[string]string{}
	for _, m := range devices(to...) {
		ids = append(ids, uid(g.e.t, m.id))
		recips = append(recips, m.id)
		wraps = append(wraps, map[string]string{"device_id": m.id, "wrapped_key": proto.B64Encode(randb(80))})
	}
	commit := randb(32)
	escrow := testvec.Hex(g.e.t, g.e.ch.Escrow.KexPub)
	sig := ed25519.Sign(creator.sign, proto.GroupEpochBytes(g.conv, epoch, uid(g.e.t, creator.id), commit, escrow, n, head, ids))
	return map[string]any{"epoch": epoch, "creator_device_id": creator.id, "key_commitment": proto.B64Encode(commit),
		"chain_n": n, "chain_hash": proto.B64Encode(head[:]), "recipients": recips, "wraps": wraps,
		"escrow_wrap": proto.B64Encode(randb(80)), "signature": proto.B64Encode(sig)}
}

func metaBody(epoch uint32, commit [32]byte) map[string]any {
	return map[string]any{"epoch": epoch, "meta_commit": proto.B64Encode(commit[:]),
		"nonce": proto.B64Encode(randb(24)), "ciphertext": proto.B64Encode(randb(256 + 16))}
}

func users(t *testing.T, ms ...*member) []proto.UUID {
	var out []proto.UUID
	for _, m := range ms {
		out = append(out, uid(t, m.user))
	}
	slices.SortFunc(out, func(a, b proto.UUID) int { return slices.Compare(a[:], b[:]) })
	return slices.Compact(out)
}

// createBody is the whole POST /v1/groups of creator, admin, with others as members.
func (g *grp) createBody(creator *member, others ...*member) (map[string]any, proto.SignedChange) {
	g.meta = []byte(`{"v":1,"name":"Atlas"}`)
	commit := proto.MetaCommit(g.conv, g.meta)
	var list []proto.GroupMember
	for _, u := range users(g.e.t, append([]*member{creator}, others...)...) {
		role := proto.RoleMember
		if proto.FormatUUID(u) == creator.user {
			role = proto.RoleAdmin
		}
		list = append(list, proto.GroupMember{User: u, Role: role})
	}
	rec := g.change(creator, proto.KindCreate, proto.CreateBody("", commit, list))
	head := proto.ChangeHash(rec)
	return map[string]any{"change": wire(rec), "meta": metaBody(1, commit),
		"epoch": g.epochBody(creator, 1, 1, head, append([]*member{creator}, others...)...)}, rec
}

func (e *env) createGroup(creator *member, others ...*member) *grp {
	e.t.Helper()
	g := e.newGrp()
	body, rec := g.createBody(creator, others...)
	st, out := creator.call("POST", "/v1/groups", body)
	if st != 201 {
		e.t.Fatalf("create group: %d %v", st, out)
	}
	g.applied(rec)
	return g
}

// post appends a record with the given epoch and meta, and follows it if accepted.
func (g *grp) post(m *member, rec proto.SignedChange, epoch, meta map[string]any) (int, map[string]any) {
	g.e.t.Helper()
	st, out := m.call("POST", "/v1/groups/"+g.id+"/changes", map[string]any{"change": wire(rec), "epoch": epoch, "meta": meta})
	if st == 201 {
		g.applied(rec)
	}
	return st, out
}

// rekey appends an add or remove record with its epoch for the devices "to" and the current meta.
func (g *grp) rekey(m *member, kind uint32, body []byte, epoch uint32, to ...*member) proto.SignedChange {
	g.e.t.Helper()
	rec := g.change(m, kind, body)
	st, out := g.post(m, rec, g.epochBody(m, epoch, g.st.N+1, proto.ChangeHash(rec), to...),
		metaBody(epoch, g.st.MetaCommit))
	if st != 201 {
		g.e.t.Fatalf("kind %d: %d %v", kind, st, out)
	}
	return rec
}

// msgFrame builds a send frame; the server only checks sizes and the signature.
func (g *grp) msgFrame(m *member, epoch uint32) map[string]any {
	conv := uid(g.e.t, g.id)
	mid := g.e.randUUID()
	nonce, ct := randb(24), randb(256+16)
	hdr := proto.MsgHeader(conv, epoch, uid(g.e.t, m.id), mid, 1)
	return map[string]any{"type": "send", "req_id": "r", "message": map[string]any{
		"conversation_id": g.id, "epoch": epoch, "sender_device_id": m.id, "message_id": proto.FormatUUID(mid), "sent_at": 1,
		"nonce": proto.B64Encode(nonce), "ciphertext": proto.B64Encode(ct),
		"signature": proto.B64Encode(ed25519.Sign(m.sign, proto.MsgSigBytes(hdr, nonce, ct)))}}
}

// say sends a message and returns the answer (ack or error).
func (g *grp) say(m *member, epoch uint32) map[string]any {
	g.e.t.Helper()
	w := g.e.wsAuth(m.token, []string{g.id})
	w.expect("ready")
	defer w.c.CloseNow()
	w.write(g.msgFrame(m, epoch))
	for {
		f, code := w.read(5 * time.Second)
		if f == nil {
			g.e.t.Fatalf("send: closed %d", code)
		}
		if f["type"] == "ack" || f["type"] == "error" {
			return f
		}
	}
}

func (w *wsc) expectNone(typ string) {
	w.t.Helper()
	w.write(map[string]any{"type": "ping", "ts": 1})
	time.Sleep(300 * time.Millisecond)
	w.write(map[string]any{"type": "ping", "ts": 2})
	for {
		f, code := w.read(5 * time.Second)
		if f == nil {
			w.t.Fatalf("closed %d", code)
		}
		if f["type"] == typ {
			w.t.Fatalf("unexpected %q: %v", typ, f)
		}
		if f["type"] == "pong" && f["ts"] == float64(2) {
			return
		}
	}
}

func detail(m map[string]any, k string) any {
	inner, _ := m["error"].(map[string]any)
	return inner[k]
}

func wantErr(t *testing.T, what string, st int, out map[string]any, status int, code string) {
	t.Helper()
	if st != status || errCode(out) != code {
		t.Fatalf("%s: %d %v, want %d %s", what, st, out, status, code)
	}
}

func list(m map[string]any, k string) []any {
	l, _ := m[k].([]any)
	return l
}

// ---- tests ----

func TestGroupLifecycle(t *testing.T) {
	e := newEnv(t)
	a, b, c, d := e.newMember("Ana"), e.newMember("Bia"), e.newMember("Caio"), e.newMember("Davi")
	wb, wd := e.wsAuth(b.token, nil), e.wsAuth(d.token, nil)
	wb.expect("ready")
	wd.expect("ready")

	g := e.newGrp()
	body, rec := g.createBody(a, b, c)
	// The epoch must cover exactly the active devices of the members.
	bad := map[string]any{"change": body["change"], "meta": body["meta"], "epoch": g.epochBody(a, 1, 1, proto.ChangeHash(rec), a, b)}
	st, out := a.call("POST", "/v1/groups", bad)
	wantErr(t, "partial recipients", st, out, 409, "device_set_changed")
	// Nothing of a refused request stays.
	if e.count(`SELECT count(*) FROM conversations`)+e.count(`SELECT count(*) FROM group_changes`) != 0 {
		t.Fatal("refused creation left rows")
	}
	st, out = b.call("POST", "/v1/groups", body)
	wantErr(t, "not the author", st, out, 403, "forbidden")
	st, out = a.call("POST", "/v1/groups", body)
	if st != 201 || out["kind"] != "group" || out["chain_n"] != float64(1) || out["admin_label"] != nil || out["closed"] != false ||
		out["latest_epoch"] != float64(1) || len(list(out, "members")) != 3 {
		t.Fatalf("create: %d %v", st, out)
	}
	g.applied(rec)
	st, out = a.call("POST", "/v1/groups", body)
	wantErr(t, "same id", st, out, 409, "group_exists")
	if f := wb.expect("conversation"); f["conversation"].(map[string]any)["kind"] != "group" {
		t.Fatalf("conversation event: %v", f)
	}
	if item := wb.expect("epoch")["item"].(map[string]any); item["chain_n"] != float64(1) || item["chain_hash"] != proto.B64Encode(g.st.Head[:]) {
		t.Fatalf("epoch event: %v", item)
	}

	// Outsiders see nothing.
	for _, path := range []string{"/changes", "/meta"} {
		st, out = d.call("GET", "/v1/groups/"+g.id+path, nil)
		wantErr(t, "outsider "+path, st, out, 403, "forbidden")
	}
	for _, path := range []string{"/epochs/mine", "/messages", "/access-events"} {
		st, out = d.call("GET", "/v1/conversations/"+g.id+path, nil)
		wantErr(t, "outsider "+path, st, out, 403, "forbidden")
	}
	if f := g.say(b, 1); f["type"] != "ack" {
		t.Fatalf("send: %v", f)
	}

	// Chain checks on the server.
	add := proto.AddBody(false, users(t, d))
	r := g.change(b, proto.KindAdd, add)
	st, out = g.post(b, r, g.epochBody(b, 2, 2, proto.ChangeHash(r), a, b, c, d), metaBody(2, g.st.MetaCommit))
	wantErr(t, "member adds", st, out, 400, "chain_invalid")
	if detail(out, "reason") != "papel" {
		t.Fatalf("reason: %v", out)
	}
	for reason, mutate := range map[string]func() proto.SignedChange{
		"prev_hash": func() proto.SignedChange {
			head := g.st.Head
			g.st.Head[0] ^= 1
			defer func() { g.st.Head = head }()
			return g.change(a, proto.KindAdd, add)
		},
		"assinatura": func() proto.SignedChange {
			r := g.change(a, proto.KindAdd, add)
			r.Sig[0] ^= 1
			return r
		},
	} {
		st, out = g.post(a, mutate(), nil, nil)
		if st != 400 || detail(out, "reason") != reason {
			t.Fatalf("%s: %d %v", reason, st, out)
		}
	}
	g.st.N++ // a record for the wrong position
	r = g.change(a, proto.KindAdd, add)
	g.st.N--
	st, out = g.post(a, r, nil, nil)
	wantErr(t, "position", st, out, 409, "chain_conflict")
	if detail(out, "chain_n") != float64(1) {
		t.Fatalf("conflict: %v", out)
	}
	r = g.change(a, proto.KindAdd, add)
	st, out = g.post(a, r, nil, nil)
	wantErr(t, "add without epoch", st, out, 400, "bad_request")
	st, out = g.post(a, r, g.epochBody(a, 2, 2, proto.ChangeHash(r), a, b, c), metaBody(2, g.st.MetaCommit))
	wantErr(t, "add without the new member", st, out, 409, "device_set_changed")
	st, out = g.post(a, r, g.epochBody(a, 2, 2, proto.ChangeHash(r), a, b, c, d), nil)
	wantErr(t, "add without meta", st, out, 400, "bad_request")
	st, out = g.post(a, r, g.epochBody(a, 2, 1, g.st.Head, a, b, c, d), metaBody(2, g.st.MetaCommit))
	wantErr(t, "epoch of another position", st, out, 400, "bad_request")
	if e.count(`SELECT count(*) FROM group_changes`) != 1 || e.count(`SELECT count(*) FROM epochs`) != 1 {
		t.Fatal("refused changes left rows")
	}
	g.rekey(a, proto.KindAdd, add, 2, a, b, c, d)
	if f := wb.expect("group_change"); f["conversation_id"] != g.id || f["change"].(map[string]any)["n"] != float64(2) || f["meta"] == nil {
		t.Fatalf("group_change: %v", f)
	}
	wd.expect("conversation")
	wd.expect("group_change")
	wd.expect("epoch")

	// A newcomer without history gets only the epochs from the entry on.
	_, mine := d.call("GET", "/v1/conversations/"+g.id+"/epochs/mine", nil)
	if items := list(mine, "items"); len(items) != 1 || items[0].(map[string]any)["epoch"] != float64(2) {
		t.Fatalf("newcomer epochs: %v", mine)
	}
	history := func(addN uint64, epoch uint32, to *member) map[string]any {
		return map[string]any{"add_n": addN, "items": []map[string]any{
			{"epoch": epoch, "device_id": to.id, "wrapped_key": proto.B64Encode(randb(80))}}}
	}
	st, out = a.call("POST", "/v1/groups/"+g.id+"/history-wraps", history(2, 1, d))
	wantErr(t, "release without history=1", st, out, 400, "bad_request")

	// Rename: current epoch and the commit of the record.
	meta := []byte(`{"v":1,"name":"Atlas 2"}`)
	commit := proto.MetaCommit(g.conv, meta)
	r = g.change(a, proto.KindRename, proto.RenameBody(commit))
	st, out = g.post(a, r, nil, metaBody(1, commit))
	wantErr(t, "rename with old epoch", st, out, 400, "bad_request")
	if st, out = g.post(a, r, nil, metaBody(2, commit)); st != 201 {
		t.Fatalf("rename: %d %v", st, out)
	}
	_, metas := a.call("GET", "/v1/groups/"+g.id+"/meta", nil)
	if items := list(metas, "items"); len(items) != 1 || items[0].(map[string]any)["meta_commit"] != proto.B64Encode(commit[:]) {
		t.Fatalf("meta: %v", metas)
	}

	// Promote and an epoch on its own (10.3).
	if st, out = g.post(a, g.change(a, proto.KindPromote, proto.UsersBody(users(t, b))), nil, nil); st != 201 {
		t.Fatalf("promote: %d %v", st, out)
	}
	epochs := "/v1/conversations/" + g.id + "/epochs"
	ep := g.epochBody(b, 3, g.st.N-1, g.st.Head, a, b, c, d)
	ep["meta"] = metaBody(3, g.st.MetaCommit)
	st, out = b.call("POST", epochs, ep)
	wantErr(t, "stale chain position", st, out, 409, "chain_conflict")
	ep = g.epochBody(b, 3, g.st.N, g.st.Head, a, b, c, d)
	st, out = b.call("POST", epochs, ep)
	wantErr(t, "epoch without meta", st, out, 400, "bad_request")
	ep["meta"] = metaBody(3, g.st.MetaCommit)
	if st, out = b.call("POST", epochs, ep); st != 201 {
		t.Fatalf("epoch 3: %d %v", st, out)
	}

	// Removal: new epoch without the removed one, who learns about it and loses access.
	removal := g.rekey(a, proto.KindRemove, proto.UsersBody(users(t, d)), 4, a, b, c)
	n := float64(g.st.N)
	for {
		f := wd.expect("group_change")
		if f["change"].(map[string]any)["change_bytes"] == proto.B64Encode(removal.Bytes) {
			break
		}
	}
	st, out = d.call("GET", "/v1/groups/"+g.id+"/changes", nil)
	wantErr(t, "removed member", st, out, 403, "forbidden")
	_, chain := a.call("GET", "/v1/groups/"+g.id+"/changes?after=1&limit=2", nil)
	if l := list(chain, "changes"); len(l) != 2 || chain["has_more"] != true || l[0].(map[string]any)["n"] != float64(2) {
		t.Fatalf("changes page: %v", chain)
	}
	_, chain = a.call("GET", "/v1/groups/"+g.id+"/changes", nil)
	if l := list(chain, "changes"); float64(len(l)) != n || chain["has_more"] != false {
		t.Fatalf("changes: %v", chain)
	}

	// Added again with the history released: now the old epochs may be wrapped for the newcomer.
	g.rekey(a, proto.KindAdd, proto.AddBody(true, users(t, d)), 5, a, b, c, d)
	addN := g.st.N
	st, out = b.call("POST", "/v1/groups/"+g.id+"/history-wraps", history(addN, 1, c))
	wantErr(t, "release to someone not added", st, out, 400, "bad_request")
	st, out = c.call("POST", "/v1/groups/"+g.id+"/history-wraps", history(addN, 1, d))
	wantErr(t, "release by a member", st, out, 403, "forbidden")
	st, out = a.call("POST", "/v1/groups/"+g.id+"/history-wraps", history(addN, 5, d))
	wantErr(t, "release of a later epoch", st, out, 400, "bad_request")
	for _, want := range []float64{1, 0} { // a retry is harmless
		if st, out = a.call("POST", "/v1/groups/"+g.id+"/history-wraps", history(addN, 1, d)); st != 201 || out["accepted"] != want {
			t.Fatalf("release: %d %v", st, out)
		}
	}
	if e.count(`SELECT count(*) FROM epoch_key_wraps WHERE source = 'history'`) != 1 {
		t.Fatal("history wrap source")
	}
	if e.count(`SELECT count(*) FROM conversation_members WHERE user_id = $1`, uid(t, d.user)) != 2 {
		t.Fatal("one row per interval")
	}

	// Leaving: the next sender creates the epoch without who left.
	if st, out = g.post(c, g.change(c, proto.KindLeave, nil), nil, nil); st != 201 {
		t.Fatalf("leave: %d %v", st, out)
	}
	if f := g.say(a, 5); f["code"] != "epoch_required" {
		t.Fatalf("after leave: %v", f)
	}

	// A moderator record never comes over HTTP.
	_, modKey, _ := ed25519.GenerateKey(rand.Reader)
	mr := proto.SignChange(proto.GroupChange{Conv: g.conv, N: g.st.N + 1, Prev: g.st.Head, Kind: proto.KindClose,
		AuthorType: proto.AuthorModerator}, modKey)
	st, out = g.post(a, mr, nil, nil)
	wantErr(t, "moderator over HTTP", st, out, 403, "forbidden")

	// Closed: no records, epochs, messages or uploads; the history stays readable.
	if st, out = g.post(a, g.change(a, proto.KindClose, nil), nil, nil); st != 201 {
		t.Fatalf("close: %d %v", st, out)
	}
	st, out = g.post(a, g.change(a, proto.KindRename, proto.RenameBody(commit)), nil, metaBody(5, commit))
	wantErr(t, "record after close", st, out, 409, "group_closed")
	ep = g.epochBody(a, 6, g.st.N, g.st.Head, a, b, d)
	ep["meta"] = metaBody(6, g.st.MetaCommit)
	st, out = a.call("POST", epochs, ep)
	wantErr(t, "epoch after close", st, out, 409, "group_closed")
	if f := g.say(a, 5); f["code"] != "group_closed" {
		t.Fatalf("send after close: %v", f)
	}
	st, out = e.upload(a.token, g.id, 100)
	wantErr(t, "upload after close", st, out, 409, "group_closed")
	st, out = a.call("POST", "/v1/groups/"+g.id+"/history-wraps", history(addN, 2, d))
	wantErr(t, "release after close", st, out, 409, "group_closed")
	_, convs := a.call("GET", "/v1/conversations", nil)
	if cv := list(convs, "conversations")[0].(map[string]any); cv["closed"] != true {
		t.Fatalf("closed flag: %v", cv)
	}
}

func TestGroupMemberLimit(t *testing.T) {
	e := newEnv(t)
	a := e.newMember("Ana")
	extra := func(n int) []proto.UUID {
		var out []proto.UUID
		for range n {
			u := e.randUUID()
			e.exec(`INSERT INTO users (id, admin_label, created_at) VALUES ($1,'x',$2)`, u, e.now())
			out = append(out, u)
		}
		return out
	}
	g := e.newGrp()
	others := extra(100)
	listing := []proto.GroupMember{{User: uid(t, a.user), Role: proto.RoleAdmin}}
	for _, u := range others {
		listing = append(listing, proto.GroupMember{User: u, Role: proto.RoleMember})
	}
	slices.SortFunc(listing, func(x, y proto.GroupMember) int { return slices.Compare(x.User[:], y.User[:]) })
	commit := [32]byte{1}
	create := func(l []proto.GroupMember) (int, map[string]any, proto.SignedChange) {
		rec := g.change(a, proto.KindCreate, proto.CreateBody("", commit, l))
		st, out := a.call("POST", "/v1/groups", map[string]any{"change": wire(rec), "meta": metaBody(1, commit),
			"epoch": g.epochBody(a, 1, 1, proto.ChangeHash(rec), a)})
		return st, out, rec
	}
	st, out, _ := create(listing) // 101
	if st != 400 || detail(out, "reason") != "limite" {
		t.Fatalf("101 members: %d %v", st, out)
	}
	last := slices.IndexFunc(listing, func(m proto.GroupMember) bool { return m.Role == proto.RoleMember })
	listing = slices.Delete(listing, last, last+1)
	st, out, rec := create(listing)
	if st != 201 {
		t.Fatalf("100 members: %d %v", st, out)
	}
	g.applied(rec)
	more := extra(1)
	st, out = g.post(a, g.change(a, proto.KindAdd, proto.AddBody(false, more)), nil, nil)
	if st != 400 || detail(out, "reason") != "limite" {
		t.Fatalf("101st member: %d %v", st, out)
	}
	st, out = g.post(a, g.change(a, proto.KindAdd, proto.AddBody(false, []proto.UUID{e.randUUID()})), nil, nil)
	if st != 400 {
		t.Fatalf("unknown user: %d %v", st, out)
	}
}

// Every deve_falhar of cadeia.json against the real routes. Where a precondition of 10.1 fails
// first (author, membership, position, closed group), that answer comes instead of chain_invalid.
func TestGroupChainVectorsOverHTTP(t *testing.T) {
	var cad struct {
		Comum struct {
			Conv string `json:"conversation_id"`
		} `json:"grupo_comum"`
		Falhas []struct {
			Caso      string `json:"caso"`
			Codigo    string `json:"codigo"`
			Registros []struct {
				ChangeBytes string `json:"change_bytes"`
				Signature   string `json:"signature"`
			} `json:"registros"`
		} `json:"deve_falhar"`
	}
	testvec.Load(t, "grupos/cadeia", &cad)
	var keys struct {
		Moderador struct {
			SignPub string `json:"sign_pub"`
		} `json:"moderador"`
		Novos []struct {
			testvec.Device
			Cert struct {
				EnrolledAt uint64 `json:"enrolled_at"`
				ExpiresAt  uint64 `json:"expires_at"`
				Sig        string `json:"sig"`
			} `json:"cert"`
		} `json:"aparelhos_novos"`
	}
	testvec.Load(t, "grupos/chaves", &keys)
	preempted := map[string]string{
		"moderador_falso": "forbidden", "moderador_adiciona": "forbidden", "moderador_renomeia": "forbidden",
		"criar_acima_do_limite": "forbidden", "nao_membro_sai": "forbidden", "aparelho_sem_certificado": "forbidden",
		"n_pulado": "chain_conflict", "depois_de_encerrar": "group_closed",
	}
	for _, f := range cad.Falhas {
		t.Run(f.Caso, func(t *testing.T) {
			e := newEnv(t)
			e.setMs(1798100000000)
			e.exec(`UPDATE server_keys SET mod_pub = $1`, testvec.Hex(t, keys.Moderador.SignPub))
			byID := map[string]ed25519.PrivateKey{}
			userOf := map[string]string{}
			addUser := func(u proto.UUID, label string) {
				e.exec(`INSERT INTO users (id, admin_label, created_at) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, u, label, e.now())
			}
			addDevice := func(d testvec.Device, sig []byte, enrolled, expires uint64) {
				addUser(uid(t, d.UserID), d.AdminLabel)
				e.exec(`INSERT INTO devices (id, user_id, platform, sign_pub, kex_pub, cert_sig, enrolled_at, expires_at)
					VALUES ($1,$2,'ios',$3,$4,$5,$6,$7)`, uid(t, d.DeviceID), uid(t, d.UserID), testvec.Hex(t, d.SignPub),
					testvec.Hex(t, d.KexPub), sig, time.UnixMilli(int64(enrolled)), time.UnixMilli(int64(expires)))
				byID[d.DeviceID] = ed25519.NewKeyFromSeed(testvec.Hex(t, d.SignSeed))
				userOf[d.DeviceID] = d.UserID
			}
			for _, d := range e.ch.Aparelhos {
				c := e.certVector(d.Nome)
				addDevice(d, testvec.Hex(t, c.CertSig), c.EnrolledAt, c.ExpiresAt)
			}
			for _, d := range keys.Novos {
				sig, err := proto.B64Decode(d.Cert.Sig)
				if err != nil {
					t.Fatal(err)
				}
				addDevice(d.Device, sig, d.Cert.EnrolledAt, d.Cert.ExpiresAt)
			}

			recs := make([]proto.SignedChange, len(f.Registros))
			for i, r := range f.Registros {
				recs[i] = proto.SignedChange{Bytes: testvec.Hex(t, r.ChangeBytes), Sig: testvec.Hex(t, r.Signature)}
				// Users that the records name but have no device in the vectors.
				c, err := proto.DecodeChange(recs[i].Bytes)
				if err != nil {
					continue
				}
				if b, err := proto.ParseBody(c.Kind, c.Body); err == nil {
					for _, m := range b.Members {
						addUser(m.User, "x")
					}
					for _, u := range b.Users {
						addUser(u, "x")
					}
				}
			}
			conv := uid(t, cad.Comum.Conv)
			ctx := context.Background()
			if len(recs) > 1 { // store the valid prefix
				st := proto.NewGroupState(conv)
				if _, err := store.InsertGroup(ctx, e.pool, conv, e.now()); err != nil {
					t.Fatal(err)
				}
				for _, r := range recs[:len(recs)-1] {
					ck, err := store.ChainKeys(ctx, e.pool, []proto.SignedChange{r})
					if err != nil {
						t.Fatal(err)
					}
					if err := st.Apply(r, ck); err != nil {
						t.Fatal(err)
					}
					if err := store.AppendChange(ctx, e.pool, r, st, e.now()); err != nil {
						t.Fatal(err)
					}
				}
			}

			last := recs[len(recs)-1]
			author := e.ch.Aparelhos[0].DeviceID // A, when the record's author cannot log in
			if c, err := proto.DecodeChange(last.Bytes); err == nil && byID[proto.FormatUUID(c.AuthorDevice)] != nil {
				author = proto.FormatUUID(c.AuthorDevice)
			}
			path, body := "/v1/groups/"+cad.Comum.Conv+"/changes", map[string]any{"change": wire(last)}
			if len(recs) == 1 {
				path, body["epoch"] = "/v1/groups", map[string]any{}
			}
			st, out := e.call("POST", path, e.grant(author), body)
			want := preempted[f.Caso]
			if want == "" {
				if st != 400 || errCode(out) != "chain_invalid" || detail(out, "reason") != f.Codigo {
					t.Fatalf("%d %v, want chain_invalid %s", st, out, f.Codigo)
				}
			} else if errCode(out) != want {
				t.Fatalf("%d %v, want %s", st, out, want)
			}
			if n := e.count(`SELECT count(*) FROM group_changes`); n != len(recs)-1 {
				t.Fatalf("%d records stored, want %d", n, len(recs)-1)
			}
		})
	}
}

func TestSealedByInactiveSender(t *testing.T) {
	e := newEnv(t)
	a, b, c, d := e.newMember("Ana"), e.newMember("Bia"), e.newMember("Caio"), e.newMember("Davi")
	g := e.createGroup(a, b, c)
	_, direct := a.call("POST", "/v1/conversations", map[string]any{"kind": "direct", "peer_user_id": b.user})
	dg := &grp{e: e, id: direct["conversation_id"].(string)}

	if f := g.say(b, 1); f["type"] != "ack" {
		t.Fatalf("send: %v", f)
	}
	if f := g.say(a, 1); f["type"] != "ack" {
		t.Fatalf("send: %v", f)
	}
	// A 1:1 message of Bia: it must stay readable.
	e.exec(`INSERT INTO messages (conversation_id, seq, message_id, epoch, sender_device_id, sent_at, nonce, ciphertext, signature, created_at)
		VALUES ($1,1,$2,1,$3,1,$4,$5,$6,$7)`, uid(t, dg.id), e.randUUID(), uid(t, b.id), randb(24), randb(272), randb(64), e.now())
	st, blob := e.upload(b.token, g.id, 100)
	if st != 201 {
		t.Fatalf("upload: %d %v", st, blob)
	}
	blobPath := "/v1/blobs/" + blob["blob_id"].(string)

	history := func(conv string) []map[string]any {
		t.Helper()
		st, out := a.call("GET", "/v1/conversations/"+conv+"/messages", nil)
		if st != 200 {
			t.Fatalf("history: %d %v", st, out)
		}
		var ms []map[string]any
		for _, m := range list(out, "messages") {
			ms = append(ms, m.(map[string]any))
		}
		return ms
	}
	if h := history(g.id); len(h) != 2 || h[0]["ciphertext"] == nil || h[0]["sealed"] != nil {
		t.Fatalf("active sender: %v", h)
	}

	// One connection of every kind: all conversations, bubble of the group, outsider.
	wa, wc, wd := e.wsAuth(a.token, nil), e.wsAuth(c.token, []string{g.id}), e.wsAuth(d.token, nil)
	for _, w := range []*wsc{wa, wc, wd} {
		w.expect("ready")
	}
	e.adv(time.Minute)
	ctx := context.Background()
	revoke := func(device string) {
		t.Helper()
		tx, err := e.pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		// What "direct-admin device revoke" does.
		if err := store.RevokeDevice(ctx, tx, uid(t, device), store.RevokedByAdmin, e.now()); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	revoke(b.id)
	for _, w := range []*wsc{wa, wc} {
		f := w.expect("member_access")
		if f["user_id"] != b.user || f["active"] != false || len(list(f, "conversations")) != 1 || list(f, "conversations")[0] != g.id {
			t.Fatalf("member_access: %v", f)
		}
	}
	wd.expectNone("member_access")

	h := history(g.id)
	sealed := h[0]
	want := proto.Scramble(g.conv, 1, 272)
	if sealed["sealed"] != true || sealed["scramble"] != want || sealed["sender_user_id"] != b.user || sealed["seq"] != float64(1) {
		t.Fatalf("sealed: %v", sealed)
	}
	for _, k := range []string{"epoch", "nonce", "ciphertext", "signature", "sent_at"} {
		if _, ok := sealed[k]; ok {
			t.Fatalf("sealed message carries %s", k)
		}
	}
	if h[1]["sealed"] != nil || h[1]["ciphertext"] == nil {
		t.Fatalf("other sender sealed: %v", h[1])
	}
	if h := history(dg.id); h[0]["sealed"] != nil || h[0]["ciphertext"] == nil {
		t.Fatalf("1:1 sealed: %v", h)
	}
	st, out := a.call("GET", blobPath, nil)
	wantErr(t, "blob of inactive sender", st, out, 403, "sender_inactive")
	st, out = a.call("POST", "/v1/media/saves", map[string]any{"conversation_id": g.id, "seq": 1})
	wantErr(t, "save of inactive sender", st, out, 403, "sender_inactive")

	// Back with a new device of the same user.
	b.another()
	if f := wa.expect("member_access"); f["active"] != true || f["user_id"] != b.user {
		t.Fatalf("back: %v", f)
	}
	if h := history(g.id); h[0]["sealed"] != nil || h[0]["ciphertext"] == nil {
		t.Fatalf("still sealed: %v", h[0])
	}
	if st, _, _ := e.raw("GET", blobPath, a.token, nil); st != 200 {
		t.Fatalf("blob after return: %d", st)
	}

	// Expiry is found by the sweep, once. Disabling a user records it too.
	e.exec(`UPDATE devices SET expires_at = $2 WHERE id = $1`, uid(t, c.id), e.now())
	e.adv(time.Second)
	for range 2 {
		if err := e.srv.SweepAccess(ctx); err != nil {
			t.Fatal(err)
		}
	}
	tx, err := e.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.DisableUser(ctx, tx, uid(t, d.user), e.now()); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if n := e.count(`SELECT count(*) FROM user_access_events WHERE NOT active AND user_id = ANY($1)`,
		[]proto.UUID{uid(t, c.user), uid(t, d.user)}); n != 2 {
		t.Fatalf("expiry and disable events: %d", n)
	}

	// The lines of the group: members only (Davi is not one).
	st, ev := a.call("GET", "/v1/conversations/"+g.id+"/access-events", nil)
	got := list(ev, "events")
	if st != 200 || len(got) != 3 || ev["has_more"] != false {
		t.Fatalf("access-events: %d %v", st, ev)
	}
	for i, want := range []struct {
		user   string
		active bool
	}{{b.user, false}, {b.user, true}, {c.user, false}} {
		if m := got[i].(map[string]any); m["user_id"] != want.user || m["active"] != want.active {
			t.Fatalf("event %d: %v", i, m)
		}
	}
	after := int(got[1].(map[string]any)["id"].(float64))
	if _, ev := a.call("GET", "/v1/conversations/"+g.id+"/access-events?after="+itoa(int64(after)), nil); len(list(ev, "events")) != 1 {
		t.Fatalf("after: %v", ev)
	}
	st, out = a.call("GET", "/v1/conversations/"+dg.id+"/access-events", nil)
	wantErr(t, "access-events of 1:1", st, out, 400, "bad_request")

	// before: the newest below it, ascending.
	_, page := a.call("GET", "/v1/conversations/"+g.id+"/messages?before=3&limit=1", nil)
	if l := list(page, "messages"); len(l) != 1 || l[0].(map[string]any)["seq"] != float64(2) || page["has_more"] != true {
		t.Fatalf("before: %v", page)
	}
	_, page = a.call("GET", "/v1/conversations/"+g.id+"/messages?before=3", nil)
	if l := list(page, "messages"); len(l) != 2 || l[0].(map[string]any)["seq"] != float64(1) || page["has_more"] != false {
		t.Fatalf("before all: %v", page)
	}
}

func TestSelfRevoke(t *testing.T) {
	e := newEnv(t)
	var v struct {
		Req    proto.SelfRevokeRequest `json:"requisicao"`
		Falhas []struct {
			Caso string                  `json:"caso"`
			Req  proto.SelfRevokeRequest `json:"requisicao"`
		} `json:"deve_falhar"`
	}
	testvec.Load(t, "grupos/revogacao", &v)
	e.setMs(int64(v.Req.CreatedAt))
	a := e.device("A")
	insert := func(name string) {
		d, c := e.device(name), e.certVector(name)
		e.exec(`INSERT INTO users (id, admin_label, created_at) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, uid(t, d.UserID), d.AdminLabel, e.now())
		e.exec(`INSERT INTO devices (id, user_id, platform, sign_pub, kex_pub, cert_sig, enrolled_at, expires_at)
			VALUES ($1,$2,'ios',$3,$4,$5,$6,$7)`, uid(t, d.DeviceID), uid(t, d.UserID), testvec.Hex(t, d.SignPub),
			testvec.Hex(t, d.KexPub), testvec.Hex(t, c.CertSig), e.now(), e.now().Add(1000*time.Hour))
	}
	insert("A")
	insert("B")
	send := func(req proto.SelfRevokeRequest) (int, map[string]any) {
		e.adv(time.Minute) // rate limit
		return e.call("POST", "/v1/devices/self-revoke", "", req)
	}
	for _, f := range v.Falhas {
		st, out := send(f.Req)
		if (st != 400 || errCode(out) != "bad_request") && (st != 401 || errCode(out) != "auth_failed") {
			t.Fatalf("%s: %d %v", f.Caso, st, out)
		}
	}
	unknown := v.Req
	unknown.DeviceID = e.randUUIDString()
	st, out := send(unknown)
	wantErr(t, "unknown device", st, out, 401, "auth_failed")
	if e.count(`SELECT count(*) FROM devices WHERE revoked_at IS NOT NULL`) != 0 {
		t.Fatal("invalid request revoked")
	}

	token := e.grant(a.DeviceID)
	ws := e.wsAuth(token, nil)
	ws.expect("ready")
	st, first := send(v.Req)
	if st != 200 || first["revoked_at"] == nil {
		t.Fatalf("self-revoke: %d %v", st, first)
	}
	ws.expectClose(4003)
	if st, _ := e.call("GET", "/v1/directory", token, nil); st != 401 {
		t.Fatal("token survived")
	}
	if e.count(`SELECT count(*) FROM devices WHERE id = $1 AND revoked_reason = 'self' AND revoke_signed_at = $2`,
		uid(t, a.DeviceID), int64(v.Req.CreatedAt)) != 1 {
		t.Fatal("audit columns")
	}
	// Replay: same answer, nothing changes.
	events := e.count(`SELECT count(*) FROM user_access_events`)
	st, again := send(v.Req)
	if st != 200 || again["revoked_at"] != first["revoked_at"] || e.count(`SELECT count(*) FROM user_access_events`) != events || events != 1 {
		t.Fatalf("replay: %d %v (events %d)", st, again, events)
	}
	// The replay touches no other device.
	if e.count(`SELECT count(*) FROM devices WHERE revoked_at IS NULL`) != 1 {
		t.Fatal("other device revoked")
	}
	// Rate limit per IP.
	e.adv(time.Minute)
	for i := range 6 {
		st, _ = e.call("POST", "/v1/devices/self-revoke", "", v.Req)
		if want := map[bool]int{true: 429, false: 200}[i == 5]; st != want {
			t.Fatalf("request %d: %d", i, st)
		}
	}
}

func TestDeviceLimitAndModPub(t *testing.T) {
	e := newEnv(t)
	if _, info := e.call("GET", "/v1/server-info", "", nil); info["mod_pub"] != nil {
		t.Fatalf("mod_pub before register: %v", info)
	}
	pub := randb(32)
	e.exec(`UPDATE server_keys SET mod_pub = $1`, pub)
	if _, info := e.call("GET", "/v1/server-info", "", nil); info["mod_pub"] != proto.B64Encode(pub) {
		t.Fatalf("mod_pub: %v", info)
	}
	a := e.newMember("Ana")
	for range 3 {
		a.another()
	}
	seed := e.invite(&a.user, a.label)
	m, st, out := e.enrollWith(seed)
	if m != nil {
		t.Fatal("fifth device accepted")
	}
	wantErr(t, "fifth device", st, out, 409, "device_limit")
	if e.count(`SELECT count(*) FROM enrollment_tokens WHERE used_at IS NULL`) != 1 {
		t.Fatal("refused enrollment spent the invite")
	}
	e.exec(`UPDATE devices SET revoked_at = $2 WHERE id = $1`, uid(t, a.id), e.now())
	if m, st, out := e.enrollWith(seed); m == nil {
		t.Fatalf("after revoking one: %d %v", st, out)
	}
}
