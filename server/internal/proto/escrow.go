package proto

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
)

// Escrow key file (docs/protocolo.md 13.1):
// magic(16) || u32(opslimit) || u32(memlimit_kib) || salt(16) || nonce(24) || ciphertext(32+16).
const (
	escrowMagic     = "direct-escrow-v1"
	modKeyMagic     = "direct-modkey-v1" // same format, holds the moderator's Ed25519 seed (protocolo-grupos 3.1)
	escrowHeaderLen = 64
	EscrowFileLen   = 112

	EscrowOps    = 3
	EscrowMemKiB = 256 << 10

	maxEscrowOps    = 10
	maxEscrowMemKiB = 1 << 20
)

// ErrEscrowOpen covers a wrong password and a tampered file (indistinguishable by design).
var ErrEscrowOpen = errors.New("senha errada ou arquivo adulterado")

func escrowFileKey(password, header []byte) []byte {
	ops := binary.BigEndian.Uint32(header[16:])
	mem := binary.BigEndian.Uint32(header[20:])
	return argon2.IDKey(password, header[24:40], ops, mem, 1, 32)
}

// SealEscrow builds the password-protected key file for a 32-byte escrow secret key.
func SealEscrow(sk, password []byte) ([]byte, error) {
	var r [40]byte // salt(16) || nonce(24)
	if _, err := rand.Read(r[:]); err != nil {
		return nil, err
	}
	return sealEscrow(sk, password, r[:16], r[16:])
}

// SealModKey builds the password-protected key file for the moderator's 32-byte Ed25519 seed.
func SealModKey(seed, password []byte) ([]byte, error) {
	var r [40]byte // salt(16) || nonce(24)
	if _, err := rand.Read(r[:]); err != nil {
		return nil, err
	}
	return sealKeyFile(modKeyMagic, seed, password, r[:16], r[16:])
}

func sealEscrow(sk, password, salt, nonce []byte) ([]byte, error) {
	return sealKeyFile(escrowMagic, sk, password, salt, nonce)
}

func sealKeyFile(magic string, sk, password, salt, nonce []byte) ([]byte, error) {
	if len(sk) != 32 {
		return nil, ErrFormat
	}
	h := make([]byte, 0, EscrowFileLen)
	h = append(h, magic...)
	h = binary.BigEndian.AppendUint32(h, EscrowOps)
	h = binary.BigEndian.AppendUint32(h, EscrowMemKiB)
	h = append(append(h, salt...), nonce...)
	key := escrowFileKey(password, h)
	defer clear(key)
	a, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	return a.Seal(h, nonce, sk, h[:escrowHeaderLen]), nil
}

// OpenEscrow decrypts a key file. The caller must clear the returned secret key after use.
func OpenEscrow(file, password []byte) ([]byte, error) {
	if len(file) != EscrowFileLen || string(file[:16]) != escrowMagic {
		return nil, fmt.Errorf("arquivo de chave escrow inválido: %w", ErrFormat)
	}
	return openKeyFile(file, password)
}

// OpenModKey decrypts a moderator key file. The caller must clear the returned seed after use.
func OpenModKey(file, password []byte) ([]byte, error) {
	if len(file) != EscrowFileLen || string(file[:16]) != modKeyMagic {
		return nil, fmt.Errorf("arquivo de chave do moderador inválido: %w", ErrFormat)
	}
	return openKeyFile(file, password)
}

func openKeyFile(file, password []byte) ([]byte, error) {
	ops, mem := binary.BigEndian.Uint32(file[16:]), binary.BigEndian.Uint32(file[20:])
	if ops < 1 || ops > maxEscrowOps || mem < 8 || mem > maxEscrowMemKiB {
		return nil, fmt.Errorf("parâmetros Argon2id fora do limite: %w", ErrFormat)
	}
	header := file[:escrowHeaderLen]
	key := escrowFileKey(password, header)
	defer clear(key)
	a, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	sk, err := a.Open(nil, header[40:64], file[escrowHeaderLen:], header)
	if err != nil {
		return nil, ErrEscrowOpen
	}
	return sk, nil
}
