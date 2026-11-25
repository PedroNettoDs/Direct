package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/url"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
	"golang.org/x/crypto/nacl/box"
	"rsc.io/qr"
)

// enrollURI enrolls a new device with the invite of a QR text.
func (e *env) enrollURI(uri string) (*phone, int, map[string]any) {
	e.t.Helper()
	u, err := url.Parse(uri)
	must(e.t, err)
	dec := func(k string) []byte {
		b, err := proto.B64Fixed(u.Query().Get(k), 32)
		must(e.t, err)
		return b
	}
	p := &phone{serverPub: dec("s"), escrow: dec("e")}
	invite := ed25519.NewKeyFromSeed(dec("t"))
	invitePub := invite.Public().(ed25519.PublicKey)
	signPub, sign, _ := ed25519.GenerateKey(nil)
	kexPub, kexSK, _ := box.GenerateKey(bytes.NewReader(random(32)))
	p.sign, p.kexPub, p.kexSK = sign, *kexPub, *kexSK
	eb := proto.EnrollBytes(invitePub, signPub, kexPub[:])
	st, res := e.call("POST", "/v1/enroll", "", map[string]any{
		"invite_pub": proto.B64Encode(invitePub), "sign_pub": proto.B64Encode(signPub), "kex_pub": proto.B64Encode(kexPub[:]),
		"platform": "android", "model": "m", "os_version": "15", "app_version": "1.0.0",
		"invite_sig": proto.B64Encode(ed25519.Sign(invite, eb)), "proof": proto.B64Encode(ed25519.Sign(sign, eb))})
	if st != 200 {
		return nil, st, res
	}
	cert := res["cert"].(map[string]any)
	p.id, p.user = cert["device_id"].(string), cert["user_id"].(string)
	if st, out := e.login(p); st == 200 {
		p.token = out["access_token"].(string)
	}
	return p, st, res
}

// clientChain follows a group as the app does.
type clientChain struct {
	e  *env
	st *proto.GroupState
}

func (c *clientChain) id() string { return proto.FormatUUID(c.st.Conv) }

func (c *clientChain) sync() {
	c.e.t.Helper()
	chain, err := store.LoadChain(context.Background(), c.e.pool, c.st.Conv)
	must(c.e.t, err)
	c.st = chain.State
}

// epoch builds a group epoch with a real key, returned so the test can compare the wraps.
func (c *clientChain) epoch(creator *phone, n uint32, chainN uint64, head [32]byte, to ...*phone) (map[string]any, []byte) {
	c.e.t.Helper()
	k := random(32)
	commit := proto.EpochKeyCommitment(c.st.Conv, n, k)
	seal := func(pub *[32]byte) string {
		w, err := box.SealAnonymous(nil, k, pub, bytes.NewReader(random(32)))
		must(c.e.t, err)
		return proto.B64Encode(w)
	}
	slices.SortFunc(to, func(a, b *phone) int { return strings.Compare(a.id, b.id) })
	var ids []proto.UUID
	var recips []string
	var wraps []map[string]string
	for _, p := range to {
		ids = append(ids, id(c.e.t, p.id))
		recips = append(recips, p.id)
		wraps = append(wraps, map[string]string{"device_id": p.id, "wrapped_key": seal(&p.kexPub)})
	}
	var esc [32]byte
	copy(esc[:], creator.escrow)
	sig := ed25519.Sign(creator.sign, proto.GroupEpochBytes(c.st.Conv, n, id(c.e.t, creator.id), commit[:], creator.escrow, chainN, head, ids))
	return map[string]any{"epoch": n, "creator_device_id": creator.id, "key_commitment": proto.B64Encode(commit[:]),
		"chain_n": chainN, "chain_hash": proto.B64Encode(head[:]), "recipients": recips, "wraps": wraps,
		"escrow_wrap": seal(&esc), "signature": proto.B64Encode(sig)}, k
}

func meta(epoch uint32, commit [32]byte) map[string]any {
	return map[string]any{"epoch": epoch, "meta_commit": proto.B64Encode(commit[:]),
		"nonce": proto.B64Encode(random(24)), "ciphertext": proto.B64Encode(random(272))}
}

func (c *clientChain) record(p *phone, kind uint32, body []byte) proto.SignedChange {
	return proto.SignChange(proto.GroupChange{Conv: c.st.Conv, N: c.st.N + 1, Prev: c.st.Head, Kind: kind,
		AuthorType: proto.AuthorDevice, AuthorDevice: id(c.e.t, p.id), AuthorUser: id(c.e.t, p.user), Body: body}, p.sign)
}

func wireRec(r proto.SignedChange) map[string]any {
	return map[string]any{"change_bytes": proto.B64Encode(r.Bytes), "signature": proto.B64Encode(r.Sig)}
}

// newGroup creates a group from admin's app with the other users; epoch 1 goes to "to".
func (e *env) newGroup(admin *phone, to ...*phone) (*clientChain, []byte) {
	e.t.Helper()
	conv, err := newUUID()
	must(e.t, err)
	c := &clientChain{e: e, st: proto.NewGroupState(conv)}
	list := []proto.GroupMember{{User: id(e.t, admin.user), Role: proto.RoleAdmin}}
	for _, p := range to {
		list = append(list, proto.GroupMember{User: id(e.t, p.user), Role: proto.RoleMember})
	}
	slices.SortFunc(list, func(a, b proto.GroupMember) int { return slices.Compare(a.User[:], b.User[:]) })
	commit := [32]byte{7}
	rec := c.record(admin, proto.KindCreate, proto.CreateBody("", commit, list))
	ep, k := c.epoch(admin, 1, 1, proto.ChangeHash(rec), append([]*phone{admin}, to...)...)
	st, res := e.call("POST", "/v1/groups", admin.token, map[string]any{"change": wireRec(rec), "epoch": ep, "meta": meta(1, commit)})
	if st != 201 {
		e.t.Fatalf("group: %d %v", st, res)
	}
	c.sync()
	return c, k
}

// change appends an add or remove record together with its epoch.
func (c *clientChain) change(admin *phone, kind uint32, body []byte, n uint32, to ...*phone) []byte {
	c.e.t.Helper()
	rec := c.record(admin, kind, body)
	ep, k := c.epoch(admin, n, c.st.N+1, proto.ChangeHash(rec), to...)
	st, res := c.e.call("POST", "/v1/groups/"+c.id()+"/changes", admin.token,
		map[string]any{"change": wireRec(rec), "epoch": ep, "meta": meta(n, c.st.MetaCommit)})
	if st != 201 {
		c.e.t.Fatalf("change %d: %d %v", kind, st, res)
	}
	c.sync()
	return k
}

// keys opens every epoch key of the conversation that the device was given.
func (e *env) keys(conv string, p *phone) map[uint32][]byte {
	e.t.Helper()
	st, res := e.call("GET", "/v1/conversations/"+conv+"/epochs/mine", p.token, nil)
	if st != 200 {
		e.t.Fatalf("epochs: %d %v", st, res)
	}
	out := map[uint32][]byte{}
	for _, raw := range res["items"].([]any) {
		it := raw.(map[string]any)
		w, _ := proto.B64Decode(it["wrapped_key"].(string))
		k, ok := box.OpenAnonymous(nil, w, &p.kexPub, &p.kexSK)
		if !ok {
			e.t.Fatal("wrap does not open")
		}
		out[uint32(it["epoch"].(float64))] = k
	}
	return out
}

func sameKeys(t *testing.T, got map[uint32][]byte, want map[uint32][]byte) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%d keys, want %d", len(got), len(want))
	}
	for n, k := range want {
		if !bytes.Equal(got[n], k) {
			t.Fatalf("epoch %d: wrong key", n)
		}
	}
}

// Groups are rewrapped only as far as the signed chain permits (protocolo-grupos 5.4).
func TestRewrapGroups(t *testing.T) {
	e := newEnv(t)
	keyFile := filepath.Join(t.TempDir(), "escrow.key")
	e.mustCLI("escrow", "init", "--out", keyFile)
	ana := e.enroll("Pixel 7", "--new-user", "Ana - Compras")
	bia := e.enroll("Pixel 8", "--new-user", "Bia - Financeiro")
	caio := e.enroll("Pixel 9", "--new-user", "Caio - TI")
	g, k1 := e.newGroup(ana, bia)
	k2 := g.change(ana, proto.KindAdd, proto.AddBody(false, []proto.UUID{id(t, caio.user)}), 2, ana, bia, caio)
	e.mustCLI("device", "revoke", caio.id)
	// Epoch 3 is created while Caio has no device.
	ep, k3 := g.epoch(ana, 3, g.st.N, g.st.Head, ana, bia)
	ep["meta"] = meta(3, g.st.MetaCommit)
	if st, res := e.call("POST", "/v1/conversations/"+g.id()+"/epochs", ana.token, ep); st != 201 {
		t.Fatalf("epoch 3: %d %v", st, res)
	}
	caio2 := e.enroll("Pixel 10", "--user", caio.user)

	rewrap := func(device string) string {
		t.Helper()
		return e.mustCLI("escrow", "rewrap", "--device", device, "--key", keyFile)
	}
	out := rewrap(caio2.id)
	for _, want := range []string{"Grupo " + g.id(), "registro 2: entrou em", "adicionado por Ana - Compras", "sem histórico: épocas 2 a 3",
		"Épocas de grupo fora (a cadeia não permite): 1", "reembrulhadas: 2", "Com falha: 0"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q:\n%s", want, out)
		}
	}
	sameKeys(t, e.keys(g.id(), caio2), map[uint32][]byte{2: k2, 3: k3})
	var n int
	must(t, e.pool.QueryRow(context.Background(), `SELECT count(*) FROM epoch_key_wraps WHERE source = 'escrow' AND recipient_device_id = $1`,
		id(t, caio2.id)).Scan(&n))
	if n != 2 {
		t.Fatalf("escrow wraps: %d", n)
	}

	// Removed: nothing, not even the epochs of the time as member.
	k4 := g.change(ana, proto.KindRemove, proto.UsersBody([]proto.UUID{id(t, caio.user)}), 4, ana, bia)
	e.pool.Exec(context.Background(), `DELETE FROM epoch_key_wraps WHERE recipient_device_id = $1`, id(t, caio2.id))
	if out := rewrap(caio2.id); !strings.Contains(out, "reembrulhadas: 0") || strings.Contains(out, "Grupo "+g.id()) {
		t.Fatalf("removed member:\n%s", out)
	}

	// Whoever rewrites the database to hide the removal: later epochs point past the chain.
	e.hideLast(g)
	out = rewrap(caio2.id)
	if !strings.Contains(out, "não está na cadeia") || !strings.Contains(out, "reembrulhadas: 0") {
		t.Fatalf("cut chain:\n%s", out)
	}
	e.restoreLast()

	// Added again with the history released: everything, including the epoch of the absence.
	k5 := g.change(ana, proto.KindAdd, proto.AddBody(true, []proto.UUID{id(t, caio.user)}), 5, ana, bia, caio2)
	out = rewrap(caio2.id)
	for _, want := range []string{"com histórico (anteriores à entrada, liberadas): épocas 1, 4", "reembrulhadas: 4", "Com falha: 0"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q:\n%s", want, out)
		}
	}
	sameKeys(t, e.keys(g.id(), caio2), map[uint32][]byte{1: k1, 2: k2, 3: k3, 4: k4, 5: k5})

	// A signature that does not cover the stored row is reported and skipped.
	e.pool.Exec(context.Background(), `DELETE FROM epoch_key_wraps WHERE recipient_device_id = $1 AND epoch < 3`, id(t, caio2.id))
	e.pool.Exec(context.Background(), `UPDATE epochs SET key_commitment = $2 WHERE conversation_id = $1 AND epoch = 1`, g.st.Conv, random(32))
	out = rewrap(caio2.id)
	if !strings.Contains(out, "época 1: assinatura do criador não confere") || !strings.Contains(out, "reembrulhadas: 1") {
		t.Fatalf("tampered epoch:\n%s", out)
	}

	// Not confirming writes nothing.
	e.pool.Exec(context.Background(), `DELETE FROM epoch_key_wraps WHERE recipient_device_id = $1`, id(t, caio2.id))
	e.answers = []string{"sim", "não"}
	if _, err := e.cli("escrow", "rewrap", "--device", caio2.id, "--key", keyFile); err == nil {
		t.Fatal("rewrap without confirmation")
	}
	if len(e.keys(g.id(), caio2)) != 0 {
		t.Fatal("wrapped without confirmation")
	}
}

// hideLast removes the last record and points the conversation at the previous one.
func (e *env) hideLast(g *clientChain) {
	e.t.Helper()
	ctx := context.Background()
	for _, sql := range []string{
		`CREATE TABLE hidden AS SELECT g.*, c.chain_hash AS head FROM group_changes g JOIN conversations c ON c.id = g.conversation_id
			WHERE g.n = c.chain_n`,
		`DELETE FROM group_changes g USING hidden h WHERE g.conversation_id = h.conversation_id AND g.n = h.n`,
		`UPDATE conversations c SET chain_n = h.n - 1, chain_hash = p.record_hash FROM hidden h, group_changes p
			WHERE c.id = h.conversation_id AND p.conversation_id = h.conversation_id AND p.n = h.n - 1`,
		`UPDATE conversation_members m SET left_at = NULL, left_n = NULL FROM hidden h
			WHERE m.conversation_id = h.conversation_id AND m.left_n = h.n`,
	} {
		_, err := e.pool.Exec(ctx, sql)
		must(e.t, err)
	}
}

func (e *env) restoreLast() {
	e.t.Helper()
	ctx := context.Background()
	for _, sql := range []string{
		`UPDATE conversation_members m SET left_at = now(), left_n = h.n FROM hidden h
			WHERE m.conversation_id = h.conversation_id AND m.left_at IS NULL
			AND m.user_id = (SELECT u.id FROM users u WHERE u.admin_label = 'Caio - TI')`,
		`INSERT INTO group_changes SELECT conversation_id, n, change_bytes, signature, record_hash, kind, author_device_id,
			author_user_id, received_at FROM hidden`,
		`UPDATE conversations c SET chain_n = h.n, chain_hash = h.head FROM hidden h WHERE c.id = h.conversation_id`,
		`DROP TABLE hidden`,
	} {
		_, err := e.pool.Exec(ctx, sql)
		must(e.t, err)
	}
}

// listen opens a WebSocket and returns the types of the frames that arrive.
func (e *env) listen(token string) func(string) map[string]any {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	e.t.Cleanup(cancel)
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(e.url, "http")+"/v1/ws", nil)
	must(e.t, err)
	e.t.Cleanup(func() { c.CloseNow() })
	b, _ := json.Marshal(map[string]any{"type": "auth", "access_token": token})
	must(e.t, c.Write(ctx, websocket.MessageText, b))
	expect := func(typ string) map[string]any {
		e.t.Helper()
		for {
			_, b, err := c.Read(ctx)
			if err != nil {
				e.t.Fatalf("waiting for %s: %v", typ, err)
			}
			var f map[string]any
			must(e.t, json.Unmarshal(b, &f))
			if f["type"] == typ {
				return f
			}
		}
	}
	expect("ready")
	return expect
}

func TestModeratorGroups(t *testing.T) {
	e := newEnv(t)
	dir := t.TempDir()
	escrowFile, modFile := filepath.Join(dir, "escrow.key"), filepath.Join(dir, "moderador.key")
	e.mustCLI("escrow", "init", "--out", escrowFile)
	ana := e.enroll("Pixel 7", "--new-user", "Ana - Compras")
	bia := e.enroll("Pixel 8", "--new-user", "Bia - Financeiro")

	create := []string{"group", "create", "--label", "Diretoria - oficial", "--admin", ana.user, "--member", bia.user, "--mod-key", modFile}
	out := e.mustCLI("moderator", "init", "--out", modFile)
	modPub := strings.Fields(out[strings.Index(out, "mod_sign_pub:"):])[1]
	if _, err := e.cli(create...); err == nil {
		t.Fatal("group before moderator register")
	}
	if _, err := e.cli("moderator", "register", "--pub", "curta"); err == nil {
		t.Fatal("bad pub")
	}
	e.mustCLI("moderator", "register", "--pub", modPub)
	if _, err := e.cli("moderator", "register", "--pub", modPub); err == nil {
		t.Fatal("moderator key replaced")
	}
	if _, info := e.call("GET", "/v1/server-info", "", nil); info["mod_pub"] != modPub {
		t.Fatalf("server-info: %v", info)
	}

	// New invites are v=2; the pin QR and the code cover the moderator key.
	mod, _ := proto.B64Decode(modPub)
	invite := e.mustCLI("token", "create", "--user", ana.user)
	q, err := url.Parse(inviteRE.FindString(invite))
	must(t, err)
	code := proto.ServerCodeMod(ana.serverPub, ana.escrow, mod)
	if q.Query().Get("v") != "2" || q.Query().Get("m") != modPub || !strings.Contains(invite, code) {
		t.Fatalf("v=2 invite:\n%s", invite)
	}
	pin := proto.PinURI("direct.exemplo.com.br", ana.serverPub, ana.escrow, mod)
	_, err = qr.Encode(pin, qr.M)
	must(t, err)
	if out := e.mustCLI("moderator", "qr"); !strings.Contains(out, pin) || !strings.Contains(out, code) {
		t.Fatalf("moderator qr:\n%s", out)
	}

	// Wrong password, wrong key file, unknown user: nothing is written.
	e.password = "outra senha qualquer bem longa"
	if _, err := e.cli(create...); err == nil {
		t.Fatal("wrong password")
	}
	e.password = password
	if _, err := e.cli(append(create[:len(create)-1:len(create)-1], escrowFile)...); err == nil {
		t.Fatal("escrow key accepted as moderator key")
	}
	other := filepath.Join(dir, "outra.key")
	e.mustCLI("moderator", "init", "--out", other)
	if _, err := e.cli(append(create[:len(create)-1:len(create)-1], other)...); err == nil {
		t.Fatal("unregistered moderator key")
	}
	if _, err := e.cli("group", "create", "--label", "x", "--admin", ana.user, "--member", ana.user, "--mod-key", modFile); err == nil {
		t.Fatal("repeated user")
	}
	if _, err := e.cli("group", "create", "--label", "x", "--member", ana.user, "--mod-key", modFile); err == nil {
		t.Fatal("group without admin")
	}
	if out := e.mustCLI("group", "list"); strings.Contains(out, "Diretoria") {
		t.Fatalf("group left behind:\n%s", out)
	}

	// directd learns about the CLI's records by NOTIFY.
	anaWS, biaWS := e.listen(ana.token), e.listen(bia.token)
	out = e.mustCLI(create...)
	conv := strings.Fields(out[strings.Index(out, "Grupo criado:")+len("Grupo criado:"):])[0]
	cv := biaWS("conversation")["conversation"].(map[string]any)
	if cv["conversation_id"] != conv || cv["admin_label"] != "Diretoria - oficial" || cv["chain_n"] != float64(1) {
		t.Fatalf("conversation: %v", cv)
	}
	if f := anaWS("group_change"); f["conversation_id"] != conv || f["meta"] != nil {
		t.Fatalf("group_change: %v", f)
	}
	if out := e.mustCLI("group", "list"); !strings.Contains(out, conv) || !strings.Contains(out, "Diretoria - oficial") || !strings.Contains(out, "Ana - Compras") {
		t.Fatalf("group list:\n%s", out)
	}

	// The first member to send creates epoch 1: no meta, the group has no name yet.
	g := &clientChain{e: e, st: proto.NewGroupState(id(t, conv))}
	g.sync()
	ep, _ := g.epoch(ana, 1, 1, g.st.Head, ana, bia)
	if st, res := e.call("POST", "/v1/conversations/"+conv+"/epochs", ana.token, ep); st != 201 {
		t.Fatalf("epoch: %d %v", st, res)
	}

	if _, err := e.cli("group", "remove-member", conv, "00000000-0000-4000-8000-000000000000", "--mod-key", modFile); err == nil {
		t.Fatal("removed a non-member")
	}
	e.mustCLI("group", "remove-member", conv, bia.user, "--mod-key", modFile)
	if f := biaWS("group_change"); f["change"].(map[string]any)["n"] == float64(1) {
		biaWS("group_change")
	}
	if st, _ := e.call("GET", "/v1/groups/"+conv+"/changes", bia.token, nil); st != 403 {
		t.Fatalf("removed member: %d", st)
	}
	out = e.mustCLI("group", "show", conv)
	for _, want := range []string{"1 · criar · ", "Ana - Compras (admin)", "2 · remover · Bia - Financeiro pelo moderador"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "NÃO confere") {
		t.Fatalf("good chain reported bad:\n%s", out)
	}

	// A tampered record: show says so and nothing is signed on top of it.
	var sig []byte
	ctx := context.Background()
	must(t, e.pool.QueryRow(ctx, `SELECT signature FROM group_changes WHERE n = 2`).Scan(&sig))
	_, err = e.pool.Exec(ctx, `UPDATE group_changes SET signature = $1 WHERE n = 2`, random(64))
	must(t, err)
	if out := e.mustCLI("group", "show", conv); !strings.Contains(out, "NÃO confere") {
		t.Fatalf("tampered chain:\n%s", out)
	}
	if _, err := e.cli("group", "close", conv, "--mod-key", modFile); err == nil || !strings.Contains(err.Error(), "não assino") {
		t.Fatalf("signed over a bad chain: %v", err)
	}
	_, err = e.pool.Exec(ctx, `UPDATE group_changes SET signature = $1 WHERE n = 2`, sig)
	must(t, err)

	e.mustCLI("group", "close", conv, "--mod-key", modFile)
	if _, err := e.cli("group", "close", conv, "--mod-key", modFile); err == nil {
		t.Fatal("closed twice")
	}
	if out := e.mustCLI("group", "show", conv); !strings.Contains(out, "3 · encerrar pelo moderador") {
		t.Fatalf("close:\n%s", out)
	}
}

func TestTokenReactivate(t *testing.T) {
	e := newEnv(t)
	e.mustCLI("escrow", "init", "--out", filepath.Join(t.TempDir(), "escrow.key"))
	created := e.mustCLI("token", "create", "--new-user", "Ana - Compras")
	uri := inviteRE.FindString(created)
	tokenID := strings.Fields(created)[1]
	reactivate := func(id string, ttl ...string) (string, error) {
		return e.cli(append([]string{"token", "reactivate", id}, ttl...)...)
	}
	if _, err := reactivate(tokenID, "--ttl", "24h"); err == nil {
		t.Fatal("pending invite reactivated")
	}
	ana, st, res := e.enrollURI(uri)
	if ana == nil {
		t.Fatalf("enroll: %d %v", st, res)
	}
	for _, bad := range [][]string{nil, {"--ttl", "30s"}, {"--ttl", "8d"}} {
		if _, err := reactivate(tokenID, bad...); err == nil {
			t.Fatalf("ttl %v accepted", bad)
		}
	}
	e.mustCLI("device", "revoke", ana.id)
	out, err := reactivate(tokenID, "--ttl", "24h")
	must(t, err)
	if !strings.Contains(out, "não há como reimprimir o QR") || inviteRE.MatchString(out) {
		t.Fatalf("reactivate:\n%s", out)
	}
	// Same QR, same user, new device; still single use.
	ana2, st, res := e.enrollURI(uri)
	if ana2 == nil || ana2.user != ana.user || ana2.id == ana.id || res["new_user"] != false {
		t.Fatalf("enroll again: %d %v", st, res)
	}
	if _, st, _ := e.enrollURI(uri); st != 401 {
		t.Fatalf("reused: %d", st)
	}
	var n, reactivations int
	ctx := context.Background()
	must(t, e.pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&n))
	must(t, e.pool.QueryRow(ctx, `SELECT reactivations FROM enrollment_tokens WHERE id = $1`, id(t, tokenID)).Scan(&reactivations))
	if n != 1 || reactivations != 1 {
		t.Fatalf("users %d, reactivations %d", n, reactivations)
	}

	// A new-user invite that expired without use would create a user: refused.
	unused := strings.Fields(e.mustCLI("token", "create", "--new-user", "Bia"))[1]
	_, err = e.pool.Exec(ctx, `UPDATE enrollment_tokens SET expires_at = now() - interval '1 hour' WHERE id = $1`, id(t, unused))
	must(t, err)
	if _, err := reactivate(unused, "--ttl", "1h"); err == nil {
		t.Fatal("unused new-user invite reactivated")
	}
	revoked := strings.Fields(e.mustCLI("token", "create", "--user", ana.user))[1]
	e.mustCLI("token", "revoke", revoked)
	if _, err := reactivate(revoked, "--ttl", "1h"); err == nil || !strings.Contains(err.Error(), "revogado") {
		t.Fatalf("revoked invite reactivated: %v", err)
	}
	e.mustCLI("user", "disable", ana.user)
	if _, err := reactivate(tokenID, "--ttl", "1h"); err == nil {
		t.Fatal("invite of a disabled user reactivated")
	}
}
