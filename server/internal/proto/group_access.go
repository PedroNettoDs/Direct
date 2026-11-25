package proto

import (
	"strings"

	"golang.org/x/crypto/blake2b"
)

// D11 sealed messages, member_access, pre-signed revocation and the moderator key in the
// QR (docs/protocolo-grupos.md §3, §7, §8).

const (
	LabelSealed               = "direct/v1/sealed\x00"
	LabelSelfRevoke           = "direct/v1/self-revoke\x00"
	LabelServerCodeMod        = "direct/v1/server-code-m\x00"
	scrambleAlphabet          = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRST#@%&$*!?"
	scrambleMin, scrambleStep = 12, 4
	scrambleMaxBlockSteps     = 5
)

// SealedMessage replaces a Message of an inactive sender in a group: no epoch, nonce,
// ciphertext or signature, only what the timeline needs.
type SealedMessage struct {
	ConversationID string `json:"conversation_id"`
	Seq            uint64 `json:"seq"`
	MessageID      string `json:"message_id"`
	SenderDeviceID string `json:"sender_device_id"`
	SenderUserID   string `json:"sender_user_id"`
	CreatedAt      uint64 `json:"created_at"`
	Sealed         bool   `json:"sealed"`
	Scramble       string `json:"scramble"`
}

// ScrambleLen is 12, 16, ... 32 characters, growing with the padded size of the message.
func ScrambleLen(ciphertextLen int) int {
	blocks := (ciphertextLen - 16) / MinPlainBlocks
	steps := min(max(blocks-1, 0), scrambleMaxBlockSteps)
	return scrambleMin + scrambleStep*steps
}

// Scramble is the display-only text of a sealed message. It depends on the conversation,
// the seq and the size bucket, never on the content, so it decrypts nothing.
func Scramble(conv UUID, seq uint64, ciphertextLen int) string {
	h := blake2b.Sum256(cat([]byte(LabelSealed), conv[:], u64(seq)))
	n := ScrambleLen(ciphertextLen)
	var sb strings.Builder
	for _, c := range h[:n] {
		sb.WriteByte(scrambleAlphabet[c&63])
	}
	return sb.String()
}

// NewSealed builds the sealed form of a stored message.
func NewSealed(conv UUID, seq uint64, messageID, senderDevice, senderUser UUID, createdAt uint64, ciphertextLen int) SealedMessage {
	return SealedMessage{
		ConversationID: FormatUUID(conv), Seq: seq, MessageID: FormatUUID(messageID),
		SenderDeviceID: FormatUUID(senderDevice), SenderUserID: FormatUUID(senderUser),
		CreatedAt: createdAt, Sealed: true, Scramble: Scramble(conv, seq, ciphertextLen),
	}
}

// MemberAccessEvent is the WebSocket event of a member's access change.
type MemberAccessEvent struct {
	Type          string   `json:"type"` // "member_access"
	UserID        string   `json:"user_id"`
	Active        bool     `json:"active"`
	At            uint64   `json:"at"`
	Conversations []string `json:"conversations"`
}

// AccessEvent is one line of GET /v1/conversations/{id}/access-events.
type AccessEvent struct {
	ID     uint64 `json:"id"`
	UserID string `json:"user_id"`
	Active bool   `json:"active"`
	At     uint64 `json:"at"`
}

// ---- pre-signed revocation ----

// SelfRevokeBytes: "direct/v1/self-revoke\0" || server_sign_pub(32) || device_id(16) || u64(created_at).  78 bytes.
func SelfRevokeBytes(serverPub []byte, deviceID UUID, createdAt uint64) []byte {
	return cat([]byte(LabelSelfRevoke), serverPub, deviceID[:], u64(createdAt))
}

// SelfRevokeRequest is the body of POST /v1/devices/self-revoke.
type SelfRevokeRequest struct {
	DeviceID  string `json:"device_id"`
	CreatedAt uint64 `json:"created_at"`
	Sig       string `json:"sig"`
}

// VerifySelfRevoke checks a pre-signed revocation with the device's sign_pub.
func VerifySelfRevoke(serverPub, signPub []byte, req SelfRevokeRequest) (UUID, bool) {
	id, err := ParseUUID(req.DeviceID)
	if err != nil {
		return id, false
	}
	sig, err := B64Fixed(req.Sig, 64)
	if err != nil {
		return id, false
	}
	return id, Verify(signPub, SelfRevokeBytes(serverPub, id, req.CreatedAt), sig)
}

// ---- moderator key in the QR ----

// InviteURIMod is the v=2 QR text: v=1 plus m=<mod_sign_pub>.
func InviteURIMod(host string, inviteSeed, serverPub, escrowPub, modPub []byte) string {
	return "direct://enroll?v=2&h=" + host + "&t=" + B64Encode(inviteSeed) +
		"&s=" + B64Encode(serverPub) + "&e=" + B64Encode(escrowPub) + "&m=" + B64Encode(modPub)
}

// PinURI is the QR that pins the moderator key on an already enrolled device.
func PinURI(host string, serverPub, escrowPub, modPub []byte) string {
	return "direct://pin?v=1&h=" + host + "&s=" + B64Encode(serverPub) +
		"&e=" + B64Encode(escrowPub) + "&m=" + B64Encode(modPub)
}

// ServerCodeMod is the 20-digit code of protocolo.md 4.3 extended with the moderator key.
func ServerCodeMod(serverPub, escrowPub, modPub []byte) string {
	dg := blake2b.Sum256(cat([]byte(LabelServerCodeMod), serverPub, escrowPub, modPub))
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
