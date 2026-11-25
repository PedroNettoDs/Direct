// Package testvec loads the shared test vectors from docs/vetores (tests only).
package testvec

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func dir() string {
	_, f, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(f), "..", "..", "..", "docs", "vetores")
}

// Load reads docs/vetores/<name>.json into v.
func Load(t testing.TB, name string, v any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir(), name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

// Hex decodes lowercase hex or fails the test.
func Hex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type Device struct {
	Nome       string `json:"nome"`
	DeviceID   string `json:"device_id"`
	UserID     string `json:"user_id"`
	AdminLabel string `json:"admin_label"`
	SignSeed   string `json:"sign_seed"`
	SignPub    string `json:"sign_pub"`
	KexSK      string `json:"kex_sk"`
	KexPub     string `json:"kex_pub"`
	Codigo     string `json:"codigo_aparelho"`
}

type Chaves struct {
	Servidor struct {
		SignSeed string `json:"sign_seed"`
		SignPub  string `json:"sign_pub"`
	} `json:"servidor"`
	Escrow struct {
		KexSK  string `json:"kex_sk"`
		KexPub string `json:"kex_pub"`
	} `json:"escrow"`
	Aparelhos []Device `json:"aparelhos"`
}

type Cert struct {
	Aparelho   string `json:"aparelho"`
	EnrolledAt uint64 `json:"enrolled_at"`
	ExpiresAt  uint64 `json:"expires_at"`
	CertBytes  string `json:"cert_bytes"`
	CertSig    string `json:"cert_sig"`
	JSON       struct {
		DeviceID   string `json:"device_id"`
		UserID     string `json:"user_id"`
		AdminLabel string `json:"admin_label"`
		SignPub    string `json:"sign_pub"`
		KexPub     string `json:"kex_pub"`
		EnrolledAt uint64 `json:"enrolled_at"`
		ExpiresAt  uint64 `json:"expires_at"`
		Sig        string `json:"sig"`
	} `json:"json"`
}

type Cadastro struct {
	InviteSeed string            `json:"invite_seed"`
	InvitePub  string            `json:"invite_pub"`
	EnrollB    string            `json:"enroll_bytes"`
	InviteSig  string            `json:"invite_sig"`
	ProofSig   string            `json:"proof_sig"`
	Req        map[string]string `json:"requisicao"`
	Certs      []Cert            `json:"certificados"`
	LowOrder   []string          `json:"kex_pub_ordem_baixa"`
}

type Login struct {
	Challenge string            `json:"challenge"`
	AuthBytes string            `json:"auth_bytes"`
	AuthSig   string            `json:"auth_sig"`
	TokenB64u string            `json:"access_token_b64u"`
	TokenHash string            `json:"access_token_hash_sha256"`
	TokenHex  string            `json:"access_token"`
	RevBytes  string            `json:"revogado_bytes"`
	RevSig    string            `json:"revogado_sig"`
	ReqVerify map[string]string `json:"requisicao_verify"`
}

type Convite struct {
	InviteSeed string `json:"invite_seed"`
	InvitePub  string `json:"invite_pub"`
	ServerB64u string `json:"server_sign_pub_b64u"`
	EscrowB64u string `json:"escrow_pub_b64u"`
	Codigo     string `json:"codigo_verificacao"`
	CodigoHash string `json:"codigo_blake2b256"`
}

type Embrulho struct {
	Destino    string `json:"destino"`
	DeviceID   string `json:"device_id"`
	WrappedKey string `json:"wrapped_key"`
}

type Epoca struct {
	ConversationID string     `json:"conversation_id"`
	Epoch          uint32     `json:"epoch"`
	Key            string     `json:"chave_epoca"`
	Commitment     string     `json:"key_commitment"`
	Recipients     []string   `json:"recipients_ordenados"`
	StatementBytes string     `json:"statement_bytes"`
	StatementSig   string     `json:"statement_sig"`
	Embrulhos      []Embrulho `json:"embrulhos"`
}

type Mensagem struct {
	ConversationID string          `json:"conversation_id"`
	Epoch          uint32          `json:"epoch"`
	MessageID      string          `json:"message_id"`
	SentAt         uint64          `json:"sent_at"`
	Nonce          string          `json:"nonce"`
	Header         string          `json:"cabecalho"`
	AAD            string          `json:"aad"`
	Ciphertext     string          `json:"ciphertext"`
	SigBytes       string          `json:"assinado_bytes"`
	Signature      string          `json:"signature"`
	Frame          json.RawMessage `json:"quadro_ws_send"`
	DeveFalhar     []struct {
		Caso string `json:"caso"`
	} `json:"deve_falhar"`
}
