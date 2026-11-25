package proto_test

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"testing"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/testvec"
	"golang.org/x/crypto/nacl/box"
)

// ---- vector types (docs/vetores/grupos) ----

type gDevice struct {
	Nome     string `json:"nome"`
	DeviceID string `json:"device_id"`
	UserID   string `json:"user_id"`
	SignPub  string `json:"sign_pub"`
	KexSK    string `json:"kex_sk"`
	KexPub   string `json:"kex_pub"`
	CertB    string `json:"cert_bytes"`
	Cert     struct {
		AdminLabel string `json:"admin_label"`
		EnrolledAt uint64 `json:"enrolled_at"`
		ExpiresAt  uint64 `json:"expires_at"`
		Sig        string `json:"sig"`
	} `json:"cert"`
}

type gChaves struct {
	Moderador struct {
		SignSeed string `json:"sign_seed"`
		SignPub  string `json:"sign_pub"`
	} `json:"moderador"`
	Novos []gDevice `json:"aparelhos_novos"`
	QR    struct {
		Host       string `json:"host"`
		InviteSeed string `json:"invite_seed"`
		URI        string `json:"qr_uri_v2"`
		Pin        string `json:"pin_uri"`
		Code       string `json:"codigo_verificacao_m"`
		CodeV1     string `json:"codigo_verificacao_v1"`
	} `json:"qr"`
}

type gRec struct {
	N           uint64 `json:"n"`
	Kind        uint32 `json:"kind"`
	ChangeBytes string `json:"change_bytes"`
	Signature   string `json:"signature"`
	RecordHash  string `json:"record_hash"`
	Body        string `json:"body"`
}

type gState struct {
	N       uint64 `json:"n"`
	Head    string `json:"head"`
	Membros []struct {
		UserID string `json:"user_id"`
		Role   string `json:"role"`
	} `json:"membros"`
	Encerrado  uint64 `json:"encerrado_em"`
	AdminLabel string `json:"admin_label"`
	MetaCommit string `json:"meta_commit"`
}

type gGroup struct {
	Conv      string   `json:"conversation_id"`
	Registros []gRec   `json:"registros"`
	Estados   []gState `json:"estado_depois_de_cada_registro"`
	Final     gState   `json:"estado_final"`
	Consultas []struct {
		Apos   int    `json:"apos_registro"`
		UserID string `json:"user_id"`
		N      uint64 `json:"chain_n"`
		Member bool   `json:"membro_em_n"`
		Rewrap bool   `json:"pode_reembrulhar"`
	} `json:"consultas"`
}

type gCadeia struct {
	Comum   gGroup `json:"grupo_comum"`
	Oficial gGroup `json:"grupo_oficial"`
	Falhas  []struct {
		Caso      string `json:"caso"`
		Codigo    string `json:"codigo"`
		N         uint64 `json:"n"`
		Registros []gRec `json:"registros"`
	} `json:"deve_falhar"`
}

// ---- helpers ----

type gEnv struct {
	t      *testing.T
	ch     testvec.Chaves
	gc     gChaves
	keys   proto.ChainKeys
	kexSK  map[string][]byte // device_id -> kex_sk
	signOf map[string][]byte // device name -> sign_pub
	idOf   map[string]proto.UUID
}

func loadGroupEnv(t *testing.T) *gEnv {
	t.Helper()
	e := &gEnv{t: t, kexSK: map[string][]byte{}, signOf: map[string][]byte{}, idOf: map[string]proto.UUID{}}
	var cad testvec.Cadastro
	testvec.Load(t, "chaves", &e.ch)
	testvec.Load(t, "cadastro", &cad)
	testvec.Load(t, "grupos/chaves", &e.gc)
	e.keys = proto.ChainKeys{
		ServerPub: testvec.Hex(t, e.ch.Servidor.SignPub),
		ModPub:    testvec.Hex(t, e.gc.Moderador.SignPub),
		Certs:     map[proto.UUID]proto.SignedCert{},
	}
	eq(t, "mod pub", ed25519.NewKeyFromSeed(testvec.Hex(t, e.gc.Moderador.SignSeed)).Public().(ed25519.PublicKey), e.gc.Moderador.SignPub)
	certs := map[string]testvec.Cert{}
	for _, c := range cad.Certs {
		certs[c.Aparelho] = c
	}
	add := func(nome, dev, user, label, signPub, kexPub, kexSK, sig string, enrolled, expires uint64) {
		c := proto.Cert{DeviceID: uuid(t, dev), UserID: uuid(t, user), SignPub: testvec.Hex(t, signPub),
			KexPub: testvec.Hex(t, kexPub), EnrolledAt: enrolled, ExpiresAt: expires, AdminLabel: label}
		e.keys.Certs[c.DeviceID] = proto.SignedCert{Cert: c, Sig: testvec.Hex(t, sig)}
		e.kexSK[dev] = testvec.Hex(t, kexSK)
		e.signOf[nome] = c.SignPub
		e.idOf[nome] = c.DeviceID
	}
	for _, d := range e.ch.Aparelhos {
		c := certs[d.Nome]
		add(d.Nome, d.DeviceID, d.UserID, d.AdminLabel, d.SignPub, d.KexPub, d.KexSK, c.CertSig, c.EnrolledAt, c.ExpiresAt)
	}
	for _, d := range e.gc.Novos {
		add(d.Nome, d.DeviceID, d.UserID, d.Cert.AdminLabel, d.SignPub, d.KexPub, d.KexSK,
			b64hex(t, d.Cert.Sig), d.Cert.EnrolledAt, d.Cert.ExpiresAt)
		eq(t, d.Nome+" cert_bytes", proto.CertBytes(e.keys.Certs[uuid(t, d.DeviceID)].Cert), d.CertB)
	}
	return e
}

func b64hex(t *testing.T, s string) string {
	b, err := proto.B64Decode(s)
	if err != nil {
		t.Fatal(err)
	}
	return string(hexOf(b))
}

func hexOf(b []byte) []byte {
	const h = "0123456789abcdef"
	out := make([]byte, 2*len(b))
	for i, c := range b {
		out[2*i], out[2*i+1] = h[c>>4], h[c&15]
	}
	return out
}

func signedRecs(t *testing.T, rs []gRec) []proto.SignedChange {
	out := make([]proto.SignedChange, len(rs))
	for i, r := range rs {
		out[i] = proto.SignedChange{Bytes: testvec.Hex(t, r.ChangeBytes), Sig: testvec.Hex(t, r.Signature)}
	}
	return out
}

func roleOf(s string) uint32 {
	if s == "admin" {
		return proto.RoleAdmin
	}
	return proto.RoleMember
}

func checkState(t *testing.T, what string, got *proto.GroupState, want gState) {
	t.Helper()
	if got.N != want.N || got.ClosedAt != want.Encerrado || got.AdminLabel != want.AdminLabel {
		t.Errorf("%s: n/encerrado/rótulo = %d/%d/%q, want %d/%d/%q", what, got.N, got.ClosedAt, got.AdminLabel, want.N, want.Encerrado, want.AdminLabel)
	}
	eq(t, what+" head", got.Head[:], want.Head)
	eq(t, what+" meta_commit", got.MetaCommit[:], want.MetaCommit)
	ms := got.SortedMembers()
	if len(ms) != len(want.Membros) {
		t.Fatalf("%s: %d membros, want %d", what, len(ms), len(want.Membros))
	}
	for i, m := range ms {
		if proto.FormatUUID(m.User) != want.Membros[i].UserID || m.Role != roleOf(want.Membros[i].Role) {
			t.Errorf("%s: membro %d = %s/%d, want %+v", what, i, proto.FormatUUID(m.User), m.Role, want.Membros[i])
		}
	}
}

// ---- chain ----

func TestGroupChainVectors(t *testing.T) {
	e := loadGroupEnv(t)
	var v gCadeia
	testvec.Load(t, "grupos/cadeia", &v)

	for _, g := range []gGroup{v.Comum, v.Oficial} {
		conv := uuid(t, g.Conv)
		recs := signedRecs(t, g.Registros)
		for i, r := range g.Registros {
			c, err := proto.DecodeChange(recs[i].Bytes)
			if err != nil {
				t.Fatalf("registro %d: %v", r.N, err)
			}
			if c.N != r.N || c.Kind != r.Kind {
				t.Errorf("registro %d: n/kind = %d/%d", r.N, c.N, c.Kind)
			}
			eq(t, "body", c.Body, r.Body)
			eq(t, "reencode", proto.ChangeBytes(c), r.ChangeBytes)
			h := proto.ChangeHash(recs[i])
			eq(t, "record_hash", h[:], r.RecordHash)
			if _, err := proto.ParseBody(c.Kind, c.Body); err != nil {
				t.Errorf("registro %d: corpo: %v", r.N, err)
			}
		}
		st, err := proto.VerifyChain(conv, recs, e.keys)
		if err != nil {
			t.Fatalf("%s: %v", g.Conv, err)
		}
		checkState(t, g.Conv+" final", st, g.Final)
		for i, want := range g.Estados {
			s, err := proto.VerifyChain(conv, recs[:i+1], e.keys)
			if err != nil {
				t.Fatal(err)
			}
			checkState(t, "após "+string(rune('0'+i+1)), s, want)
		}
		for _, q := range g.Consultas {
			s, _ := proto.VerifyChain(conv, recs[:q.Apos], e.keys)
			u := uuid(t, q.UserID)
			if s.MemberAt(u, q.N) != q.Member || s.MayRewrap(u, q.N) != q.Rewrap {
				t.Errorf("consulta %+v: member_at=%v may_rewrap=%v", q, s.MemberAt(u, q.N), s.MayRewrap(u, q.N))
			}
		}
	}

	conv := uuid(t, v.Comum.Conv)
	for _, f := range v.Falhas {
		_, err := proto.VerifyChain(conv, signedRecs(t, f.Registros), e.keys)
		var ce *proto.ChainError
		if ce, _ = err.(*proto.ChainError); ce == nil || ce.Code != f.Codigo || ce.N != f.N {
			t.Errorf("%s: err = %v, want %s no registro %d", f.Caso, err, f.Codigo, f.N)
		}
	}
}

func TestGroupChainNoModKey(t *testing.T) {
	e := loadGroupEnv(t)
	var v gCadeia
	testvec.Load(t, "grupos/cadeia", &v)
	keys := e.keys
	keys.ModPub = nil
	_, err := proto.VerifyChain(uuid(t, v.Oficial.Conv), signedRecs(t, v.Oficial.Registros), keys)
	if proto.CodeOf(err) != proto.ChainAuthor {
		t.Fatalf("sem chave do moderador: %v", err)
	}
}

func TestGroupApplyKeepsStateOnError(t *testing.T) {
	e := loadGroupEnv(t)
	var v gCadeia
	testvec.Load(t, "grupos/cadeia", &v)
	conv := uuid(t, v.Comum.Conv)
	recs := signedRecs(t, v.Comum.Registros)
	s := proto.NewGroupState(conv)
	if err := s.Apply(recs[0], e.keys); err != nil {
		t.Fatal(err)
	}
	bad := proto.SignedChange{Bytes: recs[1].Bytes, Sig: append([]byte(nil), recs[1].Sig...)}
	bad.Sig[10] ^= 0x40
	if err := s.Apply(bad, e.keys); proto.CodeOf(err) != proto.ChainSig {
		t.Fatalf("bad sig: %v", err)
	}
	if s.N != 1 || len(s.Members) != 2 {
		t.Fatalf("estado mudou após erro: n=%d membros=%d", s.N, len(s.Members))
	}
	for _, r := range recs[1:] {
		if err := s.Apply(r, e.keys); err != nil {
			t.Fatal(err)
		}
	}
	checkState(t, "incremental", s, v.Comum.Final)
}

func TestDecodeChangeRejects(t *testing.T) {
	var v gCadeia
	testvec.Load(t, "grupos/cadeia", &v)
	b := testvec.Hex(t, v.Comum.Registros[0].ChangeBytes)
	for name, x := range map[string][]byte{
		"curto":        b[:50],
		"byte a mais":  append(append([]byte(nil), b...), 0),
		"byte a menos": b[:len(b)-1],
		"rótulo":       append([]byte("direct/v1/group-chang\x00x"), b[23:]...),
		"grande":       append(append([]byte(nil), b...), make([]byte, proto.GroupMaxChangeBytes)...),
	} {
		if _, err := proto.DecodeChange(x); err == nil {
			t.Errorf("%s: aceito", name)
		}
	}
	for name, body := range map[string][]byte{
		"add sem alvos":  proto.AddBody(false, nil),
		"promote vazio":  proto.UsersBody(nil),
		"rename curto":   make([]byte, 31),
		"leave com byte": {0},
	} {
		kind := map[string]uint32{"add sem alvos": proto.KindAdd, "promote vazio": proto.KindPromote,
			"rename curto": proto.KindRename, "leave com byte": proto.KindLeave}[name]
		if _, err := proto.ParseBody(kind, body); err == nil {
			t.Errorf("%s: aceito", name)
		}
	}
	if _, err := proto.ParseBody(99, nil); err == nil {
		t.Error("kind 99 aceito")
	}
}

// ---- epochs and meta ----

type gEpoca struct {
	Conv   string `json:"conversation_id"`
	Escrow string `json:"escrow_pub"`
	Epocas []struct {
		Epoch      uint32   `json:"epoch"`
		ChainN     uint64   `json:"chain_n"`
		ChainHash  string   `json:"chain_hash"`
		K          string   `json:"chave_epoca"`
		Commitment string   `json:"key_commitment"`
		Recipients []string `json:"recipients_ordenados"`
		Stmt       string   `json:"statement_bytes"`
		Sig        string   `json:"statement_sig"`
		Embrulhos  []struct {
			Destino    string `json:"destino"`
			DeviceID   string `json:"device_id"`
			WrappedKey string `json:"wrapped_key"`
		} `json:"embrulhos"`
		Meta struct {
			JSON       string `json:"meta_json"`
			Commit     string `json:"meta_commit"`
			AAD        string `json:"aad"`
			Nonce      string `json:"nonce"`
			Ciphertext string `json:"ciphertext"`
		} `json:"meta"`
	} `json:"epocas"`
	Historico struct {
		Epoch      uint32 `json:"epoch"`
		DeviceID   string `json:"device_id"`
		WrappedKey string `json:"wrapped_key"`
	} `json:"historico_liberado"`
	Falhas []struct {
		Caso      string   `json:"caso"`
		ChainN    uint64   `json:"chain_n"`
		ChainHash string   `json:"chain_hash"`
		Creator   string   `json:"creator_user_id"`
		Owners    []string `json:"recipient_owners"`
		Codigo    string   `json:"codigo"`
	} `json:"deve_falhar"`
}

func openWrap(t *testing.T, ct, pub, sk []byte) []byte {
	t.Helper()
	var p, s [32]byte
	copy(p[:], pub)
	copy(s[:], sk)
	k, ok := box.OpenAnonymous(nil, ct, &p, &s)
	if !ok {
		t.Fatal("embrulho não abre")
	}
	return k
}

func TestGroupEpochVectors(t *testing.T) {
	e := loadGroupEnv(t)
	var v gEpoca
	var c gCadeia
	testvec.Load(t, "grupos/epoca", &v)
	testvec.Load(t, "grupos/cadeia", &c)
	conv := uuid(t, v.Conv)
	st, err := proto.VerifyChain(conv, signedRecs(t, c.Comum.Registros[:2]), e.keys)
	if err != nil {
		t.Fatal(err)
	}
	escrowPub := testvec.Hex(t, v.Escrow)
	keys := map[uint32][]byte{}
	for _, ep := range v.Epocas {
		K := testvec.Hex(t, ep.K)
		keys[ep.Epoch] = K
		cm := proto.EpochKeyCommitment(conv, ep.Epoch, K)
		eq(t, "commitment", cm[:], ep.Commitment)
		var rec, owners []proto.UUID
		for _, r := range ep.Recipients {
			id := uuid(t, r)
			rec = append(rec, id)
			owners = append(owners, e.keys.Certs[id].Cert.UserID)
		}
		var ch [32]byte
		copy(ch[:], testvec.Hex(t, ep.ChainHash))
		stmt := proto.GroupEpochBytes(conv, ep.Epoch, e.idOf["A"], cm[:], escrowPub, ep.ChainN, ch, rec)
		eq(t, "statement", stmt, ep.Stmt)
		if !proto.Verify(e.signOf["A"], stmt, testvec.Hex(t, ep.Sig)) {
			t.Error("assinatura da época")
		}
		if err := st.CheckGroupEpoch(ep.ChainN, ch, e.keys.Certs[e.idOf["A"]].Cert.UserID, owners); err != nil {
			t.Errorf("época %d: %v", ep.Epoch, err)
		}
		for _, w := range ep.Embrulhos {
			pub, sk := escrowPub, testvec.Hex(t, e.ch.Escrow.KexSK)
			if w.Destino != "escrow" {
				sc := e.keys.Certs[uuid(t, w.DeviceID)]
				pub, sk = sc.Cert.KexPub, e.kexSK[w.DeviceID]
			}
			if k := openWrap(t, testvec.Hex(t, w.WrappedKey), pub, sk); !bytes.Equal(k, K) {
				t.Errorf("embrulho %s", w.Destino)
			}
		}
		var mc [32]byte
		copy(mc[:], testvec.Hex(t, ep.Meta.Commit))
		if got := proto.MetaCommit(conv, []byte(ep.Meta.JSON)); got != mc {
			t.Error("meta_commit")
		}
		eq(t, "meta aad", proto.MetaAAD(conv, ep.Epoch, mc), ep.Meta.AAD)
		nonce := testvec.Hex(t, ep.Meta.Nonce)
		ct, err := proto.SealMeta(K, nonce, conv, ep.Epoch, []byte(ep.Meta.JSON))
		if err != nil {
			t.Fatal(err)
		}
		eq(t, "meta ciphertext", ct, ep.Meta.Ciphertext)
		m, err := proto.OpenMeta(K, nonce, ct, conv, ep.Epoch, mc)
		if err != nil || string(m) != ep.Meta.JSON {
			t.Errorf("OpenMeta: %v", err)
		}
		other := mc
		other[0] ^= 1
		if _, err := proto.OpenMeta(K, nonce, ct, conv, ep.Epoch, other); err == nil {
			t.Error("OpenMeta aceitou compromisso errado")
		}
		if _, err := proto.OpenMeta(K, nonce, ct, conv, ep.Epoch+1, mc); err == nil {
			t.Error("OpenMeta aceitou outra época")
		}
	}

	h := v.Historico
	sc := e.keys.Certs[uuid(t, h.DeviceID)]
	if k := openWrap(t, testvec.Hex(t, h.WrappedKey), sc.Cert.KexPub, e.kexSK[h.DeviceID]); !bytes.Equal(k, keys[h.Epoch]) {
		t.Error("histórico liberado")
	}
	if !st.MayRewrap(sc.Cert.UserID, 1) {
		t.Error("MayRewrap Marcos época 1")
	}

	for _, f := range v.Falhas {
		var ch [32]byte
		copy(ch[:], testvec.Hex(t, f.ChainHash))
		var owners []proto.UUID
		for _, o := range f.Owners {
			owners = append(owners, uuid(t, o))
		}
		err := st.CheckGroupEpoch(f.ChainN, ch, uuid(t, f.Creator), owners)
		if proto.CodeOf(err) != f.Codigo {
			t.Errorf("%s: %v, want %s", f.Caso, err, f.Codigo)
		}
	}
}

// ---- D11, revocation, QR ----

func TestSealedVectors(t *testing.T) {
	var v struct {
		Alfabeto string `json:"alfabeto"`
		Exemplos []struct {
			Len    int                 `json:"len_ciphertext"`
			SLen   int                 `json:"scramble_len"`
			Input  string              `json:"hash_entrada"`
			Selada proto.SealedMessage `json:"selada"`
		} `json:"exemplos"`
		Evento json.RawMessage `json:"evento_member_access"`
	}
	testvec.Load(t, "grupos/selada", &v)
	seen := map[rune]bool{}
	for _, r := range v.Alfabeto {
		seen[r] = true
	}
	if len(v.Alfabeto) != 64 || len(seen) != 64 {
		t.Fatalf("alfabeto com %d caracteres, %d distintos", len(v.Alfabeto), len(seen))
	}
	for _, x := range v.Exemplos {
		s := x.Selada
		got := proto.NewSealed(uuid(t, s.ConversationID), s.Seq, uuid(t, s.MessageID), uuid(t, s.SenderDeviceID),
			uuid(t, s.SenderUserID), s.CreatedAt, x.Len)
		if got != s || len(got.Scramble) != x.SLen || proto.ScrambleLen(x.Len) != x.SLen {
			t.Errorf("selada %d: %+v, want %+v", x.Len, got, s)
		}
		for _, r := range got.Scramble {
			if !seen[r] {
				t.Errorf("caractere fora do alfabeto: %q", r)
			}
		}
	}
	var ev proto.MemberAccessEvent
	if err := json.Unmarshal(v.Evento, &ev); err != nil || ev.Type != "member_access" || ev.Active || len(ev.Conversations) != 1 {
		t.Errorf("evento: %+v %v", ev, err)
	}
	if proto.ScrambleLen(16+256*64) != 32 || proto.ScrambleLen(0) != 12 {
		t.Error("ScrambleLen nos extremos")
	}
}

func TestSelfRevokeVectors(t *testing.T) {
	e := loadGroupEnv(t)
	var v struct {
		CreatedAt uint64                  `json:"created_at"`
		Bytes     string                  `json:"self_revoke_bytes"`
		Sig       string                  `json:"sig"`
		Req       proto.SelfRevokeRequest `json:"requisicao"`
		Falhas    []struct {
			Caso string                  `json:"caso"`
			Req  proto.SelfRevokeRequest `json:"requisicao"`
		} `json:"deve_falhar"`
	}
	testvec.Load(t, "grupos/revogacao", &v)
	srv := e.keys.ServerPub
	b := proto.SelfRevokeBytes(srv, e.idOf["A"], v.CreatedAt)
	eq(t, "self_revoke_bytes", b, v.Bytes)
	if len(b) != 78 {
		t.Errorf("tamanho %d", len(b))
	}
	if id, ok := proto.VerifySelfRevoke(srv, e.signOf["A"], v.Req); !ok || id != e.idOf["A"] {
		t.Error("revogação válida recusada")
	}
	for _, f := range v.Falhas {
		id, err := proto.ParseUUID(f.Req.DeviceID)
		if err != nil {
			t.Fatal(err)
		}
		pub := e.keys.Certs[id].Cert.SignPub // o servidor busca pelo device_id da requisição
		if _, ok := proto.VerifySelfRevoke(srv, pub, f.Req); ok {
			t.Errorf("%s: aceita", f.Caso)
		}
	}
	if _, ok := proto.VerifySelfRevoke(srv, e.signOf["A"], proto.SelfRevokeRequest{DeviceID: "X", Sig: v.Req.Sig}); ok {
		t.Error("device_id inválido aceito")
	}
}

func TestModQRVectors(t *testing.T) {
	e := loadGroupEnv(t)
	q := e.gc.QR
	srv, esc, mod := e.keys.ServerPub, testvec.Hex(t, e.ch.Escrow.KexPub), e.keys.ModPub
	if got := proto.InviteURIMod(q.Host, testvec.Hex(t, q.InviteSeed), srv, esc, mod); got != q.URI {
		t.Errorf("qr v2 = %s", got)
	}
	if got := proto.PinURI(q.Host, srv, esc, mod); got != q.Pin {
		t.Errorf("pin = %s", got)
	}
	if got := proto.ServerCodeMod(srv, esc, mod); got != q.Code || got == q.CodeV1 || len(got) != 23 {
		t.Errorf("código = %s", got)
	}
	if proto.ServerCode(srv, esc) != q.CodeV1 {
		t.Error("código v1")
	}
}

// TestBodyBuildersRoundTrip rebuilds every body of the valid chains from its parsed form.
func TestBodyBuildersRoundTrip(t *testing.T) {
	var v gCadeia
	testvec.Load(t, "grupos/cadeia", &v)
	for _, g := range []gGroup{v.Comum, v.Oficial} {
		for _, r := range g.Registros {
			body := testvec.Hex(t, r.Body)
			b, err := proto.ParseBody(r.Kind, body)
			if err != nil {
				t.Fatal(err)
			}
			var got []byte
			switch r.Kind {
			case proto.KindCreate:
				got = proto.CreateBody(b.AdminLabel, b.MetaCommit, b.Members)
			case proto.KindAdd:
				got = proto.AddBody(b.History, b.Users)
			case proto.KindRemove, proto.KindPromote:
				got = proto.UsersBody(b.Users)
			case proto.KindRename:
				got = proto.RenameBody(b.MetaCommit)
			}
			if !bytes.Equal(got, body) {
				t.Errorf("registro %d (kind %d): corpo refeito difere", r.N, r.Kind)
			}
		}
	}
}
