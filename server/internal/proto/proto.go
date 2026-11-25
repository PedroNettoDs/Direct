// Package proto implements the byte-level formats of docs/protocolo.md (v1).
package proto

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/blake2b"
	"golang.org/x/crypto/curve25519"
)

type UUID = [16]byte

const (
	LabelEnroll     = "direct/v1/enroll\x00"
	LabelDeviceCert = "direct/v1/device-cert\x00"
	LabelAuth       = "direct/v1/auth\x00"
	LabelRevoked    = "direct/v1/revoked\x00"
	LabelEpochKey   = "direct/v1/epoch-key\x00"
	LabelEpoch      = "direct/v1/epoch\x00"
	LabelMsg        = "direct/v1/msg\x00"
	LabelMsgSig     = "direct/v1/msg-sig\x00"

	MinPlainBlocks = 256
	MaxPadded      = 16384
)

var ErrFormat = errors.New("invalid format")

// ---- base64url / UUID ----

// B64Encode encodes as base64url without padding.
func B64Encode(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// B64Decode decodes canonical base64url without padding.
func B64Decode(s string) ([]byte, error) {
	b, err := base64.RawURLEncoding.Strict().DecodeString(s)
	if err != nil || base64.RawURLEncoding.EncodeToString(b) != s {
		return nil, ErrFormat
	}
	return b, nil
}

// B64Fixed decodes and requires exactly n bytes.
func B64Fixed(s string, n int) ([]byte, error) {
	b, err := B64Decode(s)
	if err != nil || len(b) != n {
		return nil, ErrFormat
	}
	return b, nil
}

const hexd = "0123456789abcdef"

func FormatUUID(u UUID) string {
	var out [36]byte
	j := 0
	for i, c := range u {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[j] = '-'
			j++
		}
		out[j] = hexd[c>>4]
		out[j+1] = hexd[c&15]
		j += 2
	}
	return string(out[:])
}

// ParseUUID accepts only lowercase 8-4-4-4-12.
func ParseUUID(s string) (UUID, error) {
	var u UUID
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return u, ErrFormat
	}
	j := 0
	for i := 0; i < 36; i++ {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			continue
		}
		var v byte
		switch c := s[i]; {
		case c >= '0' && c <= '9':
			v = c - '0'
		case c >= 'a' && c <= 'f':
			v = c - 'a' + 10
		default:
			return u, ErrFormat
		}
		if j%2 == 0 {
			u[j/2] = v << 4
		} else {
			u[j/2] |= v
		}
		j++
	}
	return u, nil
}

// ---- signed byte strings ----

func u32(v uint32) []byte { return binary.BigEndian.AppendUint32(nil, v) }
func u64(v uint64) []byte { return binary.BigEndian.AppendUint64(nil, v) }

func cat(parts ...[]byte) []byte {
	var n int
	for _, p := range parts {
		n += len(p)
	}
	out := make([]byte, 0, n)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func EnrollBytes(invitePub, signPub, kexPub []byte) []byte {
	return cat([]byte(LabelEnroll), invitePub, signPub, kexPub)
}

type Cert struct {
	DeviceID, UserID UUID
	SignPub, KexPub  []byte
	EnrolledAt       uint64
	ExpiresAt        uint64
	AdminLabel       string
}

func CertBytes(c Cert) []byte {
	return cat([]byte(LabelDeviceCert), c.DeviceID[:], c.UserID[:], c.SignPub, c.KexPub,
		u64(c.EnrolledAt), u64(c.ExpiresAt), u32(uint32(len(c.AdminLabel))), []byte(c.AdminLabel))
}

func AuthBytes(serverPub []byte, deviceID UUID, challenge []byte) []byte {
	return cat([]byte(LabelAuth), serverPub, deviceID[:], challenge)
}

func RevokedBytes(deviceID UUID, challenge []byte) []byte {
	return cat([]byte(LabelRevoked), deviceID[:], challenge)
}

func EpochBytes(conv UUID, epoch uint32, creator UUID, commitment, escrowPub []byte, recipients []UUID) []byte {
	b := cat([]byte(LabelEpoch), conv[:], u32(epoch), creator[:], commitment, escrowPub, u32(uint32(len(recipients))))
	for _, r := range recipients {
		b = append(b, r[:]...)
	}
	return b
}

func MsgHeader(conv UUID, epoch uint32, sender, messageID UUID, sentAt uint64) []byte {
	return cat(conv[:], u32(epoch), sender[:], messageID[:], u64(sentAt))
}

func MsgAAD(header []byte) []byte { return cat([]byte(LabelMsg), header) }

func MsgSigBytes(header, nonce, ciphertext []byte) []byte {
	return cat([]byte(LabelMsgSig), header, nonce, u32(uint32(len(ciphertext))), ciphertext)
}

func EpochKeyCommitment(conv UUID, epoch uint32, k []byte) [32]byte {
	return blake2b.Sum256(cat([]byte(LabelEpochKey), conv[:], u32(epoch), k))
}

// ServerCode is the 20-digit verification code of section 4.3.
func ServerCode(serverPub, escrowPub []byte) string {
	return code20(blake2b.Sum256(cat([]byte("direct/v1/server-code\x00"), serverPub, escrowPub)))
}

// DeviceCode is the 20-digit fingerprint of a device's public keys (section 13.4): the moderator
// compares it with the one the new device shows before "escrow rewrap".
func DeviceCode(signPub, kexPub []byte) string {
	return code20(blake2b.Sum256(cat([]byte("direct/v1/device-code\x00"), signPub, kexPub)))
}

func code20(dg [32]byte) string {
	groups := make([]string, 4)
	for i := range groups {
		var v uint64
		for _, c := range dg[5*i : 5*i+5] {
			v = v<<8 | uint64(c)
		}
		s := "00000" + itoa(v%100000)
		groups[i] = s[len(s)-5:]
	}
	return strings.Join(groups, " ")
}

func itoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[i:])
}

func TokenHash(token []byte) []byte {
	h := sha256.Sum256(token)
	return h[:]
}

// ---- crypto helpers ----

func Verify(pub, msg, sig []byte) bool {
	return len(pub) == ed25519.PublicKeySize && len(sig) == ed25519.SignatureSize && ed25519.Verify(pub, msg, sig)
}

// LowOrderX25519 reports whether a public key is a small-order point.
func LowOrderX25519(pub []byte) bool {
	scalar := make([]byte, 32)
	scalar[0] = 8
	scalar[31] = 64
	_, err := curve25519.X25519(scalar, pub)
	return err != nil
}

// ---- text validation ----

func noControl(s string) bool {
	for _, r := range s {
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) {
			return false
		}
	}
	return true
}

func ValidAdminLabel(s string) bool {
	return len(s) >= 1 && len(s) <= 100 && utf8.ValidString(s) && noControl(s)
}

func ValidDisplayName(s string) bool {
	n := utf8.RuneCountInString(s)
	return n >= 1 && n <= 64 && utf8.ValidString(s) && noControl(s)
}

func ValidStatus(s string) bool {
	return utf8.RuneCountInString(s) <= 140 && utf8.ValidString(s) && noControl(s)
}

func ValidDeviceInfo(s string) bool { return len(s) <= 64 && utf8.ValidString(s) }
