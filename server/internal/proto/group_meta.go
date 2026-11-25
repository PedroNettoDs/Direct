package proto

import (
	"crypto/subtle"
	"errors"

	"golang.org/x/crypto/blake2b"
	"golang.org/x/crypto/chacha20poly1305"
)

// Encrypted group name, photo and description (docs/protocolo-grupos.md §6).

const (
	LabelGroupMetaCommit = "direct/v1/group-meta-commit\x00"
	LabelGroupMeta       = "direct/v1/group-meta\x00"

	metaBlock = 256
	// MaxGroupMeta is the largest meta JSON: it must fit the 16384-byte padded limit.
	MaxGroupMeta = MaxPadded - 1
)

var ErrMetaOpen = errors.New("metadados do grupo não abrem ou não conferem com a cadeia")

// MetaCommit binds the exact meta JSON bytes (which carry a random salt) to the group.
func MetaCommit(conv UUID, meta []byte) [32]byte {
	b := cat([]byte(LabelGroupMetaCommit), conv[:], u32(uint32(len(meta))), meta)
	return blake2b.Sum256(b)
}

// MetaAAD: "direct/v1/group-meta\0" || conversation_id(16) || u32(epoch) || meta_commit(32).
func MetaAAD(conv UUID, epoch uint32, commit [32]byte) []byte {
	return cat([]byte(LabelGroupMeta), conv[:], u32(epoch), commit[:])
}

// SealMeta pads (ISO/IEC 7816-4, block 256) and encrypts meta under the epoch key k.
func SealMeta(k, nonce []byte, conv UUID, epoch uint32, meta []byte) ([]byte, error) {
	if len(meta) > MaxGroupMeta {
		return nil, ErrFormat
	}
	a, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, err
	}
	return a.Seal(nil, nonce, pad(meta, metaBlock), MetaAAD(conv, epoch, MetaCommit(conv, meta))), nil
}

// OpenMeta decrypts and unpads, then checks the result against commit (from the chain).
func OpenMeta(k, nonce, ct []byte, conv UUID, epoch uint32, commit [32]byte) ([]byte, error) {
	a, err := chacha20poly1305.NewX(k)
	if err != nil || len(nonce) != chacha20poly1305.NonceSizeX {
		return nil, ErrMetaOpen
	}
	padded, err := a.Open(nil, nonce, ct, MetaAAD(conv, epoch, commit))
	if err != nil {
		return nil, ErrMetaOpen
	}
	meta, ok := unpad(padded, metaBlock)
	if !ok {
		return nil, ErrMetaOpen
	}
	got := MetaCommit(conv, meta)
	if subtle.ConstantTimeCompare(got[:], commit[:]) != 1 {
		return nil, ErrMetaOpen
	}
	return meta, nil
}

func pad(b []byte, bs int) []byte {
	n := (len(b)/bs + 1) * bs
	out := make([]byte, n)
	copy(out, b)
	out[len(b)] = 0x80
	return out
}

func unpad(b []byte, bs int) ([]byte, bool) {
	if len(b) == 0 || len(b)%bs != 0 {
		return nil, false
	}
	for i := len(b) - 1; i >= 0 && i >= len(b)-bs; i-- {
		switch b[i] {
		case 0x80:
			return b[:i], true
		case 0:
		default:
			return nil, false
		}
	}
	return nil, false
}
