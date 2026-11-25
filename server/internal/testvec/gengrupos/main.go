// Gerador dos vetores de grupos (docs/protocolo-grupos.md), saída em docs/vetores/grupos/.
//
// Uso, a partir de server/:
//
//	go run ./internal/testvec/gengrupos ../docs/vetores
//
// Lê chaves.json e cadastro.json da pasta dada (aparelhos A, B e C, chaves do servidor e do
// escrow) e escreve <pasta>/grupos/*.json. Todas as entradas são fixas (sementes derivadas de
// nomes com BLAKE2b-256, como no gerador da v1), então a saída é igual a cada execução.
// O teste deste pacote regenera em memória e compara com os arquivos.
package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/testvec"
	"golang.org/x/crypto/blake2b"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "uso: gengrupos <docs/vetores>")
		os.Exit(2)
	}
	files, err := generate(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	out := filepath.Join(os.Args[1], "grupos")
	if err := os.MkdirAll(out, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		if err := os.WriteFile(filepath.Join(out, n), files[n], 0o644); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("escrito", filepath.Join(out, n))
	}
}

// ---------- JSON com ordem de campos preservada ----------

type kv struct {
	K string
	V any
}

// O é um objeto JSON que mantém a ordem dos campos.
type O []kv

func (o O) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, e := range o {
		if i > 0 {
			buf.WriteByte(',')
		}
		k, err := enc(e.K)
		if err != nil {
			return nil, err
		}
		buf.Write(k)
		buf.WriteByte(':')
		v, err := enc(e.V)
		if err != nil {
			return nil, err
		}
		buf.Write(v)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

func enc(v any) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

func render(v any) []byte {
	b, err := enc(v)
	must(err)
	var out bytes.Buffer
	must(json.Indent(&out, b, "", "  "))
	out.WriteByte('\n')
	return out.Bytes()
}

// ---------- utilidades ----------

type genErr struct{ error }

func must(err error) {
	if err != nil {
		panic(genErr{err})
	}
}

func check(ok bool, what string) {
	if !ok {
		panic(genErr{fmt.Errorf("conferência falhou: %s", what)})
	}
}

func hx(b []byte) string  { return hex.EncodeToString(b) }
func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func seed(name string) []byte {
	h := blake2b.Sum256([]byte("direct/test-vector/" + name))
	return h[:]
}

func unhex(s string) []byte {
	b, err := hex.DecodeString(s)
	must(err)
	return b
}

func uid(s string) proto.UUID {
	u, err := proto.ParseUUID(s)
	must(err)
	return u
}

func x25519Pub(sk []byte) []byte {
	p, err := curve25519.X25519(sk, curve25519.Basepoint)
	must(err)
	return p
}

func seal(msg, pub, eph []byte) []byte {
	var pk [32]byte
	copy(pk[:], pub)
	out, err := box.SealAnonymous(nil, msg, &pk, bytes.NewReader(eph))
	must(err)
	return out
}

func open(ct, pub, sk []byte) ([]byte, bool) {
	var pk, s [32]byte
	copy(pk[:], pub)
	copy(s[:], sk)
	return box.OpenAnonymous(nil, ct, &pk, &s)
}

func loadJSON(dir, name string, v any) {
	b, err := os.ReadFile(filepath.Join(dir, name))
	must(err)
	must(json.Unmarshal(b, v))
}

// ---------- aparelhos ----------

type device struct {
	nome, label string
	id, user    proto.UUID
	sign        ed25519.PrivateKey
	kexSK       []byte
	kexPub      []byte
	cert        proto.SignedCert
}

func (d *device) signPub() []byte { return d.sign.Public().(ed25519.PublicKey) }

type world struct {
	serverKey ed25519.PrivateKey
	serverPub []byte
	escrowSK  []byte
	escrowPub []byte
	modKey    ed25519.PrivateKey
	modPub    []byte
	dev       map[string]*device
	keys      proto.ChainKeys
}

func (w *world) user(nome string) proto.UUID { return w.dev[nome].user }

func newWorld(base string) *world {
	var ch testvec.Chaves
	var cad testvec.Cadastro
	loadJSON(base, "chaves.json", &ch)
	loadJSON(base, "cadastro.json", &cad)

	w := &world{dev: map[string]*device{}}
	w.serverKey = ed25519.NewKeyFromSeed(unhex(ch.Servidor.SignSeed))
	w.serverPub = w.serverKey.Public().(ed25519.PublicKey)
	check(hx(w.serverPub) == ch.Servidor.SignPub, "chave do servidor")
	w.escrowSK = unhex(ch.Escrow.KexSK)
	w.escrowPub = unhex(ch.Escrow.KexPub)
	w.modKey = ed25519.NewKeyFromSeed(seed("grupos/moderador"))
	w.modPub = w.modKey.Public().(ed25519.PublicKey)

	certs := map[string]testvec.Cert{}
	for _, c := range cad.Certs {
		certs[c.Aparelho] = c
	}
	for _, a := range ch.Aparelhos {
		c := certs[a.Nome]
		d := &device{nome: a.Nome, label: a.AdminLabel, id: uid(a.DeviceID), user: uid(a.UserID),
			sign: ed25519.NewKeyFromSeed(unhex(a.SignSeed)), kexSK: unhex(a.KexSK), kexPub: unhex(a.KexPub)}
		d.cert = proto.SignedCert{Cert: proto.Cert{DeviceID: d.id, UserID: d.user, SignPub: d.signPub(),
			KexPub: d.kexPub, EnrolledAt: c.EnrolledAt, ExpiresAt: c.ExpiresAt, AdminLabel: d.label},
			Sig: unhex(c.CertSig)}
		check(proto.Verify(w.serverPub, proto.CertBytes(d.cert.Cert), d.cert.Sig), "certificado "+a.Nome)
		w.dev[a.Nome] = d
	}
	// Aparelhos novos só dos vetores de grupo.
	for _, n := range []struct{ nome, id, user, label string }{
		{"D", "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f", "Marcos Lima - TI"},
		{"E", "6f5e4d3c-2b1a-4098-a7b6-c5d4e3f2a1b0", "d1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6", "Paula Reis - RH"},
	} {
		d := &device{nome: n.nome, label: n.label, id: uid(n.id), user: uid(n.user),
			sign: ed25519.NewKeyFromSeed(seed("grupos/" + n.nome + "/sign")), kexSK: seed("grupos/" + n.nome + "/kex")}
		d.kexPub = x25519Pub(d.kexSK)
		d.cert.Cert = proto.Cert{DeviceID: d.id, UserID: d.user, SignPub: d.signPub(), KexPub: d.kexPub,
			EnrolledAt: 1798000000000, ExpiresAt: 1813552000000, AdminLabel: d.label}
		d.cert.Sig = ed25519.Sign(w.serverKey, proto.CertBytes(d.cert.Cert))
		w.dev[n.nome] = d
	}
	w.keys = proto.ChainKeys{ServerPub: w.serverPub, ModPub: w.modPub, Certs: map[proto.UUID]proto.SignedCert{}}
	for _, d := range w.dev {
		w.keys.Certs[d.id] = d.cert
	}
	return w
}

func (d *device) json() O {
	c := d.cert.Cert
	return O{
		{"nome", d.nome},
		{"device_id", proto.FormatUUID(d.id)},
		{"user_id", proto.FormatUUID(d.user)},
		{"admin_label", d.label},
		{"sign_seed", hx(d.sign.Seed())},
		{"sign_pub", hx(d.signPub())},
		{"kex_sk", hx(d.kexSK)},
		{"kex_pub", hx(d.kexPub)},
		{"cert_bytes", hx(proto.CertBytes(c))},
		{"cert", O{
			{"device_id", proto.FormatUUID(c.DeviceID)}, {"user_id", proto.FormatUUID(c.UserID)},
			{"admin_label", c.AdminLabel}, {"sign_pub", b64(c.SignPub)}, {"kex_pub", b64(c.KexPub)},
			{"enrolled_at", c.EnrolledAt}, {"expires_at", c.ExpiresAt}, {"sig", b64(d.cert.Sig)},
		}},
	}
}

// ---------- registros ----------

// author is a device name, or "moderador".
type rec struct {
	author string
	c      proto.GroupChange
	key    ed25519.PrivateKey // nil: chave do autor
}

func (w *world) change(conv proto.UUID, n uint64, prev [32]byte, kind uint32, author string, at uint64, body []byte) rec {
	c := proto.GroupChange{Conv: conv, N: n, Prev: prev, Kind: kind, CreatedAt: at, Body: body}
	if author == "moderador" {
		c.AuthorType = proto.AuthorModerator
	} else {
		d := w.dev[author]
		c.AuthorType, c.AuthorDevice, c.AuthorUser = proto.AuthorDevice, d.id, d.user
	}
	return rec{author: author, c: c}
}

func (w *world) sign(r rec) proto.SignedChange {
	key := r.key
	if key == nil {
		if r.author == "moderador" {
			key = w.modKey
		} else {
			key = w.dev[r.author].sign
		}
	}
	return proto.SignChange(r.c, key)
}

// chain signs records in order, filling n and prev_hash from the previous record.
func (w *world) chain(rs []rec) []proto.SignedChange {
	var out []proto.SignedChange
	var prev [32]byte
	for i := range rs {
		rs[i].c.N = uint64(i + 1)
		rs[i].c.Prev = prev
		sc := w.sign(rs[i])
		out = append(out, sc)
		prev = proto.ChangeHash(sc)
	}
	return out
}

var kindName = map[uint32]string{
	proto.KindCreate: "criar", proto.KindAdd: "adicionar", proto.KindRemove: "remover",
	proto.KindPromote: "promover", proto.KindLeave: "sair", proto.KindRename: "renomear", proto.KindClose: "encerrar",
}

func recJSON(author string, sc proto.SignedChange) O {
	c, err := proto.DecodeChange(sc.Bytes)
	must(err)
	h := proto.ChangeHash(sc)
	return O{
		{"n", c.N},
		{"tipo", kindName[c.Kind]},
		{"kind", c.Kind},
		{"autor", author},
		{"created_at", c.CreatedAt},
		{"prev_hash", hx(c.Prev[:])},
		{"body", hx(c.Body)},
		{"change_bytes", hx(sc.Bytes)},
		{"signature", hx(sc.Sig)},
		{"record_hash", hx(h[:])},
		{"json", O{{"n", c.N}, {"change_bytes", b64(sc.Bytes)}, {"signature", b64(sc.Sig)}}},
	}
}

func wire(sc []proto.SignedChange) []O {
	out := make([]O, len(sc))
	for i, s := range sc {
		out[i] = O{{"change_bytes", hx(s.Bytes)}, {"signature", hx(s.Sig)}}
	}
	return out
}

func roleName(r uint32) string {
	if r == proto.RoleAdmin {
		return "admin"
	}
	return "membro"
}

func stateJSON(s *proto.GroupState) O {
	var ms []O
	for _, m := range s.SortedMembers() {
		ms = append(ms, O{{"user_id", proto.FormatUUID(m.User)}, {"role", roleName(m.Role)}})
	}
	return O{
		{"n", s.N},
		{"head", hx(s.Head[:])},
		{"membros", ms},
		{"encerrado_em", s.ClosedAt},
		{"admin_label", s.AdminLabel},
		{"meta_commit", hx(s.MetaCommit[:])},
	}
}

func sortedUsers(us ...proto.UUID) []proto.UUID {
	sort.Slice(us, func(i, j int) bool { return bytes.Compare(us[i][:], us[j][:]) < 0 })
	return us
}

func sortedMembers(ms ...proto.GroupMember) []proto.GroupMember {
	sort.Slice(ms, func(i, j int) bool { return bytes.Compare(ms[i].User[:], ms[j].User[:]) < 0 })
	return ms
}

// ---------- geração ----------

var (
	convG   = uid("b7c8d9e0-f1a2-4b3c-8d4e-5f6a7b8c9d0e") // grupo comum, criado por Ana
	convOf  = uid("c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f") // grupo oficial, criado pelo moderador
	t0      = uint64(1798100000000)
	meta1   = []byte(`{"v":1,"salt":"` + b64(seed("grupos/meta1/salt")) + `","name":"Projeto Atlas","description":"Equipe do projeto Atlas"}`)
	meta2   = []byte(`{"v":1,"salt":"` + b64(seed("grupos/meta2/salt")) + `","name":"Atlas - fase 2","description":""}`)
	metaOf  = []byte(`{"v":1,"salt":"` + b64(seed("grupos/metaOf/salt")) + `","name":"Diretoria","description":"Comunicados da diretoria"}`)
	labelOf = "Diretoria - oficial"
)

func generate(base string) (files map[string][]byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			if g, ok := r.(genErr); ok {
				err = g.error
				return
			}
			panic(r)
		}
	}()
	w := newWorld(base)
	files = map[string][]byte{
		"chaves.json":    w.genChaves(),
		"cadeia.json":    w.genCadeia(),
		"epoca.json":     w.genEpoca(),
		"selada.json":    w.genSelada(),
		"revogacao.json": w.genRevogacao(),
	}
	return files, nil
}

func (w *world) genChaves() []byte {
	host := "direct.exemplo.com.br"
	inv := seed("grupos/convite")
	qr := proto.InviteURIMod(host, inv, w.serverPub, w.escrowPub, w.modPub)
	pin := proto.PinURI(host, w.serverPub, w.escrowPub, w.modPub)
	other := ed25519.NewKeyFromSeed(seed("grupos/outro-servidor")).Public().(ed25519.PublicKey)
	return render(O{
		{"descricao", "Chaves dos vetores de grupo. A, B (João) e C (João, aparelho novo) vêm de ../chaves.json e ../cadastro.json; D (Marcos) e E (Paula) são novos, com certificado assinado pela chave do servidor de ../chaves.json."},
		{"moderador", O{{"sign_seed", hx(w.modKey.Seed())}, {"sign_pub", hx(w.modPub)}, {"sign_pub_b64u", b64(w.modPub)}}},
		{"aparelhos_novos", []O{w.dev["D"].json(), w.dev["E"].json()}},
		{"usuarios", O{
			{"ana", proto.FormatUUID(w.user("A"))}, {"joao", proto.FormatUUID(w.user("B"))},
			{"marcos", proto.FormatUUID(w.user("D"))}, {"paula", proto.FormatUUID(w.user("E"))},
		}},
		{"qr", O{
			{"host", host},
			{"invite_seed", hx(inv)},
			{"qr_uri_v2", qr},
			{"pin_uri", pin},
			{"codigo_verificacao_m", proto.ServerCodeMod(w.serverPub, w.escrowPub, w.modPub)},
			{"codigo_verificacao_v1", proto.ServerCode(w.serverPub, w.escrowPub)},
			{"qr_invalidos", []O{
				{{"caso", "v2_sem_m"}, {"uri", "direct://enroll?v=2&h=" + host + "&t=" + b64(inv) + "&s=" + b64(w.serverPub) + "&e=" + b64(w.escrowPub)}},
				{{"caso", "v1_com_m"}, {"uri", "direct://enroll?v=1&h=" + host + "&t=" + b64(inv) + "&s=" + b64(w.serverPub) + "&e=" + b64(w.escrowPub) + "&m=" + b64(w.modPub)}},
				{{"caso", "m_tamanho_errado"}, {"uri", "direct://enroll?v=2&h=" + host + "&t=" + b64(inv) + "&s=" + b64(w.serverPub) + "&e=" + b64(w.escrowPub) + "&m=" + b64(w.modPub[:31])}},
				{{"caso", "pin_com_t"}, {"uri", pin + "&t=" + b64(inv)}},
				{{"caso", "pin_servidor_diferente_do_fixado"}, {"uri", proto.PinURI(host, other, w.escrowPub, w.modPub)}},
				{{"caso", "pin_host_diferente_do_fixado"}, {"uri", proto.PinURI("outro.exemplo.com.br", w.serverPub, w.escrowPub, w.modPub)}},
			}},
		}},
	})
}

// mainChain is the valid chain of convG (8 records, all kinds).
func (w *world) mainChain() ([]rec, []proto.SignedChange) {
	ana, joao, marcos, paula := w.user("A"), w.user("B"), w.user("D"), w.user("E")
	c1 := proto.MetaCommit(convG, meta1)
	c2 := proto.MetaCommit(convG, meta2)
	rs := []rec{
		w.change(convG, 0, [32]byte{}, proto.KindCreate, "A", t0, proto.CreateBody("", c1, sortedMembers(
			proto.GroupMember{User: ana, Role: proto.RoleAdmin}, proto.GroupMember{User: joao, Role: proto.RoleMember}))),
		w.change(convG, 0, [32]byte{}, proto.KindAdd, "A", t0+60000, proto.AddBody(true, []proto.UUID{marcos})),
		w.change(convG, 0, [32]byte{}, proto.KindPromote, "A", t0+120000, proto.UsersBody([]proto.UUID{joao})),
		w.change(convG, 0, [32]byte{}, proto.KindRename, "C", t0+180000, proto.RenameBody(c2)),
		w.change(convG, 0, [32]byte{}, proto.KindRemove, "moderador", t0+240000, proto.UsersBody([]proto.UUID{marcos})),
		w.change(convG, 0, [32]byte{}, proto.KindAdd, "B", t0+300000, proto.AddBody(false, []proto.UUID{paula})),
		w.change(convG, 0, [32]byte{}, proto.KindLeave, "A", t0+360000, nil),
		w.change(convG, 0, [32]byte{}, proto.KindClose, "B", t0+420000, nil),
	}
	return rs, w.chain(rs)
}

type badCase struct {
	caso, desc string
	recs       []proto.SignedChange
	code       string
	n          uint64
}

func (w *world) genCadeia() []byte {
	ana, joao, marcos, paula := w.user("A"), w.user("B"), w.user("D"), w.user("E")
	rs, sc := w.mainChain()

	var regs []O
	var estados []O
	for i, s := range sc {
		regs = append(regs, recJSON(rs[i].author, s))
		st, err := proto.VerifyChain(convG, sc[:i+1], w.keys)
		must(err)
		estados = append(estados, stateJSON(st))
	}
	final, err := proto.VerifyChain(convG, sc, w.keys)
	must(err)

	// Consultas de reembrulho no estado depois do registro k.
	type q struct {
		apos   int
		nome   string
		user   proto.UUID
		n      uint64
		member bool
		rewrap bool
	}
	qs := []q{
		{4, "marcos", marcos, 1, false, true}, // entrou em 2 com histórico liberado
		{4, "marcos", marcos, 2, true, true},
		{4, "joao", joao, 1, true, true},
		{6, "marcos", marcos, 3, true, false}, // foi removido em 5: não é mais membro
		{6, "paula", paula, 5, false, false},  // entrou em 6 sem histórico
		{6, "paula", paula, 6, true, true},
		{8, "ana", ana, 6, true, false}, // saiu em 7
		{8, "ana", ana, 7, false, false},
		{8, "joao", joao, 8, true, true},
	}
	var cons []O
	for _, x := range qs {
		st, err := proto.VerifyChain(convG, sc[:x.apos], w.keys)
		must(err)
		check(st.MemberAt(x.user, x.n) == x.member, fmt.Sprintf("member_at %s %d", x.nome, x.n))
		check(st.MayRewrap(x.user, x.n) == x.rewrap, fmt.Sprintf("may_rewrap %s %d", x.nome, x.n))
		cons = append(cons, O{{"apos_registro", x.apos}, {"usuario", x.nome}, {"user_id", proto.FormatUUID(x.user)},
			{"chain_n", x.n}, {"membro_em_n", x.member}, {"pode_reembrulhar", x.rewrap}})
	}

	// Grupo oficial: criado pelo moderador com rótulo em claro, depois renomeado por Ana.
	ofRs := []rec{
		w.change(convOf, 0, [32]byte{}, proto.KindCreate, "moderador", t0, proto.CreateBody(labelOf, [32]byte{}, sortedMembers(
			proto.GroupMember{User: ana, Role: proto.RoleAdmin}, proto.GroupMember{User: joao, Role: proto.RoleMember},
			proto.GroupMember{User: marcos, Role: proto.RoleMember}))),
		w.change(convOf, 0, [32]byte{}, proto.KindRename, "A", t0+60000, proto.RenameBody(proto.MetaCommit(convOf, metaOf))),
	}
	ofSc := w.chain(ofRs)
	ofSt, err := proto.VerifyChain(convOf, ofSc, w.keys)
	must(err)
	var ofRegs []O
	for i, s := range ofSc {
		ofRegs = append(ofRegs, recJSON(ofRs[i].author, s))
	}

	bad := w.badCases(sc)
	var falhas []O
	for _, b := range bad {
		_, err := proto.VerifyChain(convG, b.recs, w.keys)
		var ce *proto.ChainError
		ok := err != nil && asChain(err, &ce) && ce.Code == b.code && ce.N == b.n
		check(ok, fmt.Sprintf("caso %s: esperado %s em %d, veio %v", b.caso, b.code, b.n, err))
		falhas = append(falhas, O{{"caso", b.caso}, {"descricao", b.desc}, {"codigo", b.code}, {"n", b.n}, {"registros", wire(b.recs)}})
	}

	return render(O{
		{"descricao", "Cadeia de mudanças assinada (protocolo-grupos §2). Grupo comum criado por Ana com todos os tipos de registro; grupo oficial criado pelo moderador; casos que devem falhar. Verificar com as chaves de ../chaves.json, ./chaves.json e os certificados de ../cadastro.json e ./chaves.json."},
		{"grupo_comum", O{
			{"conversation_id", proto.FormatUUID(convG)},
			{"meta_json_1", string(meta1)},
			{"meta_json_2", string(meta2)},
			{"registros", regs},
			{"estado_depois_de_cada_registro", estados},
			{"estado_final", stateJSON(final)},
			{"consultas", cons},
		}},
		{"grupo_oficial", O{
			{"conversation_id", proto.FormatUUID(convOf)},
			{"meta_json", string(metaOf)},
			{"registros", ofRegs},
			{"estado_final", stateJSON(ofSt)},
		}},
		{"deve_falhar", falhas},
	})
}

func asChain(err error, target **proto.ChainError) bool {
	ce, ok := err.(*proto.ChainError)
	if ok {
		*target = ce
	}
	return ok
}

func (w *world) badCases(sc []proto.SignedChange) []badCase {
	ana, joao, paula := w.user("A"), w.user("B"), w.user("E")
	first := sc[0]
	h1 := proto.ChangeHash(first)
	mk := func(n uint64, prev [32]byte, kind uint32, author string, body []byte) rec {
		return w.change(convG, n, prev, kind, author, t0+60000, body)
	}
	signed := func(r rec) proto.SignedChange { return w.sign(r) }

	var cases []badCase
	add := func(caso, desc, code string, n uint64, recs ...proto.SignedChange) {
		cases = append(cases, badCase{caso, desc, recs, code, n})
	}

	// assinatura errada
	r2 := sc[1]
	flipped := proto.SignedChange{Bytes: r2.Bytes, Sig: append([]byte(nil), r2.Sig...)}
	flipped.Sig[0] ^= 1
	add("assinatura_errada", "registro 2 da cadeia válida com um bit trocado na assinatura", proto.ChainSig, 2, first, flipped)

	// assinatura de outra chave de moderador
	wrongMod := mk(2, h1, proto.KindRemove, "moderador", proto.UsersBody([]proto.UUID{joao}))
	wrongMod.key = ed25519.NewKeyFromSeed(seed("grupos/moderador-falso"))
	add("moderador_falso", "remoção assinada por chave que não é a do moderador fixada", proto.ChainSig, 2, first, signed(wrongMod))

	// prev_hash quebrado
	bp := h1
	bp[0] ^= 1
	add("prev_hash_quebrado", "registro 2 bem assinado, mas com prev_hash que não é o hash do registro 1", proto.ChainPrev, 2,
		first, signed(mk(2, bp, proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{paula}))))

	// sequência
	add("n_pulado", "segundo registro com n = 3", proto.ChainSeq, 2,
		first, signed(mk(3, h1, proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{paula}))))
	add("criar_depois_do_inicio", "registro de criação na posição 2", proto.ChainSeq, 2,
		first, signed(mk(2, h1, proto.KindCreate, "A", proto.CreateBody("", proto.MetaCommit(convG, meta1),
			[]proto.GroupMember{{User: ana, Role: proto.RoleAdmin}}))))

	// outra conversa
	other := w.change(convOf, 2, h1, proto.KindAdd, "A", t0+60000, proto.AddBody(false, []proto.UUID{paula}))
	add("outra_conversa", "registro 2 com conversation_id de outro grupo", proto.ChainConv, 2, first, signed(other))

	// autor sem papel
	add("autor_sem_papel", "João, membro comum, tenta adicionar Paula", proto.ChainRole, 2,
		first, signed(mk(2, h1, proto.KindAdd, "B", proto.AddBody(false, []proto.UUID{paula}))))
	add("moderador_adiciona", "o moderador não assina adicionar", proto.ChainRole, 2,
		first, signed(mk(2, h1, proto.KindAdd, "moderador", proto.AddBody(false, []proto.UUID{paula}))))
	add("moderador_renomeia", "o moderador não assina renomear", proto.ChainRole, 2,
		first, signed(mk(2, h1, proto.KindRename, "moderador", proto.RenameBody(proto.MetaCommit(convG, meta2)))))
	add("nao_membro_sai", "Paula, que não é membro, assina sair", proto.ChainRole, 2,
		first, signed(mk(2, h1, proto.KindLeave, "E", nil)))
	creatorNotAdmin := w.change(convG, 1, [32]byte{}, proto.KindCreate, "A", t0, proto.CreateBody("", proto.MetaCommit(convG, meta1),
		sortedMembers(proto.GroupMember{User: ana, Role: proto.RoleMember}, proto.GroupMember{User: joao, Role: proto.RoleAdmin})))
	add("criador_nao_admin", "Ana cria o grupo, mas se coloca como membro comum", proto.ChainRole, 1, signed(creatorNotAdmin))

	// autor
	swapped := mk(2, h1, proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{paula}))
	swapped.c.AuthorUser = joao
	add("usuario_do_autor_trocado", "aparelho A (de Ana) declara author_user_id de João", proto.ChainAuthor, 2, first, signed(swapped))
	ghost := mk(2, h1, proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{paula}))
	ghost.c.AuthorDevice = uid("00000000-0000-4000-8000-0000000000f1")
	ghost.key = ed25519.NewKeyFromSeed(seed("grupos/fantasma"))
	add("aparelho_sem_certificado", "autor é um aparelho sem certificado conhecido", proto.ChainAuthor, 2, first, signed(ghost))

	// alvo
	add("alvo_ja_membro", "Ana adiciona João, que já é membro", proto.ChainTarget, 2,
		first, signed(mk(2, h1, proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{joao}))))
	add("remover_a_si_mesmo", "Ana se remove (deve usar sair)", proto.ChainTarget, 2,
		first, signed(mk(2, h1, proto.KindRemove, "A", proto.UsersBody([]proto.UUID{ana}))))
	add("remover_nao_membro", "Ana remove Paula, que não é membro", proto.ChainTarget, 2,
		first, signed(mk(2, h1, proto.KindRemove, "A", proto.UsersBody([]proto.UUID{paula}))))

	// formato
	unsorted := mk(2, h1, proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{paula, w.user("D")}))
	add("alvos_fora_de_ordem", "lista de alvos fora da ordem crescente", proto.ChainFormat, 2, first, signed(unsorted))
	devLabel := w.change(convG, 1, [32]byte{}, proto.KindCreate, "A", t0, proto.CreateBody("Rótulo", proto.MetaCommit(convG, meta1),
		[]proto.GroupMember{{User: ana, Role: proto.RoleAdmin}}))
	add("rotulo_em_grupo_comum", "aparelho cria grupo com admin_label em claro", proto.ChainFormat, 1, signed(devLabel))

	// encerrado
	closed := signed(mk(2, h1, proto.KindClose, "A", nil))
	add("depois_de_encerrar", "registro depois de encerrar", proto.ChainClosed, 3,
		first, closed, signed(mk(3, proto.ChangeHash(closed), proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{paula}))))

	// limite
	members := []proto.GroupMember{{User: ana, Role: proto.RoleAdmin}}
	for i := 1; len(members) < proto.GroupMaxMembers; i++ {
		var u proto.UUID
		copy(u[:], seed(fmt.Sprintf("grupos/figurante/%d", i))[:16])
		u[6] = u[6]&0x0f | 0x40
		u[8] = u[8]&0x3f | 0x80
		if u == joao || u == paula {
			continue
		}
		members = append(members, proto.GroupMember{User: u, Role: proto.RoleMember})
	}
	members = sortedMembers(members...)
	full := signed(w.change(convG, 1, [32]byte{}, proto.KindCreate, "moderador", t0, proto.CreateBody(labelOf, [32]byte{}, members)))
	add("membro_acima_do_limite", "grupo oficial com 100 membros; Ana adiciona Paula (seria o 101º)", proto.ChainLimit, 2,
		full, signed(mk(2, proto.ChangeHash(full), proto.KindAdd, "A", proto.AddBody(false, []proto.UUID{paula}))))
	over := sortedMembers(append(append([]proto.GroupMember(nil), members...), proto.GroupMember{User: paula, Role: proto.RoleMember})...)
	add("criar_acima_do_limite", "criação com 101 membros", proto.ChainLimit, 1,
		signed(w.change(convG, 1, [32]byte{}, proto.KindCreate, "moderador", t0, proto.CreateBody(labelOf, [32]byte{}, over))))
	return cases
}

// ---------- épocas de grupo e metadados ----------

func (w *world) genEpoca() []byte {
	_, sc := w.mainChain()
	st2, err := proto.VerifyChain(convG, sc[:2], w.keys)
	must(err)

	type ep struct {
		epoch  uint32
		chainN uint64
		devs   []string
		meta   []byte
	}
	eps := []ep{
		{1, 1, []string{"A", "B", "C"}, meta1},
		{2, 2, []string{"A", "B", "C", "D"}, meta1},
	}
	keyOf := map[uint32][]byte{}
	var out []O
	for _, e := range eps {
		K := seed(fmt.Sprintf("grupos/epoca/%d/K", e.epoch))
		keyOf[e.epoch] = K
		h, _ := st2.HashAt(e.chainN)
		var rec []proto.UUID
		var owners []proto.UUID
		for _, n := range e.devs {
			rec = append(rec, w.dev[n].id)
		}
		rec = sortedUsers(rec...)
		for _, id := range rec {
			owners = append(owners, w.keys.Certs[id].Cert.UserID)
		}
		cm := proto.EpochKeyCommitment(convG, e.epoch, K)
		stmt := proto.GroupEpochBytes(convG, e.epoch, w.dev["A"].id, cm[:], w.escrowPub, e.chainN, h, rec)
		sig := ed25519.Sign(w.dev["A"].sign, stmt)
		must(st2.CheckGroupEpoch(e.chainN, h, w.user("A"), owners))

		var wraps []O
		for _, n := range append(append([]string(nil), e.devs...), "escrow") {
			pub, sk, id := w.escrowPub, w.escrowSK, ""
			if n != "escrow" {
				pub, sk, id = w.dev[n].kexPub, w.dev[n].kexSK, proto.FormatUUID(w.dev[n].id)
			}
			eph := seed(fmt.Sprintf("grupos/epoca/%d/eph/%s", e.epoch, n))
			ct := seal(K, pub, eph)
			got, ok := open(ct, pub, sk)
			check(ok && bytes.Equal(got, K), "abrir embrulho")
			wraps = append(wraps, O{{"destino", n}, {"device_id", id}, {"eph_sk", hx(eph)}, {"wrapped_key", hx(ct)}})
		}

		nonce := seed(fmt.Sprintf("grupos/epoca/%d/meta-nonce", e.epoch))[:24]
		mc := proto.MetaCommit(convG, e.meta)
		mct, err := proto.SealMeta(K, nonce, convG, e.epoch, e.meta)
		must(err)
		back, err := proto.OpenMeta(K, nonce, mct, convG, e.epoch, mc)
		must(err)
		check(bytes.Equal(back, e.meta), "abrir metadados")

		var recS []string
		for _, r := range rec {
			recS = append(recS, proto.FormatUUID(r))
		}
		out = append(out, O{
			{"epoch", e.epoch},
			{"creator", "A"},
			{"chain_n", e.chainN},
			{"chain_hash", hx(h[:])},
			{"chave_epoca", hx(K)},
			{"key_commitment", hx(cm[:])},
			{"recipients_ordenados", recS},
			{"statement_bytes", hx(stmt)},
			{"statement_sig", hx(sig)},
			{"embrulhos", wraps},
			{"meta", O{
				{"meta_json", string(e.meta)},
				{"meta_commit", hx(mc[:])},
				{"aad", hx(proto.MetaAAD(convG, e.epoch, mc))},
				{"nonce", hx(nonce)},
				{"ciphertext", hx(mct)},
				{"json", O{{"epoch", e.epoch}, {"meta_commit", b64(mc[:])}, {"nonce", b64(nonce)}, {"ciphertext", b64(mct)}}},
			}},
		})
	}

	// Liberação de histórico (G2): Ana reembrulha a época 1 para D, de Marcos (registro 2 com history = 1).
	check(st2.MayRewrap(w.user("D"), 1), "marcos pode receber época 1")
	eph := seed("grupos/historico/eph/D")
	hw := seal(keyOf[1], w.dev["D"].kexPub, eph)

	// Épocas que devem ser recusadas pela cadeia (CheckGroupEpoch no estado depois do registro 2).
	h1, _ := st2.HashAt(1)
	h2, _ := st2.HashAt(2)
	bh := h2
	bh[0] ^= 1
	type bad struct {
		caso, desc string
		n          uint64
		h          [32]byte
		creator    string
		devs       []string
		code       string
	}
	bads := []bad{
		{"chain_hash_errado", "chain_hash não é o hash do registro 2", 2, bh, "A", []string{"A", "B", "C", "D"}, proto.ChainEpochRef},
		{"chain_n_futuro", "chain_n = 3 numa cadeia com 2 registros", 3, h2, "A", []string{"A", "B", "C", "D"}, proto.ChainEpochRef},
		{"criador_nao_membro", "Marcos cria época na posição 1, antes de entrar", 1, h1, "D", []string{"A", "B", "C", "D"}, proto.ChainRole},
		{"destinatario_nao_membro", "época na posição 2 com o aparelho E, de Paula, que não é membro", 2, h2, "A", []string{"A", "B", "C", "D", "E"}, proto.ChainTarget},
	}
	var falhas []O
	for _, b := range bads {
		var owners []string
		var ou []proto.UUID
		for _, d := range b.devs {
			owners = append(owners, proto.FormatUUID(w.dev[d].user))
			ou = append(ou, w.dev[d].user)
		}
		err := st2.CheckGroupEpoch(b.n, b.h, w.dev[b.creator].user, ou)
		var ce *proto.ChainError
		check(err != nil && asChain(err, &ce) && ce.Code == b.code, "época inválida "+b.caso)
		falhas = append(falhas, O{{"caso", b.caso}, {"descricao", b.desc}, {"chain_n", b.n}, {"chain_hash", hx(b.h[:])},
			{"creator_user_id", proto.FormatUUID(w.dev[b.creator].user)}, {"recipient_owners", owners}, {"codigo", b.code}})
	}

	return render(O{
		{"descricao", "Épocas 1 e 2 do grupo comum de cadeia.json (protocolo-grupos §5 e §6), metadados cifrados, liberação de histórico e épocas que a cadeia recusa. As verificações de cadeia usam o estado depois do registro 2."},
		{"conversation_id", proto.FormatUUID(convG)},
		{"escrow_pub", hx(w.escrowPub)},
		{"epocas", out},
		{"historico_liberado", O{
			{"add_n", 2}, {"epoch", 1}, {"device_id", proto.FormatUUID(w.dev["D"].id)},
			{"eph_sk", hx(eph)}, {"wrapped_key", hx(hw)},
			{"json", O{{"add_n", 2}, {"items", []O{{{"epoch", 1}, {"device_id", proto.FormatUUID(w.dev["D"].id)}, {"wrapped_key", b64(hw)}}}}}},
		}},
		{"deve_falhar", falhas},
	})
}

// ---------- D11 ----------

func (w *world) genSelada() []byte {
	marcos := w.dev["D"]
	var ex []O
	for i, ctLen := range []int{272, 1040, 16400} {
		seq := uint64(7 + i)
		mid := uid(fmt.Sprintf("0b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4%d", i))
		s := proto.NewSealed(convG, seq, mid, marcos.id, marcos.user, t0+600000+uint64(i)*1000, ctLen)
		ex = append(ex, O{{"len_ciphertext", ctLen}, {"scramble_len", proto.ScrambleLen(ctLen)},
			{"hash_entrada", hx(append(append([]byte(proto.LabelSealed), convG[:]...), u64(seq)...))}, {"selada", s}})
	}
	ev := proto.MemberAccessEvent{Type: "member_access", UserID: proto.FormatUUID(marcos.user), Active: false,
		At: t0 + 700000, Conversations: []string{proto.FormatUUID(convG)}}
	return render(O{
		{"descricao", "Mensagem selada (protocolo-grupos §7.2), embaralhado, evento member_access e erro de blob. O embaralhado depende só de conversation_id, seq e tamanho; não depende do conteúdo."},
		{"alfabeto", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRST#@%&$*!?"},
		{"exemplos", ex},
		{"evento_member_access", ev},
		{"access_events", O{{"events", []proto.AccessEvent{
			{ID: 41, UserID: proto.FormatUUID(marcos.user), Active: false, At: t0 + 700000},
			{ID: 42, UserID: proto.FormatUUID(marcos.user), Active: true, At: t0 + 90000000},
		}}, {"has_more", false}}},
		{"erro_blob", O{{"error", O{{"code", "sender_inactive"}, {"message", "remetente sem acesso"}}}}},
	})
}

func u64(v uint64) []byte {
	b := make([]byte, 8)
	for i := 7; i >= 0; i-- {
		b[i] = byte(v)
		v >>= 8
	}
	return b
}

func (w *world) genRevogacao() []byte {
	a := w.dev["A"]
	at := uint64(1798200000000)
	msg := proto.SelfRevokeBytes(w.serverPub, a.id, at)
	sig := ed25519.Sign(a.sign, msg)
	req := proto.SelfRevokeRequest{DeviceID: proto.FormatUUID(a.id), CreatedAt: at, Sig: b64(sig)}
	_, ok := proto.VerifySelfRevoke(w.serverPub, a.signPub(), req)
	check(ok, "revogação válida")

	other := ed25519.NewKeyFromSeed(seed("grupos/outro-servidor")).Public().(ed25519.PublicKey)
	badSig := append([]byte(nil), sig...)
	badSig[5] ^= 1
	cases := []struct {
		caso, desc string
		req        proto.SelfRevokeRequest
	}{
		{"outro_aparelho", "assinatura de A apresentada com device_id de B",
			proto.SelfRevokeRequest{DeviceID: proto.FormatUUID(w.dev["B"].id), CreatedAt: at, Sig: b64(sig)}},
		{"horario_trocado", "created_at diferente do assinado", proto.SelfRevokeRequest{DeviceID: req.DeviceID, CreatedAt: at + 1, Sig: b64(sig)}},
		{"bit_trocado", "assinatura com um bit trocado", proto.SelfRevokeRequest{DeviceID: req.DeviceID, CreatedAt: at, Sig: b64(badSig)}},
		{"outro_servidor", "assinada sobre server_sign_pub de outro servidor",
			proto.SelfRevokeRequest{DeviceID: req.DeviceID, CreatedAt: at, Sig: b64(ed25519.Sign(a.sign, proto.SelfRevokeBytes(other, a.id, at)))}},
	}
	var falhas []O
	for _, c := range cases {
		// O servidor busca o sign_pub pelo device_id da requisição.
		pub := a.signPub()
		if c.caso == "outro_aparelho" {
			pub = w.dev["B"].signPub()
		}
		_, ok := proto.VerifySelfRevoke(w.serverPub, pub, c.req)
		check(!ok, "revogação inválida "+c.caso)
		falhas = append(falhas, O{{"caso", c.caso}, {"descricao", c.desc}, {"requisicao", c.req}})
	}
	return render(O{
		{"descricao", "Revogação pré-assinada do aparelho A (protocolo-grupos §8). Verificar com o sign_pub do aparelho indicado em device_id e a server_sign_pub de ../chaves.json."},
		{"aparelho", "A"},
		{"created_at", at},
		{"self_revoke_bytes", hx(msg)},
		{"sig", hx(sig)},
		{"requisicao", req},
		{"deve_falhar", falhas},
	})
}
