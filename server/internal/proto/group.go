package proto

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"errors"

	"golang.org/x/crypto/blake2b"
)

// Group change records of docs/protocolo-grupos.md §2.

const (
	LabelGroupChange = "direct/v1/group-change\x00"
	LabelGroupLink   = "direct/v1/group-link\x00"

	// GroupMaxMembers is G4 (docs/grupos.md §9).
	GroupMaxMembers = 100
	// GroupMaxChangeBytes bounds one encoded record.
	GroupMaxChangeBytes = 4096
	// changeFixedLen is every byte of change_bytes except the body.
	changeFixedLen = len(LabelGroupChange) + 16 + 8 + 32 + 4 + 4 + 16 + 16 + 8 + 4
)

// Record kinds.
const (
	KindCreate  uint32 = 1
	KindAdd     uint32 = 2
	KindRemove  uint32 = 3
	KindPromote uint32 = 4
	KindLeave   uint32 = 5
	KindRename  uint32 = 6
	KindClose   uint32 = 7
)

// Author types.
const (
	AuthorDevice    uint32 = 1
	AuthorModerator uint32 = 2
)

// Member roles.
const (
	RoleMember uint32 = 1
	RoleAdmin  uint32 = 2
)

// GroupChange is one decoded record. Body is kind-specific (see the *Body helpers).
type GroupChange struct {
	Conv         UUID
	N            uint64
	Prev         [32]byte
	Kind         uint32
	AuthorType   uint32
	AuthorDevice UUID // zero for the moderator
	AuthorUser   UUID // zero for the moderator
	CreatedAt    uint64
	Body         []byte
}

// SignedChange is a record as stored and sent: the exact bytes plus the signature.
type SignedChange struct {
	Bytes []byte
	Sig   []byte
}

// GroupMember is one entry of a create body.
type GroupMember struct {
	User UUID
	Role uint32
}

// ChangeBody is the parsed body. Only the fields of the record's kind are set.
type ChangeBody struct {
	AdminLabel string        // create
	MetaCommit [32]byte      // create, rename
	Members    []GroupMember // create
	Users      []UUID        // add, remove, promote
	History    bool          // add
}

// ChangeBytes is the canonical encoding that is signed.
func ChangeBytes(c GroupChange) []byte {
	b := make([]byte, 0, changeFixedLen+len(c.Body))
	b = append(b, LabelGroupChange...)
	b = append(b, c.Conv[:]...)
	b = binary.BigEndian.AppendUint64(b, c.N)
	b = append(b, c.Prev[:]...)
	b = binary.BigEndian.AppendUint32(b, c.Kind)
	b = binary.BigEndian.AppendUint32(b, c.AuthorType)
	b = append(b, c.AuthorDevice[:]...)
	b = append(b, c.AuthorUser[:]...)
	b = binary.BigEndian.AppendUint64(b, c.CreatedAt)
	b = binary.BigEndian.AppendUint32(b, uint32(len(c.Body)))
	return append(b, c.Body...)
}

// DecodeChange parses change_bytes. It checks only the outer layout; ParseBody checks the body.
func DecodeChange(b []byte) (GroupChange, error) {
	var c GroupChange
	if len(b) < changeFixedLen || len(b) > GroupMaxChangeBytes || !bytes.HasPrefix(b, []byte(LabelGroupChange)) {
		return c, ErrFormat
	}
	p := b[len(LabelGroupChange):]
	copy(c.Conv[:], p[0:16])
	c.N = binary.BigEndian.Uint64(p[16:24])
	copy(c.Prev[:], p[24:56])
	c.Kind = binary.BigEndian.Uint32(p[56:60])
	c.AuthorType = binary.BigEndian.Uint32(p[60:64])
	copy(c.AuthorDevice[:], p[64:80])
	copy(c.AuthorUser[:], p[80:96])
	c.CreatedAt = binary.BigEndian.Uint64(p[96:104])
	n := binary.BigEndian.Uint32(p[104:108])
	if uint64(n) != uint64(len(p)-108) {
		return c, ErrFormat
	}
	c.Body = p[108:]
	return c, nil
}

// SignChange encodes and signs a record with an Ed25519 private key (device or moderator).
func SignChange(c GroupChange, key ed25519.PrivateKey) SignedChange {
	b := ChangeBytes(c)
	return SignedChange{Bytes: b, Sig: ed25519.Sign(key, b)}
}

// ChangeHash is the link hash: the next record's prev_hash.
func ChangeHash(sc SignedChange) [32]byte {
	h, _ := blake2b.New256(nil)
	h.Write([]byte(LabelGroupLink))
	h.Write(binary.BigEndian.AppendUint32(nil, uint32(len(sc.Bytes))))
	h.Write(sc.Bytes)
	h.Write(sc.Sig)
	var out [32]byte
	h.Sum(out[:0])
	return out
}

// ---- bodies ----

func appendLP(b []byte, s []byte) []byte {
	b = binary.BigEndian.AppendUint32(b, uint32(len(s)))
	return append(b, s...)
}

// CreateBody: u32(len(label)) || label || meta_commit(32) || u32(m) || m × (user_id(16) || u32(role)).
// Members must be in ascending user_id order.
func CreateBody(adminLabel string, metaCommit [32]byte, members []GroupMember) []byte {
	b := appendLP(nil, []byte(adminLabel))
	b = append(b, metaCommit[:]...)
	b = binary.BigEndian.AppendUint32(b, uint32(len(members)))
	for _, m := range members {
		b = append(b, m.User[:]...)
		b = binary.BigEndian.AppendUint32(b, m.Role)
	}
	return b
}

func usersBody(b []byte, users []UUID) []byte {
	b = binary.BigEndian.AppendUint32(b, uint32(len(users)))
	for _, u := range users {
		b = append(b, u[:]...)
	}
	return b
}

// AddBody: u32(history) || u32(k) || k × user_id(16).
func AddBody(history bool, users []UUID) []byte {
	var h uint32
	if history {
		h = 1
	}
	return usersBody(binary.BigEndian.AppendUint32(nil, h), users)
}

// UsersBody (remove, promote): u32(k) || k × user_id(16).
func UsersBody(users []UUID) []byte { return usersBody(nil, users) }

// RenameBody: meta_commit(32).
func RenameBody(metaCommit [32]byte) []byte { return append([]byte(nil), metaCommit[:]...) }

type reader struct {
	b   []byte
	bad bool
}

func (r *reader) take(n int) []byte {
	if r.bad || n < 0 || len(r.b) < n {
		r.bad = true
		return nil
	}
	out := r.b[:n]
	r.b = r.b[n:]
	return out
}

func (r *reader) u32() uint32 {
	p := r.take(4)
	if p == nil {
		return 0
	}
	return binary.BigEndian.Uint32(p)
}

func (r *reader) users() []UUID {
	k := r.u32()
	if r.bad || k < 1 || k > GroupMaxMembers+1 {
		r.bad = true
		return nil
	}
	out := make([]UUID, k)
	for i := range out {
		copy(out[i][:], r.take(16))
		if i > 0 && bytes.Compare(out[i-1][:], out[i][:]) >= 0 {
			r.bad = true
		}
	}
	return out
}

// ParseBody decodes the body of kind and checks that it is canonical: exact length,
// ascending user ids without repetition, known role and history values.
// The create list may hold GroupMaxMembers+1 entries so that the limit is reported as
// "limite", not "formato".
func ParseBody(kind uint32, body []byte) (ChangeBody, error) {
	var cb ChangeBody
	r := &reader{b: body}
	switch kind {
	case KindCreate:
		cb.AdminLabel = string(r.take(int(r.u32())))
		copy(cb.MetaCommit[:], r.take(32))
		m := r.u32()
		if m < 1 || m > GroupMaxMembers+1 {
			return cb, ErrFormat
		}
		cb.Members = make([]GroupMember, m)
		for i := range cb.Members {
			copy(cb.Members[i].User[:], r.take(16))
			cb.Members[i].Role = r.u32()
			if role := cb.Members[i].Role; role != RoleMember && role != RoleAdmin {
				return cb, ErrFormat
			}
			if i > 0 && bytes.Compare(cb.Members[i-1].User[:], cb.Members[i].User[:]) >= 0 {
				return cb, ErrFormat
			}
		}
	case KindAdd:
		h := r.u32()
		if h > 1 {
			return cb, ErrFormat
		}
		cb.History = h == 1
		cb.Users = r.users()
	case KindRemove, KindPromote:
		cb.Users = r.users()
	case KindRename:
		copy(cb.MetaCommit[:], r.take(32))
	case KindLeave, KindClose:
	default:
		return cb, ErrFormat
	}
	if r.bad || len(r.b) != 0 {
		return cb, ErrFormat
	}
	return cb, nil
}

// ---- errors ----

// ChainError says which record failed and why. Code is one of the Chain* codes.
type ChainError struct {
	N    uint64
	Code string
}

func (e *ChainError) Error() string { return "registro " + itoa(e.N) + " do grupo: " + e.Code }

// Error codes, in the order in which Apply checks them (docs/protocolo-grupos.md §2.6).
const (
	ChainFormat   = "formato"
	ChainConv     = "conversa"
	ChainSeq      = "sequencia"
	ChainPrev     = "prev_hash"
	ChainAuthor   = "autor"
	ChainSig      = "assinatura"
	ChainClosed   = "encerrado"
	ChainRole     = "papel"
	ChainTarget   = "alvo"
	ChainLimit    = "limite"
	ChainEpochRef = "cadeia" // epoch refers to a chain position that does not match
)

// CodeOf returns the ChainError code of err, or "" if err is not one.
func CodeOf(err error) string {
	var ce *ChainError
	if errors.As(err, &ce) {
		return ce.Code
	}
	return ""
}
