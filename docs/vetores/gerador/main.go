// Gerador dos vetores de teste do protocolo Direct v1 (docs/protocolo.md).
//
// Uso: go run . <pasta-de-saída>
//
// Todas as entradas são fixas (derivadas de nomes com BLAKE2b-256), então a saída é
// idêntica a cada execução. Qualquer divergência entre este programa e a especificação
// é bug: a especificação manda.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/blake2b"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

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

func write(dir, name string, v any) {
	b, err := enc(v)
	must(err)
	var out bytes.Buffer
	must(json.Indent(&out, b, "", "  "))
	out.WriteByte('\n')
	must(os.WriteFile(filepath.Join(dir, name), out.Bytes(), 0o644))
}

// ---------- utilitários ----------

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func check(ok bool, what string) {
	if !ok {
		panic("autoverificação falhou: " + what)
	}
}

func hx(b []byte) string  { return hex.EncodeToString(b) }
func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func cat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func u32(n uint32) []byte { b := make([]byte, 4); binary.BigEndian.PutUint32(b, n); return b }
func u64(n uint64) []byte { b := make([]byte, 8); binary.BigEndian.PutUint64(b, n); return b }

// lp = campo de tamanho variável: u32 big-endian com o tamanho, depois os bytes.
func lp(b []byte) []byte { return cat(u32(uint32(len(b))), b) }

// label = rótulo de domínio ASCII terminado em 0x00.
func label(s string) []byte { return append([]byte(s), 0) }

func uuidBytes(s string) []byte {
	b, err := hex.DecodeString(strings.ReplaceAll(s, "-", ""))
	must(err)
	check(len(b) == 16, "uuid "+s)
	return b
}

// seed deriva 32 bytes fixos a partir de um nome (só para vetores).
func seed(name string) []byte {
	h := blake2b.Sum256([]byte("direct/test-vector/" + name))
	return h[:]
}

func x25519Pub(sk []byte) []byte {
	pk, err := curve25519.X25519(sk, curve25519.Basepoint)
	must(err)
	return pk
}

func k32(b []byte) *[32]byte { var a [32]byte; copy(a[:], b); return &a }

// seal = crypto_box_seal com chave efêmera fixa (só para vetores).
func seal(msg, recipientPub, ephSK []byte) []byte {
	out, err := box.SealAnonymous(nil, msg, k32(recipientPub), bytes.NewReader(ephSK))
	must(err)
	return out
}

func open(ct, pub, sk []byte) ([]byte, bool) {
	return box.OpenAnonymous(nil, ct, k32(pub), k32(sk))
}

func blake256(parts ...[]byte) []byte {
	h := blake2b.Sum256(cat(parts...))
	return h[:]
}

// pad = sodium_pad (ISO/IEC 7816-4): 0x80 e zeros até múltiplo de bs; sempre acrescenta ao menos 1 byte.
func pad(b []byte, bs int) []byte {
	out := append(append([]byte{}, b...), 0x80)
	for len(out)%bs != 0 {
		out = append(out, 0)
	}
	return out
}

func unpad(b []byte, bs int) ([]byte, bool) {
	if len(b) == 0 || len(b)%bs != 0 {
		return nil, false
	}
	i := len(b) - 1
	for i >= 0 && b[i] == 0 {
		i--
	}
	if i < 0 || b[i] != 0x80 || len(b)-i > bs {
		return nil, false
	}
	return b[:i], true
}

// codigoServidor = 4 grupos de 5 dígitos a partir dos 20 primeiros bytes do hash.
func codigoServidor(h []byte) string {
	var grupos []string
	for i := 0; i < 4; i++ {
		var v uint64
		for _, c := range h[i*5 : i*5+5] {
			v = v<<8 | uint64(c)
		}
		grupos = append(grupos, fmt.Sprintf("%05d", v%100000))
	}
	return strings.Join(grupos, " ")
}

// ---------- entidades fixas ----------

type device struct {
	nome     string
	id, user []byte
	idStr    string
	userStr  string
	label    string
	signSeed []byte
	signPriv ed25519.PrivateKey
	signPub  []byte
	kexSK    []byte
	kexPK    []byte
	enrolled uint64
	expires  uint64
}

func newDevice(nome, id, user, lbl string, enrolled uint64) *device {
	d := &device{nome: nome, idStr: id, userStr: user, id: uuidBytes(id), user: uuidBytes(user), label: lbl}
	d.signSeed = seed("aparelho/" + nome + "/sign")
	d.signPriv = ed25519.NewKeyFromSeed(d.signSeed)
	d.signPub = d.signPriv.Public().(ed25519.PublicKey)
	d.kexSK = seed("aparelho/" + nome + "/kex")
	d.kexPK = x25519Pub(d.kexSK)
	d.enrolled = enrolled
	d.expires = enrolled + 180*86400*1000
	return d
}

func (d *device) keys() O {
	return O{
		{"nome", d.nome},
		{"device_id", d.idStr},
		{"user_id", d.userStr},
		{"admin_label", d.label},
		{"sign_seed", hx(d.signSeed)},
		{"sign_sk_libsodium", hx(d.signPriv)},
		{"sign_pub", hx(d.signPub)},
		{"kex_sk", hx(d.kexSK)},
		{"kex_pub", hx(d.kexPK)},
		{"codigo_aparelho", codigoServidor(blake256(label("direct/v1/device-code"), d.signPub, d.kexPK))},
	}
}

func certBytes(d *device) []byte {
	return cat(label("direct/v1/device-cert"), d.id, d.user, d.signPub, d.kexPK,
		u64(d.enrolled), u64(d.expires), lp([]byte(d.label)))
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "uso: go run . <pasta-de-saída>")
		os.Exit(2)
	}
	dir := os.Args[1]
	must(os.MkdirAll(dir, 0o755))

	// Servidor e escrow.
	srvSeed := seed("servidor/sign")
	srvPriv := ed25519.NewKeyFromSeed(srvSeed)
	srvPub := []byte(srvPriv.Public().(ed25519.PublicKey))
	escSK := seed("escrow/kex")
	escPK := x25519Pub(escSK)

	const t0 = uint64(1795000000000) // ms
	A := newDevice("A", "c3a1e2f4-5b6d-4e7f-8a9b-0c1d2e3f4a5b", "7d0c9b8a-1e2f-4a3b-9c4d-5e6f7a8b9c0d", "Ana Souza - Diretoria", t0)
	B := newDevice("B", "1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9", "2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d", "João - Financeiro", t0+3600000)
	C := newDevice("C", "8e7d6c5b-4a39-4281-b7c6-d5e4f3a2b1c0", B.userStr, B.label, t0+30*86400000)

	// ---------- chaves.json ----------
	write(dir, "chaves.json", O{
		{"descricao", "Chaves fixas usadas por todos os vetores. sign_sk_libsodium = seed||pub (64 bytes), igual a crypto_sign_seed_keypair e a ed25519.NewKeyFromSeed."},
		{"servidor", O{{"sign_seed", hx(srvSeed)}, {"sign_sk_libsodium", hx(srvPriv)}, {"sign_pub", hx(srvPub)}}},
		{"escrow", O{{"kex_sk", hx(escSK)}, {"kex_pub", hx(escPK)}}},
		{"aparelhos", []O{A.keys(), B.keys(), C.keys()}},
	})

	// ---------- convite.json ----------
	host := "direct.exemplo.com.br"
	inviteSeed := seed("convite/seed")
	invitePriv := ed25519.NewKeyFromSeed(inviteSeed)
	invitePub := []byte(invitePriv.Public().(ed25519.PublicKey))
	token := inviteSeed // o "token" do QR é a semente Ed25519 do convite
	uri := "direct://enroll?v=1&h=" + host + "&t=" + b64(token) + "&s=" + b64(srvPub) + "&e=" + b64(escPK)
	codeInput := cat(label("direct/v1/server-code"), srvPub, escPK)
	codeHash := blake256(codeInput)
	code := codigoServidor(codeHash)
	write(dir, "convite.json", O{
		{"host", host},
		{"invite_seed", hx(inviteSeed)},
		{"invite_seed_b64u", b64(inviteSeed)},
		{"invite_pub", hx(invitePub)},
		{"invite_pub_b64u", b64(invitePub)},
		{"server_sign_pub_b64u", b64(srvPub)},
		{"escrow_pub_b64u", b64(escPK)},
		{"qr_uri", uri},
		{"codigo_entrada", hx(codeInput)},
		{"codigo_blake2b256", hx(codeHash)},
		{"codigo_verificacao", code},
		{"qr_invalidos", []O{
			{{"uri", "direct://enroll?v=2&h=" + host + "&t=" + b64(token) + "&s=" + b64(srvPub) + "&e=" + b64(escPK)}, {"motivo", "versão desconhecida"}},
			{{"uri", "direct://enroll?v=1&h=" + host + "&t=" + b64(token) + "=&s=" + b64(srvPub) + "&e=" + b64(escPK)}, {"motivo", "base64url com padding"}},
			{{"uri", "direct://enroll?v=1&h=" + host + "&t=" + b64(token[:31]) + "&s=" + b64(srvPub) + "&e=" + b64(escPK)}, {"motivo", "token com 31 bytes"}},
			{{"uri", "direct://enroll?v=1&h=" + host + "&h=evil.example&t=" + b64(token) + "&s=" + b64(srvPub) + "&e=" + b64(escPK)}, {"motivo", "parâmetro repetido"}},
			{{"uri", "direct://enroll?v=1&h=Direct.Exemplo.com.br&t=" + b64(token) + "&s=" + b64(srvPub) + "&e=" + b64(escPK)}, {"motivo", "host com maiúscula"}},
		}},
	})

	// ---------- cadastro.json ----------
	enrollMsg := cat(label("direct/v1/enroll"), invitePub, A.signPub, A.kexPK)
	inviteSig := ed25519.Sign(invitePriv, enrollMsg)
	proofSig := ed25519.Sign(A.signPriv, enrollMsg)
	certs := []O{}
	for _, d := range []*device{A, B, C} {
		cb := certBytes(d)
		sig := ed25519.Sign(srvPriv, cb)
		check(ed25519.Verify(srvPub, cb, sig), "cert "+d.nome)
		certs = append(certs, O{
			{"aparelho", d.nome},
			{"enrolled_at", d.enrolled},
			{"expires_at", d.expires},
			{"cert_bytes", hx(cb)},
			{"cert_sig", hx(sig)},
			{"json", O{
				{"device_id", d.idStr}, {"user_id", d.userStr}, {"admin_label", d.label},
				{"sign_pub", b64(d.signPub)}, {"kex_pub", b64(d.kexPK)},
				{"enrolled_at", d.enrolled}, {"expires_at", d.expires}, {"sig", b64(sig)},
			}},
		})
	}
	// Pontos X25519 de ordem baixa: o servidor deve recusar como kex_pub.
	lowOrder := []string{
		"0000000000000000000000000000000000000000000000000000000000000000",
		"0100000000000000000000000000000000000000000000000000000000000000",
		"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
		"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
	}
	for _, p := range lowOrder {
		pb, _ := hex.DecodeString(p)
		_, err := curve25519.X25519(seed("teste/escalar"), pb)
		check(err != nil, "ponto de ordem baixa aceito: "+p)
	}
	write(dir, "cadastro.json", O{
		{"aparelho", "A"},
		{"invite_seed", hx(inviteSeed)},
		{"invite_pub", hx(invitePub)},
		{"enroll_bytes", hx(enrollMsg)},
		{"invite_sig", hx(inviteSig)},
		{"proof_sig", hx(proofSig)},
		{"requisicao", O{
			{"invite_pub", b64(invitePub)}, {"sign_pub", b64(A.signPub)}, {"kex_pub", b64(A.kexPK)},
			{"platform", "android"}, {"model", "Pixel 8"}, {"os_version", "15"}, {"app_version", "1.0.0"},
			{"invite_sig", b64(inviteSig)}, {"proof", b64(proofSig)},
		}},
		{"certificados", certs},
		{"kex_pub_ordem_baixa", lowOrder},
	})

	// ---------- login.json ----------
	challenge := seed("login/challenge")
	authMsg := cat(label("direct/v1/auth"), srvPub, A.id, challenge)
	authSig := ed25519.Sign(A.signPriv, authMsg)
	accessToken := seed("login/access-token")
	revokedMsg := cat(label("direct/v1/revoked"), A.id, challenge)
	revokedSig := ed25519.Sign(srvPriv, revokedMsg)
	write(dir, "login.json", O{
		{"aparelho", "A"},
		{"challenge", hx(challenge)},
		{"auth_bytes", hx(authMsg)},
		{"auth_sig", hx(authSig)},
		{"requisicao_verify", O{{"device_id", A.idStr}, {"challenge", b64(challenge)}, {"sig", b64(authSig)}}},
		{"access_token", hx(accessToken)},
		{"access_token_b64u", b64(accessToken)},
		{"access_token_hash_sha256", hx(func() []byte { h := sha256.Sum256(accessToken); return h[:] }())},
		{"revogado_bytes", hx(revokedMsg)},
		{"revogado_sig", hx(revokedSig)},
	})

	// ---------- epoca.json ----------
	convStr := "a0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d"
	conv := uuidBytes(convStr)
	const epoch = uint32(1)
	K := seed("epoca/1/chave")
	commit := blake256(label("direct/v1/epoch-key"), conv, u32(epoch), K)
	recips := [][]byte{A.id, B.id}
	sort.Slice(recips, func(i, j int) bool { return bytes.Compare(recips[i], recips[j]) < 0 })
	stmt := cat(label("direct/v1/epoch"), conv, u32(epoch), A.id, commit, escPK, u32(uint32(len(recips))))
	for _, r := range recips {
		stmt = append(stmt, r...)
	}
	stmtSig := ed25519.Sign(A.signPriv, stmt)
	type wrapv struct {
		dest    string
		destID  string
		pub, sk []byte
		ephName string
	}
	wraps := []O{}
	var escrowWrap []byte
	for _, w := range []wrapv{
		{"A", A.idStr, A.kexPK, A.kexSK, "epoca/1/eph/A"},
		{"B", B.idStr, B.kexPK, B.kexSK, "epoca/1/eph/B"},
		{"escrow", "", escPK, escSK, "epoca/1/eph/escrow"},
	} {
		eph := seed(w.ephName)
		ct := seal(K, w.pub, eph)
		check(len(ct) == 80, "tamanho do embrulho")
		pt, ok := open(ct, w.pub, w.sk)
		check(ok && bytes.Equal(pt, K), "abrir embrulho "+w.dest)
		if w.dest == "escrow" {
			escrowWrap = ct
		}
		wraps = append(wraps, O{
			{"destino", w.dest}, {"device_id", w.destID},
			{"eph_sk", hx(eph)}, {"eph_pub", hx(x25519Pub(eph))},
			{"wrapped_key", hx(ct)},
		})
	}
	recipStrs := []string{}
	for _, r := range recips {
		recipStrs = append(recipStrs, fmt.Sprintf("%x-%x-%x-%x-%x", r[0:4], r[4:6], r[6:8], r[8:10], r[10:16]))
	}
	write(dir, "epoca.json", O{
		{"conversation_id", convStr},
		{"epoch", epoch},
		{"criador", "A"},
		{"chave_epoca", hx(K)},
		{"key_commitment_entrada", hx(cat(label("direct/v1/epoch-key"), conv, u32(epoch), K))},
		{"key_commitment", hx(commit)},
		{"recipients_ordenados", recipStrs},
		{"statement_bytes", hx(stmt)},
		{"statement_sig", hx(stmtSig)},
		{"embrulhos", wraps},
		{"nota_selagem", "Selagem com chave efêmera fixa só existe no gerador (Go). Em Dart/libsodium o teste é abrir wrapped_key com kex_sk e obter chave_epoca; e reconstruir eph_pub||crypto_box_easy(chave, nonce=BLAKE2b-192(eph_pub||pub_destino), pub_destino, eph_sk) se a API permitir."},
	})

	// ---------- mensagem.json ----------
	msgIDStr := "6f1e2d3c-4b5a-4968-a7b6-c5d4e3f2a1b0"
	msgID := uuidBytes(msgIDStr)
	sentAt := uint64(1795600000123)
	plain := []byte(`{"type":"text","text":"Olá, João! Reunião às 15h ✅"}`)
	padded := pad(plain, 256)
	up, ok := unpad(padded, 256)
	check(ok && bytes.Equal(up, plain), "unpad")
	nonce := seed("mensagem/1/nonce")[:24]
	header := cat(conv, u32(epoch), A.id, msgID, u64(sentAt))
	check(len(header) == 60, "cabeçalho 60 bytes")
	aad := cat(label("direct/v1/msg"), header)
	aead, err := chacha20poly1305.NewX(K)
	must(err)
	ct := aead.Seal(nil, nonce, padded, aad)
	sigIn := cat(label("direct/v1/msg-sig"), header, nonce, lp(ct))
	msgSig := ed25519.Sign(A.signPriv, sigIn)

	// Casos que devem falhar.
	ctBad := append([]byte{}, ct...)
	ctBad[len(ctBad)-1] ^= 0x01
	_, err = aead.Open(nil, nonce, ctBad, aad)
	check(err != nil, "ct adulterado abriu")
	aadB := cat(label("direct/v1/msg"), conv, u32(epoch), B.id, msgID, u64(sentAt))
	_, err = aead.Open(nil, nonce, ct, aadB)
	check(err != nil, "aad com outro remetente abriu")
	check(!ed25519.Verify(B.signPub, sigIn, msgSig), "assinatura verificou com chave errada")
	conv2 := uuidBytes("ffffffff-e4f5-4a6b-8c7d-9e0f1a2b3c4d")
	aadConv := cat(label("direct/v1/msg"), conv2, u32(epoch), A.id, msgID, u64(sentAt))
	_, err = aead.Open(nil, nonce, ct, aadConv)
	check(err != nil, "aad com outra conversa abriu")

	padCases := []O{}
	for _, n := range []int{0, 1, 255, 256, 257} {
		in := bytes.Repeat([]byte{0x61}, n)
		p := pad(in, 256)
		padCases = append(padCases, O{{"entrada_len", n}, {"saida_len", len(p)}, {"saida_ultimos_bytes", hx(p[len(p)-min(len(p), 4):])}})
	}

	write(dir, "mensagem.json", O{
		{"conversation_id", convStr},
		{"epoch", epoch},
		{"remetente", "A"},
		{"message_id", msgIDStr},
		{"sent_at", sentAt},
		{"chave_epoca", hx(K)},
		{"texto_claro", string(plain)},
		{"texto_claro_bytes", hx(plain)},
		{"texto_preenchido", hx(padded)},
		{"nonce", hx(nonce)},
		{"cabecalho", hx(header)},
		{"aad", hx(aad)},
		{"ciphertext", hx(ct)},
		{"assinado_bytes", hx(sigIn)},
		{"signature", hx(msgSig)},
		{"quadro_ws_send", O{
			{"type", "send"}, {"req_id", "r1"},
			{"message", O{
				{"conversation_id", convStr}, {"epoch", epoch}, {"sender_device_id", A.idStr},
				{"message_id", msgIDStr}, {"sent_at", sentAt},
				{"nonce", b64(nonce)}, {"ciphertext", b64(ct)}, {"signature", b64(msgSig)},
			}},
		}},
		{"deve_falhar", []O{
			{{"caso", "ciphertext com último bit trocado"}, {"ciphertext", hx(ctBad)}, {"aad", hx(aad)}},
			{{"caso", "aad com sender_device_id de B"}, {"ciphertext", hx(ct)}, {"aad", hx(aadB)}},
			{{"caso", "aad com outra conversation_id"}, {"ciphertext", hx(ct)}, {"aad", hx(aadConv)}},
			{{"caso", "assinatura conferida com sign_pub de B"}, {"sign_pub", hx(B.signPub)}, {"assinado_bytes", hx(sigIn)}, {"signature", hx(msgSig)}},
		}},
		{"preenchimento_bloco_256", padCases},
	})

	// ---------- anexo.json (protocolo.md, Anexos) ----------
	blobKey := seed("anexo/chave")
	blobNonce := seed("anexo/nonce")[:24]
	// Bytes quaisquer no lugar de um JPEG: a cifra não os interpreta.
	imgPlain := append([]byte{0xff, 0xd8, 0xff, 0xe0}, bytes.Repeat([]byte("Direct imagem de teste "), 12)...)
	imgPlain = append(imgPlain, 0xff, 0xd9)
	blobAAD := cat(label("direct/v1/blob"), conv)
	blobAEAD, err := chacha20poly1305.NewX(blobKey)
	must(err)
	blobCT := blobAEAD.Seal(nil, blobNonce, imgPlain, blobAAD)
	blob := cat(blobNonce, blobCT)
	blobSum := sha256.Sum256(blob)
	check(len(blob) == 24+len(imgPlain)+16, "tamanho do blob")
	thumb := append([]byte{0xff, 0xd8, 0xff, 0xe0}, bytes.Repeat([]byte("miniatura "), 5)...)
	thumb = append(thumb, 0xff, 0xd9)
	blobIDStr := "0b9a8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d"
	imgMsgStr := "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6e"
	imgSentAt := uint64(1795600060456)
	imgMsgID := uuidBytes(imgMsgStr)
	imgJSON := []byte(fmt.Sprintf(`{"type":"image","blob_id":%q,"key":%q,"sha256":%q,"mime":"image/jpeg","w":1536,"h":2048,"thumb":%q}`,
		blobIDStr, b64(blobKey), b64(blobSum[:]), b64(thumb)))
	imgPadded := pad(imgJSON, 256)
	imgNonce := seed("anexo/mensagem/nonce")[:24]
	imgHeader := cat(conv, u32(epoch), A.id, imgMsgID, u64(imgSentAt))
	imgAAD := cat(label("direct/v1/msg"), imgHeader)
	imgCT := aead.Seal(nil, imgNonce, imgPadded, imgAAD)
	imgSigIn := cat(label("direct/v1/msg-sig"), imgHeader, imgNonce, lp(imgCT))
	imgSig := ed25519.Sign(A.signPriv, imgSigIn)

	blobBad := append([]byte{}, blob...)
	blobBad[len(blobBad)-1] ^= 0x01
	_, err = blobAEAD.Open(nil, blobNonce, blobBad[24:], blobAAD)
	check(err != nil, "blob adulterado abriu")
	_, err = blobAEAD.Open(nil, blobNonce, blobCT, cat(label("direct/v1/blob"), conv2))
	check(err != nil, "blob abriu com outra conversa")
	blobSumBad := sha256.Sum256(blobBad)
	check(!bytes.Equal(blobSumBad[:], blobSum[:]), "hash do blob adulterado igual")
	saveAt := "2026-11-24T18:30:05Z"
	saveID := "5c4b3a29-1807-4f6e-8d5c-4b3a29180716"
	exif := fmt.Sprintf("Direct save_id=%s user=%s device=%s at=%s", saveID, B.userStr, B.idStr, saveAt)

	write(dir, "anexo.json", O{
		{"conversation_id", convStr},
		{"chave_blob", hx(blobKey)},
		{"nonce_blob", hx(blobNonce)},
		{"imagem_bytes", hx(imgPlain)},
		{"aad_blob", hx(blobAAD)},
		{"blob", hx(blob)},
		{"blob_sha256", hx(blobSum[:])},
		{"blob_id", blobIDStr},
		{"miniatura_bytes", hx(thumb)},
		{"mensagem", O{
			{"message_id", imgMsgStr},
			{"sent_at", imgSentAt},
			{"epoch", epoch},
			{"remetente", "A"},
			{"chave_epoca", hx(K)},
			{"texto_claro", string(imgJSON)},
			{"texto_claro_bytes", hx(imgJSON)},
			{"texto_preenchido", hx(imgPadded)},
			{"nonce", hx(imgNonce)},
			{"cabecalho", hx(imgHeader)},
			{"aad", hx(imgAAD)},
			{"ciphertext", hx(imgCT)},
			{"assinado_bytes", hx(imgSigIn)},
			{"signature", hx(imgSig)},
		}},
		{"deve_falhar", []O{
			{{"caso", "blob com último bit trocado: hash e AEAD recusam"}, {"blob", hx(blobBad)}, {"blob_sha256_esperado", hx(blobSum[:])}},
			{{"caso", "blob aberto com aad de outra conversa"}, {"blob", hx(blob)}, {"aad", hx(cat(label("direct/v1/blob"), conv2))}},
		}},
		{"salvar", O{
			{"save_id", saveID}, {"user_id", B.userStr}, {"device_id", B.idStr}, {"at", saveAt},
			{"exif_descricao", exif},
		}},
	})

	// ---------- escrow.json ----------
	password := "cavalo correto bateria grampo"
	salt := seed("escrow/arquivo/salt")[:16]
	fnonce := seed("escrow/arquivo/nonce")[:24]
	const ops, memKiB = uint32(3), uint32(262144)
	fileHeader := cat([]byte("direct-escrow-v1"), u32(ops), u32(memKiB), salt, fnonce)
	check(len(fileHeader) == 64, "cabeçalho do arquivo 64 bytes")
	fkey := argon2.IDKey([]byte(password), salt, ops, memKiB, 1, 32)
	faead, err := chacha20poly1305.NewX(fkey)
	must(err)
	fct := faead.Seal(nil, fnonce, escSK, fileHeader)
	file := cat(fileHeader, fct)
	check(len(file) == 112, "arquivo 112 bytes")

	// Rewrap: abre o embrulho de escrow da época 1 e sela para o aparelho C.
	kEsc, ok := open(escrowWrap, escPK, escSK)
	check(ok && bytes.Equal(kEsc, K), "abrir escrow")
	check(bytes.Equal(blake256(label("direct/v1/epoch-key"), conv, u32(epoch), kEsc), commit), "commitment no rewrap")
	ephC := seed("rewrap/C")
	rewrapC := seal(kEsc, C.kexPK, ephC)
	pC, ok := open(rewrapC, C.kexPK, C.kexSK)
	check(ok && bytes.Equal(pC, K), "abrir rewrap C")

	write(dir, "escrow.json", O{
		{"arquivo", O{
			{"senha_utf8", password},
			{"salt", hx(salt)},
			{"opslimit", ops},
			{"memlimit_kib", memKiB},
			{"memlimit_bytes", uint64(memKiB) * 1024},
			{"chave_argon2id", hx(fkey)},
			{"nonce", hx(fnonce)},
			{"cabecalho", hx(fileHeader)},
			{"conteudo_arquivo", hx(file)},
			{"escrow_sk", hx(escSK)},
			{"escrow_pub", hx(escPK)},
		}},
		{"rewrap", O{
			{"conversation_id", convStr},
			{"epoch", epoch},
			{"escrow_wrap", hx(escrowWrap)},
			{"chave_epoca", hx(K)},
			{"key_commitment", hx(commit)},
			{"destino", "C"},
			{"eph_sk", hx(ephC)},
			{"eph_pub", hx(x25519Pub(ephC))},
			{"wrapped_key", hx(rewrapC)},
		}},
	})

	fmt.Println("vetores gravados em", dir)
}
