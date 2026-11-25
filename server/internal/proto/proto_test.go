package proto_test

import (
	"crypto/ed25519"
	"crypto/sha256"
	"strings"
	"testing"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/testvec"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
)

func uuid(t *testing.T, s string) proto.UUID {
	t.Helper()
	u, err := proto.ParseUUID(s)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func eq(t *testing.T, what string, got []byte, wantHex string) {
	t.Helper()
	if want := testvec.Hex(t, wantHex); string(got) != string(want) {
		t.Errorf("%s mismatch\n got %x\nwant %s", what, got, wantHex)
	}
}

func TestKeys(t *testing.T) {
	var ch testvec.Chaves
	testvec.Load(t, "chaves", &ch)
	eq(t, "server pub", ed25519.NewKeyFromSeed(testvec.Hex(t, ch.Servidor.SignSeed)).Public().(ed25519.PublicKey), ch.Servidor.SignPub)
	pub, _ := curve25519.X25519(testvec.Hex(t, ch.Escrow.KexSK), curve25519.Basepoint)
	eq(t, "escrow pub", pub, ch.Escrow.KexPub)
	for _, d := range ch.Aparelhos {
		eq(t, d.Nome+" sign pub", ed25519.NewKeyFromSeed(testvec.Hex(t, d.SignSeed)).Public().(ed25519.PublicKey), d.SignPub)
	}
}

func TestDeviceCode(t *testing.T) {
	var ch testvec.Chaves
	testvec.Load(t, "chaves", &ch)
	for _, d := range ch.Aparelhos {
		if got := proto.DeviceCode(testvec.Hex(t, d.SignPub), testvec.Hex(t, d.KexPub)); got != d.Codigo || len(got) != 23 {
			t.Errorf("device %s code %q want %q", d.Nome, got, d.Codigo)
		}
	}
}

func TestInvite(t *testing.T) {
	var c testvec.Convite
	testvec.Load(t, "convite", &c)
	eq(t, "invite pub", ed25519.NewKeyFromSeed(testvec.Hex(t, c.InviteSeed)).Public().(ed25519.PublicKey), c.InvitePub)
	sp, _ := proto.B64Decode(c.ServerB64u)
	ep, _ := proto.B64Decode(c.EscrowB64u)
	if got := proto.ServerCode(sp, ep); got != c.Codigo {
		t.Errorf("server code %q want %q", got, c.Codigo)
	}
}

func TestEnrollAndCerts(t *testing.T) {
	var ch testvec.Chaves
	var cad testvec.Cadastro
	testvec.Load(t, "chaves", &ch)
	testvec.Load(t, "cadastro", &cad)
	a := ch.Aparelhos[0]
	ip, sp, kp := testvec.Hex(t, cad.InvitePub), testvec.Hex(t, a.SignPub), testvec.Hex(t, a.KexPub)
	eb := proto.EnrollBytes(ip, sp, kp)
	eq(t, "enroll_bytes", eb, cad.EnrollB)
	if !proto.Verify(ip, eb, testvec.Hex(t, cad.InviteSig)) || !proto.Verify(sp, eb, testvec.Hex(t, cad.ProofSig)) {
		t.Error("invite_sig/proof do not verify")
	}
	// JSON request carries the same bytes in base64url.
	for k, want := range map[string][]byte{"invite_pub": ip, "sign_pub": sp, "kex_pub": kp} {
		if got, err := proto.B64Decode(cad.Req[k]); err != nil || string(got) != string(want) {
			t.Errorf("requisicao.%s", k)
		}
	}
	if proto.LowOrderX25519(kp) {
		t.Error("valid kex flagged as low order")
	}
	for _, h := range cad.LowOrder {
		if !proto.LowOrderX25519(testvec.Hex(t, h)) {
			t.Errorf("low-order point %s accepted", h)
		}
	}
	srv := testvec.Hex(t, ch.Servidor.SignPub)
	if len(cad.Certs) != 3 {
		t.Fatal("expected 3 certs")
	}
	for i, c := range cad.Certs {
		d := ch.Aparelhos[i]
		cert := proto.Cert{
			DeviceID: uuid(t, d.DeviceID), UserID: uuid(t, d.UserID),
			SignPub: testvec.Hex(t, d.SignPub), KexPub: testvec.Hex(t, d.KexPub),
			EnrolledAt: c.EnrolledAt, ExpiresAt: c.ExpiresAt, AdminLabel: d.AdminLabel,
		}
		cb := proto.CertBytes(cert)
		eq(t, d.Nome+" cert_bytes", cb, c.CertBytes)
		if !proto.Verify(srv, cb, testvec.Hex(t, c.CertSig)) {
			t.Errorf("%s cert sig invalid", d.Nome)
		}
		// Signing is deterministic: server must reproduce the exact signature.
		sig := ed25519.Sign(ed25519.NewKeyFromSeed(testvec.Hex(t, ch.Servidor.SignSeed)), cb)
		eq(t, d.Nome+" cert_sig", sig, c.CertSig)
	}
}

func TestLogin(t *testing.T) {
	var ch testvec.Chaves
	var l testvec.Login
	testvec.Load(t, "chaves", &ch)
	testvec.Load(t, "login", &l)
	a := ch.Aparelhos[0]
	srv := testvec.Hex(t, ch.Servidor.SignPub)
	chal := testvec.Hex(t, l.Challenge)
	ab := proto.AuthBytes(srv, uuid(t, a.DeviceID), chal)
	eq(t, "auth_bytes", ab, l.AuthBytes)
	if !proto.Verify(testvec.Hex(t, a.SignPub), ab, testvec.Hex(t, l.AuthSig)) {
		t.Error("auth sig invalid")
	}
	tok, err := proto.B64Decode(l.TokenB64u)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "token hash", proto.TokenHash(tok), l.TokenHash)
	rb := proto.RevokedBytes(uuid(t, a.DeviceID), chal)
	eq(t, "revoked_bytes", rb, l.RevBytes)
	if !proto.Verify(srv, rb, testvec.Hex(t, l.RevSig)) {
		t.Error("revoked sig invalid")
	}
}

func TestEpoch(t *testing.T) {
	var ch testvec.Chaves
	var e testvec.Epoca
	testvec.Load(t, "chaves", &ch)
	testvec.Load(t, "epoca", &e)
	conv := uuid(t, e.ConversationID)
	commit := proto.EpochKeyCommitment(conv, e.Epoch, testvec.Hex(t, e.Key))
	eq(t, "commitment", commit[:], e.Commitment)
	var rec []proto.UUID
	for _, r := range e.Recipients {
		rec = append(rec, uuid(t, r))
	}
	a := ch.Aparelhos[0]
	eb := proto.EpochBytes(conv, e.Epoch, uuid(t, a.DeviceID), commit[:], testvec.Hex(t, ch.Escrow.KexPub), rec)
	eq(t, "statement_bytes", eb, e.StatementBytes)
	if !proto.Verify(testvec.Hex(t, a.SignPub), eb, testvec.Hex(t, e.StatementSig)) {
		t.Error("epoch signature invalid")
	}
	// A different escrow_pub must break the signature (section 9.3).
	bad := proto.EpochBytes(conv, e.Epoch, uuid(t, a.DeviceID), commit[:], testvec.Hex(t, ch.Servidor.SignPub), rec)
	if proto.Verify(testvec.Hex(t, a.SignPub), bad, testvec.Hex(t, e.StatementSig)) {
		t.Error("signature verified with wrong escrow_pub")
	}
}

func TestMessage(t *testing.T) {
	var ch testvec.Chaves
	var m testvec.Mensagem
	testvec.Load(t, "chaves", &ch)
	testvec.Load(t, "mensagem", &m)
	a, b := ch.Aparelhos[0], ch.Aparelhos[1]
	hdr := proto.MsgHeader(uuid(t, m.ConversationID), m.Epoch, uuid(t, a.DeviceID), uuid(t, m.MessageID), m.SentAt)
	eq(t, "header", hdr, m.Header)
	eq(t, "aad", proto.MsgAAD(hdr), m.AAD)
	sb := proto.MsgSigBytes(hdr, testvec.Hex(t, m.Nonce), testvec.Hex(t, m.Ciphertext))
	eq(t, "sig bytes", sb, m.SigBytes)
	if !proto.Verify(testvec.Hex(t, a.SignPub), sb, testvec.Hex(t, m.Signature)) {
		t.Error("message signature invalid")
	}
	if proto.Verify(testvec.Hex(t, b.SignPub), sb, testvec.Hex(t, m.Signature)) {
		t.Error("message signature verified with B's key")
	}
	bad := append([]byte(nil), testvec.Hex(t, m.Signature)...)
	bad[0] ^= 1
	if proto.Verify(testvec.Hex(t, a.SignPub), sb, bad) {
		t.Error("tampered signature verified")
	}
}

func TestEncodingStrictness(t *testing.T) {
	for _, s := range []string{"AA==", "AA\n", "A", "AB", "AA+/", " AA"} {
		if _, err := proto.B64Decode(s); err == nil {
			t.Errorf("B64Decode(%q) accepted", s)
		}
	}
	if b, err := proto.B64Decode("_-8"); err != nil || len(b) != 2 {
		t.Errorf("valid input rejected: %v", err)
	}
	for _, s := range []string{
		strings.ToUpper("a3a1e2f4-5b6d-4e7f-8a9b-0c1d2e3f4a5b"),
		"a3a1e2f45b6d4e7f8a9b0c1d2e3f4a5b0000",
		"a3a1e2f4-5b6d-4e7f-8a9b-0c1d2e3f4a5",
		"g3a1e2f4-5b6d-4e7f-8a9b-0c1d2e3f4a5b",
	} {
		if _, err := proto.ParseUUID(s); err == nil {
			t.Errorf("ParseUUID(%q) accepted", s)
		}
	}
	u := uuid(t, "c3a1e2f4-5b6d-4e7f-8a9b-0c1d2e3f4a5b")
	if proto.FormatUUID(u) != "c3a1e2f4-5b6d-4e7f-8a9b-0c1d2e3f4a5b" {
		t.Error("uuid round trip")
	}
}

// TestAttachmentVectors checks docs/vetores/anexo.json (protocolo.md, seção 18): the blob, its
// hash, the image message that points to it, and the cases that must fail.
func TestAttachmentVectors(t *testing.T) {
	var ch testvec.Chaves
	testvec.Load(t, "chaves", &ch)
	var an struct {
		ConversationID string `json:"conversation_id"`
		Key            string `json:"chave_blob"`
		Image          string `json:"imagem_bytes"`
		AAD            string `json:"aad_blob"`
		Blob           string `json:"blob"`
		BlobSHA256     string `json:"blob_sha256"`
		BlobID         string `json:"blob_id"`
		Msg            struct {
			MessageID string `json:"message_id"`
			SentAt    uint64 `json:"sent_at"`
			Epoch     uint32 `json:"epoch"`
			Key       string `json:"chave_epoca"`
			Plain     string `json:"texto_claro_bytes"`
			Padded    string `json:"texto_preenchido"`
			Nonce     string `json:"nonce"`
			AAD       string `json:"aad"`
			CT        string `json:"ciphertext"`
			SigBytes  string `json:"assinado_bytes"`
			Sig       string `json:"signature"`
		} `json:"mensagem"`
		Fail []struct {
			Blob string `json:"blob"`
			AAD  string `json:"aad"`
			Sum  string `json:"blob_sha256_esperado"`
		} `json:"deve_falhar"`
	}
	testvec.Load(t, "anexo", &an)
	conv := uuid(t, an.ConversationID)
	aad := append([]byte("direct/v1/blob\x00"), conv[:]...)
	eq(t, "blob aad", aad, an.AAD)
	blob := testvec.Hex(t, an.Blob)
	sum := sha256.Sum256(blob)
	eq(t, "blob sha256", sum[:], an.BlobSHA256)
	aead, err := chacha20poly1305.NewX(testvec.Hex(t, an.Key))
	if err != nil {
		t.Fatal(err)
	}
	img, err := aead.Open(nil, blob[:24], blob[24:], aad)
	if err != nil {
		t.Fatalf("open blob: %v", err)
	}
	eq(t, "image bytes", img, an.Image)

	// The image message goes through the ordinary message pipeline (seção 10).
	m := an.Msg
	hdr := proto.MsgHeader(conv, m.Epoch, uuid(t, ch.Aparelhos[0].DeviceID), uuid(t, m.MessageID), m.SentAt)
	eq(t, "msg aad", proto.MsgAAD(hdr), m.AAD)
	sb := proto.MsgSigBytes(hdr, testvec.Hex(t, m.Nonce), testvec.Hex(t, m.CT))
	eq(t, "msg sig bytes", sb, m.SigBytes)
	if !proto.Verify(testvec.Hex(t, ch.Aparelhos[0].SignPub), sb, testvec.Hex(t, m.Sig)) {
		t.Error("image message signature invalid")
	}
	maead, _ := chacha20poly1305.NewX(testvec.Hex(t, m.Key))
	padded, err := maead.Open(nil, testvec.Hex(t, m.Nonce), testvec.Hex(t, m.CT), proto.MsgAAD(hdr))
	if err != nil {
		t.Fatalf("open image message: %v", err)
	}
	eq(t, "padded", padded, m.Padded)
	for i, f := range an.Fail {
		b := testvec.Hex(t, f.Blob)
		if f.AAD != "" {
			if _, err := aead.Open(nil, b[:24], b[24:], testvec.Hex(t, f.AAD)); err == nil {
				t.Errorf("fail case %d opened", i)
			}
		} else if s := sha256.Sum256(b); string(s[:]) == string(testvec.Hex(t, f.Sum)) {
			t.Errorf("fail case %d: hash matched", i)
		}
	}
}
