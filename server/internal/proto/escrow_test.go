package proto

import (
	"bytes"
	"errors"
	"testing"

	"github.com/nettotech/direct/server/internal/testvec"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

func TestEscrowVectors(t *testing.T) {
	var v struct {
		File struct {
			Password string `json:"senha_utf8"`
			Salt     string `json:"salt"`
			Nonce    string `json:"nonce"`
			Content  string `json:"conteudo_arquivo"`
			SK       string `json:"escrow_sk"`
			Pub      string `json:"escrow_pub"`
		} `json:"arquivo"`
		Rewrap struct {
			Conv       string `json:"conversation_id"`
			Epoch      uint32 `json:"epoch"`
			Wrap       string `json:"escrow_wrap"`
			Key        string `json:"chave_epoca"`
			Commitment string `json:"key_commitment"`
		} `json:"rewrap"`
	}
	testvec.Load(t, "escrow", &v)
	hx := func(s string) []byte { return testvec.Hex(t, s) }
	sk, pw, file := hx(v.File.SK), []byte(v.File.Password), hx(v.File.Content)

	got, err := sealEscrow(sk, pw, hx(v.File.Salt), hx(v.File.Nonce))
	if err != nil || !bytes.Equal(got, file) {
		t.Fatalf("seal differs from vector: %x %v", got, err)
	}
	open, err := OpenEscrow(file, pw)
	if err != nil || !bytes.Equal(open, sk) {
		t.Fatalf("open: %v", err)
	}
	if _, err := OpenEscrow(file, []byte("errada")); !errors.Is(err, ErrEscrowOpen) {
		t.Fatalf("wrong password: %v", err)
	}
	huge := bytes.Clone(file)
	huge[20] = 0xff // memlimit way above the cap: refused before Argon2id runs
	if _, err := OpenEscrow(huge, pw); !errors.Is(err, ErrFormat) {
		t.Fatalf("memlimit cap: %v", err)
	}

	pub, _ := curve25519.X25519(sk, curve25519.Basepoint)
	if !bytes.Equal(pub, hx(v.File.Pub)) {
		t.Fatal("escrow_pub")
	}
	var pk, k [32]byte
	copy(pk[:], pub)
	copy(k[:], sk)
	ek, ok := box.OpenAnonymous(nil, hx(v.Rewrap.Wrap), &pk, &k)
	if !ok || !bytes.Equal(ek, hx(v.Rewrap.Key)) {
		t.Fatal("libsodium sealed box does not open")
	}
	conv, err := ParseUUID(v.Rewrap.Conv)
	if err != nil {
		t.Fatal(err)
	}
	c := EpochKeyCommitment(conv, v.Rewrap.Epoch, ek)
	if !bytes.Equal(c[:], hx(v.Rewrap.Commitment)) {
		t.Fatal("commitment")
	}
}

func TestInviteURI(t *testing.T) {
	var c testvec.Convite
	testvec.Load(t, "convite", &c)
	var q struct {
		Host string `json:"host"`
		URI  string `json:"qr_uri"`
	}
	testvec.Load(t, "convite", &q)
	srv, _ := B64Decode(c.ServerB64u)
	esc, _ := B64Decode(c.EscrowB64u)
	if got := InviteURI(q.Host, testvec.Hex(t, c.InviteSeed), srv, esc); got != q.URI {
		t.Fatalf("uri: %s", got)
	}
	for _, bad := range []string{"", "A.com", "a.com.", "a.com:443", "a b", "a/b"} {
		if ValidHost(bad) {
			t.Fatalf("host %q accepted", bad)
		}
	}
}
