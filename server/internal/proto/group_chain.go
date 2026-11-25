package proto

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"sort"
)

// SignedCert is a device certificate with the server signature (docs/protocolo.md 5.3).
type SignedCert struct {
	Cert Cert
	Sig  []byte
}

// ChainKeys is what the verifier trusts: the pinned server and moderator keys, and the
// certificates of the devices that signed records (from /v1/directory or /v1/devices,
// revoked ones included). Certificates are checked here against ServerPub.
type ChainKeys struct {
	ServerPub []byte
	ModPub    []byte // nil until pinned: then moderator records fail with "autor"
	Certs     map[UUID]SignedCert
}

// Interval is one membership period in chain positions: From ≤ n < To (To = 0: still member).
// History says the add record released the epochs before From (G2).
type Interval struct {
	From, To uint64
	History  bool
}

// GroupState is the result of verifying a chain prefix.
type GroupState struct {
	Conv       UUID
	N          uint64 // last applied record, 0 before create
	Head       [32]byte
	Members    map[UUID]uint32 // user -> role
	ClosedAt   uint64          // record that closed the group (close, or last member out), 0 if open
	AdminLabel string
	MetaCommit [32]byte
	Intervals  map[UUID][]Interval
	hashes     [][32]byte // hashes[i] = ChangeHash of record i+1
}

// NewGroupState is the empty state of conversation conv, before record 1.
func NewGroupState(conv UUID) *GroupState {
	return &GroupState{Conv: conv, Members: map[UUID]uint32{}, Intervals: map[UUID][]Interval{}}
}

// VerifyChain applies recs in order from record 1. Any failure rejects the whole chain.
func VerifyChain(conv UUID, recs []SignedChange, keys ChainKeys) (*GroupState, error) {
	s := NewGroupState(conv)
	for _, r := range recs {
		if err := s.Apply(r, keys); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (s *GroupState) fail(code string) error { return &ChainError{N: s.N + 1, Code: code} }

// Apply verifies one record against the state and, if valid, applies it. On error the
// state is unchanged.
func (s *GroupState) Apply(rec SignedChange, keys ChainKeys) error {
	c, err := DecodeChange(rec.Bytes)
	if err != nil || len(rec.Sig) != ed25519.SignatureSize {
		return s.fail(ChainFormat)
	}
	body, err := ParseBody(c.Kind, c.Body)
	if err != nil || !authorFormatOK(c, body) {
		return s.fail(ChainFormat)
	}
	if c.Conv != s.Conv {
		return s.fail(ChainConv)
	}
	if c.N != s.N+1 || (c.Kind == KindCreate) != (c.N == 1) {
		return s.fail(ChainSeq)
	}
	if c.Prev != s.Head {
		return s.fail(ChainPrev)
	}

	// Author and signature.
	var zero UUID
	var pub []byte
	switch c.AuthorType {
	case AuthorModerator:
		if c.AuthorDevice != zero || c.AuthorUser != zero || len(keys.ModPub) != ed25519.PublicKeySize {
			return s.fail(ChainAuthor)
		}
		pub = keys.ModPub
	case AuthorDevice:
		sc, ok := keys.Certs[c.AuthorDevice]
		if !ok || sc.Cert.DeviceID != c.AuthorDevice || sc.Cert.UserID != c.AuthorUser ||
			!Verify(keys.ServerPub, CertBytes(sc.Cert), sc.Sig) {
			return s.fail(ChainAuthor)
		}
		pub = sc.Cert.SignPub
	default:
		return s.fail(ChainAuthor)
	}
	if !Verify(pub, rec.Bytes, rec.Sig) {
		return s.fail(ChainSig)
	}

	if s.ClosedAt != 0 {
		return s.fail(ChainClosed)
	}

	// Role of the author.
	mod := c.AuthorType == AuthorModerator
	role := s.Members[c.AuthorUser]
	switch c.Kind {
	case KindCreate:
		if !mod && !hasMember(body.Members, c.AuthorUser, RoleAdmin) {
			return s.fail(ChainRole)
		}
		admins := 0
		for _, m := range body.Members {
			if m.Role == RoleAdmin {
				admins++
			}
		}
		if admins == 0 {
			return s.fail(ChainRole)
		}
	case KindRemove, KindClose:
		if !mod && role != RoleAdmin {
			return s.fail(ChainRole)
		}
	case KindAdd, KindPromote, KindRename:
		if mod || role != RoleAdmin {
			return s.fail(ChainRole)
		}
	case KindLeave:
		if mod || role == 0 {
			return s.fail(ChainRole)
		}
	}

	// Targets.
	for _, u := range body.Users {
		cur := s.Members[u]
		switch {
		case c.Kind == KindAdd && cur != 0,
			c.Kind == KindRemove && (cur == 0 || (!mod && u == c.AuthorUser)),
			c.Kind == KindPromote && cur != RoleMember:
			return s.fail(ChainTarget)
		}
	}

	// Limit.
	switch c.Kind {
	case KindCreate:
		if len(body.Members) > GroupMaxMembers {
			return s.fail(ChainLimit)
		}
	case KindAdd:
		if len(s.Members)+len(body.Users) > GroupMaxMembers {
			return s.fail(ChainLimit)
		}
	}

	// Apply.
	n := c.N
	switch c.Kind {
	case KindCreate:
		s.AdminLabel = body.AdminLabel
		s.MetaCommit = body.MetaCommit
		for _, m := range body.Members {
			s.Members[m.User] = m.Role
			s.Intervals[m.User] = append(s.Intervals[m.User], Interval{From: n})
		}
	case KindAdd:
		for _, u := range body.Users {
			s.Members[u] = RoleMember
			s.Intervals[u] = append(s.Intervals[u], Interval{From: n, History: body.History})
		}
	case KindRemove:
		for _, u := range body.Users {
			s.leave(u, n)
		}
	case KindLeave:
		s.leave(c.AuthorUser, n)
	case KindPromote:
		for _, u := range body.Users {
			s.Members[u] = RoleAdmin
		}
	case KindRename:
		s.MetaCommit = body.MetaCommit
	case KindClose:
		s.ClosedAt = n
	}
	if len(s.Members) == 0 && s.ClosedAt == 0 {
		s.ClosedAt = n
	}
	s.N = n
	s.Head = ChangeHash(rec)
	s.hashes = append(s.hashes, s.Head)
	return nil
}

// authorFormatOK holds the format rules that depend on the author type: the clear
// admin_label exists only in groups created by the moderator, who has no epoch key and
// so cannot commit to an encrypted name; devices must commit to one.
func authorFormatOK(c GroupChange, b ChangeBody) bool {
	var zero [32]byte
	switch c.Kind {
	case KindCreate:
		if c.AuthorType == AuthorModerator {
			return ValidAdminLabel(b.AdminLabel) && b.MetaCommit == zero
		}
		return b.AdminLabel == "" && b.MetaCommit != zero
	case KindRename:
		return b.MetaCommit != zero
	}
	return true
}

func hasMember(ms []GroupMember, u UUID, role uint32) bool {
	for _, m := range ms {
		if m.User == u {
			return m.Role == role
		}
	}
	return false
}

func (s *GroupState) leave(u UUID, n uint64) {
	delete(s.Members, u)
	iv := s.Intervals[u]
	iv[len(iv)-1].To = n
}

// HashAt returns the hash of record n (1 ≤ n ≤ s.N).
func (s *GroupState) HashAt(n uint64) ([32]byte, bool) {
	if n < 1 || n > s.N {
		return [32]byte{}, false
	}
	return s.hashes[n-1], true
}

// IsMember reports membership after the last applied record.
func (s *GroupState) IsMember(u UUID) bool { return s.Members[u] != 0 }

// IsAdmin reports the admin role after the last applied record.
func (s *GroupState) IsAdmin(u UUID) bool { return s.Members[u] == RoleAdmin }

// MemberAt reports whether u was a member in the state right after record n.
func (s *GroupState) MemberAt(u UUID, n uint64) bool {
	for _, iv := range s.Intervals[u] {
		if iv.From <= n && (iv.To == 0 || n < iv.To) {
			return true
		}
	}
	return false
}

// MayRewrap says whether the key of an epoch created at chain position n may be wrapped
// for a device of u outside the epoch's own recipients (history release or escrow rewrap):
// u must be a member now and either was a member at n or had the history released by an
// add record after n.
func (s *GroupState) MayRewrap(u UUID, n uint64) bool {
	if !s.IsMember(u) || n < 1 || n > s.N {
		return false
	}
	if s.MemberAt(u, n) {
		return true
	}
	for _, iv := range s.Intervals[u] {
		if iv.History && n < iv.From {
			return true
		}
	}
	return false
}

// SortedMembers lists the current members in ascending user_id order.
func (s *GroupState) SortedMembers() []GroupMember {
	out := make([]GroupMember, 0, len(s.Members))
	for u, r := range s.Members {
		out = append(out, GroupMember{User: u, Role: r})
	}
	sort.Slice(out, func(i, j int) bool { return bytes.Compare(out[i].User[:], out[j].User[:]) < 0 })
	return out
}

// ---- group epochs ----

const LabelGroupEpoch = "direct/v1/group-epoch\x00"

// GroupEpochBytes is the signed epoch statement of a group (docs/protocolo-grupos.md §5.2):
// the 1:1 statement plus the chain position it was computed from.
func GroupEpochBytes(conv UUID, epoch uint32, creator UUID, commitment, escrowPub []byte,
	chainN uint64, chainHash [32]byte, recipients []UUID) []byte {
	b := make([]byte, 0, len(LabelGroupEpoch)+144+16*len(recipients))
	b = append(b, LabelGroupEpoch...)
	b = append(b, conv[:]...)
	b = binary.BigEndian.AppendUint32(b, epoch)
	b = append(b, creator[:]...)
	b = append(b, commitment...)
	b = append(b, escrowPub...)
	b = binary.BigEndian.AppendUint64(b, chainN)
	b = append(b, chainHash[:]...)
	b = binary.BigEndian.AppendUint32(b, uint32(len(recipients)))
	for _, r := range recipients {
		b = append(b, r[:]...)
	}
	return b
}

// CheckGroupEpoch checks an epoch's chain reference against a verified chain: the chain
// position exists with that hash and the group was open there, the creator was a member
// there, and every recipient device belongs to a member there. recipientOwners holds the
// user_id of each recipient device, from verified certificates.
func (s *GroupState) CheckGroupEpoch(chainN uint64, chainHash [32]byte, creatorUser UUID, recipientOwners []UUID) error {
	fail := func(code string) error { return &ChainError{N: chainN, Code: code} }
	h, ok := s.HashAt(chainN)
	if !ok || h != chainHash || (s.ClosedAt != 0 && chainN >= s.ClosedAt) {
		return fail(ChainEpochRef)
	}
	if !s.MemberAt(creatorUser, chainN) {
		return fail(ChainRole)
	}
	for _, u := range recipientOwners {
		if !s.MemberAt(u, chainN) {
			return fail(ChainTarget)
		}
	}
	return nil
}
