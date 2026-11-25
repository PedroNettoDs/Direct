package store

// Group chains (docs/protocolo-grupos.md 2 and 10.2). Used by directd and the CLI.

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
)

// ChangeRow is a stored chain record.
type ChangeRow struct {
	proto.SignedChange
	N          uint64
	ReceivedAt time.Time
}

// ListChanges returns records with n > after, ascending; limit 0 = all.
func ListChanges(ctx context.Context, q DB, conv proto.UUID, after uint64, limit int) ([]ChangeRow, error) {
	var lim any
	if limit > 0 {
		lim = limit
	}
	rows, err := q.Query(ctx, `SELECT n, change_bytes, signature, received_at FROM group_changes
		WHERE conversation_id = $1 AND n > $2 ORDER BY n LIMIT $3`, conv, int64(after), lim)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (ChangeRow, error) {
		var c ChangeRow
		err := r.Scan(&c.N, &c.Bytes, &c.Sig, &c.ReceivedAt)
		return c, err
	})
}

// LoadCerts returns the certificates of the devices, revoked and expired ones included.
func LoadCerts(ctx context.Context, q DB, ids []proto.UUID) (map[proto.UUID]proto.SignedCert, error) {
	rows, err := q.Query(ctx, `SELECT d.id, d.user_id, u.admin_label, d.sign_pub, d.kex_pub, d.cert_sig, d.enrolled_at, d.expires_at
		FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[proto.UUID]proto.SignedCert{}
	for rows.Next() {
		var sc proto.SignedCert
		c := &sc.Cert
		var enrolled, expires time.Time
		if err := rows.Scan(&c.DeviceID, &c.UserID, &c.AdminLabel, &c.SignPub, &c.KexPub, &sc.Sig, &enrolled, &expires); err != nil {
			return nil, err
		}
		c.EnrolledAt, c.ExpiresAt = uint64(enrolled.UnixMilli()), uint64(expires.UnixMilli())
		out[c.DeviceID] = sc
	}
	return out, rows.Err()
}

// ChainKeys is what verifies recs: the server and moderator public keys and the authors' certificates.
func ChainKeys(ctx context.Context, q DB, recs []proto.SignedChange) (proto.ChainKeys, error) {
	k, err := GetKeys(ctx, q)
	if err != nil {
		return proto.ChainKeys{}, err
	}
	var authors []proto.UUID
	for _, r := range recs {
		if c, err := proto.DecodeChange(r.Bytes); err == nil && c.AuthorType == proto.AuthorDevice {
			authors = append(authors, c.AuthorDevice)
		}
	}
	certs, err := LoadCerts(ctx, q, authors)
	return proto.ChainKeys{ServerPub: k.ServerSignPub, ModPub: k.ModPub, Certs: certs}, err
}

// ErrBadChain means the stored chain does not verify or does not match the conversation row.
var ErrBadChain = errors.New("a cadeia gravada do grupo não confere")

// Chain is a verified stored chain. Keys also covers the authors of the extra records.
type Chain struct {
	Rows  []ChangeRow
	State *proto.GroupState
	Keys  proto.ChainKeys
}

// LoadChain reads and verifies the chain of a group from record 1 and checks that it ends where
// the conversation row says. extra are records about to be applied.
func LoadChain(ctx context.Context, q DB, conv proto.UUID, extra ...proto.SignedChange) (Chain, error) {
	var c Chain
	var err error
	if c.Rows, err = ListChanges(ctx, q, conv, 0, 0); err != nil {
		return c, err
	}
	recs := make([]proto.SignedChange, 0, len(c.Rows)+len(extra))
	for _, r := range c.Rows {
		recs = append(recs, r.SignedChange)
	}
	if c.Keys, err = ChainKeys(ctx, q, append(recs, extra...)); err != nil {
		return c, err
	}
	if c.State, err = proto.VerifyChain(conv, recs, c.Keys); err != nil {
		return c, fmt.Errorf("%w: %v", ErrBadChain, err)
	}
	var n uint64
	var head []byte
	if err := q.QueryRow(ctx, `SELECT chain_n, chain_hash FROM conversations WHERE id = $1`, conv).Scan(&n, &head); err != nil {
		return c, notFound(err)
	}
	if n != c.State.N || (n > 0 && string(head) != string(c.State.Head[:])) {
		return c, fmt.Errorf("%w: o topo é diferente do registrado na conversa", ErrBadChain)
	}
	return c, nil
}

// InsertGroup creates the conversation row of a new group; false if the id is taken.
func InsertGroup(ctx context.Context, q DB, conv proto.UUID, now time.Time) (bool, error) {
	ct, err := q.Exec(ctx, `INSERT INTO conversations (id, kind, created_at) VALUES ($1,'group',$2) ON CONFLICT (id) DO NOTHING`, conv, now)
	return ct.RowsAffected() == 1, err
}

// UsersEnabled reports whether every user exists and is not disabled.
func UsersEnabled(ctx context.Context, q DB, users []proto.UUID) (bool, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = ANY($1) AND disabled_at IS NULL`, users).Scan(&n)
	return n == len(users), err
}

// AppendChange stores a record that st.Apply accepted (st is the state after it) and updates the
// conversation and the membership rows. The caller holds the conversation row lock.
func AppendChange(ctx context.Context, q DB, rec proto.SignedChange, st *proto.GroupState, now time.Time) error {
	c, err := proto.DecodeChange(rec.Bytes)
	if err != nil {
		return err
	}
	body, err := proto.ParseBody(c.Kind, c.Body)
	if err != nil {
		return err
	}
	conv, n := st.Conv, int64(c.N)
	var authorDevice, authorUser any
	if c.AuthorType == proto.AuthorDevice {
		authorDevice, authorUser = c.AuthorDevice, c.AuthorUser
	}
	hash := proto.ChangeHash(rec)
	if _, err := q.Exec(ctx, `INSERT INTO group_changes (conversation_id, n, change_bytes, signature, record_hash, kind,
		author_device_id, author_user_id, received_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		conv, n, rec.Bytes, rec.Sig, hash[:], int16(c.Kind), authorDevice, authorUser, now); err != nil {
		return err
	}
	if _, err := q.Exec(ctx, `UPDATE conversations SET chain_n = $2, chain_hash = $3,
		closed_at = CASE WHEN $4 THEN COALESCE(closed_at, $5) ELSE closed_at END WHERE id = $1`,
		conv, n, hash[:], st.ClosedAt != 0, now); err != nil {
		return err
	}

	join := func(u proto.UUID, role uint32, history bool) error {
		name := "member"
		if role == proto.RoleAdmin {
			name = "admin"
		}
		_, err := q.Exec(ctx, `INSERT INTO conversation_members (conversation_id, user_id, joined_at, role, joined_n, history)
			VALUES ($1,$2,$3,$4,$5,$6)`, conv, u, now, name, n, history)
		return err
	}
	leave := func(users []proto.UUID) error {
		_, err := q.Exec(ctx, `UPDATE conversation_members SET left_at = $3, left_n = $4
			WHERE conversation_id = $1 AND user_id = ANY($2) AND left_at IS NULL`, conv, users, now, n)
		return err
	}
	switch c.Kind {
	case proto.KindCreate:
		if _, err := q.Exec(ctx, `UPDATE conversations SET admin_label = NULLIF($2, '') WHERE id = $1`, conv, body.AdminLabel); err != nil {
			return err
		}
		for _, m := range body.Members {
			if err := join(m.User, m.Role, false); err != nil {
				return err
			}
		}
	case proto.KindAdd:
		for _, u := range body.Users {
			if err := join(u, proto.RoleMember, body.History); err != nil {
				return err
			}
		}
	case proto.KindRemove:
		return leave(body.Users)
	case proto.KindLeave:
		return leave([]proto.UUID{c.AuthorUser})
	case proto.KindPromote:
		_, err := q.Exec(ctx, `UPDATE conversation_members SET role = 'admin'
			WHERE conversation_id = $1 AND user_id = ANY($2) AND left_at IS NULL`, conv, body.Users)
		return err
	}
	return nil
}

// CurrentMetaCommit is the meta_commit of the last create or rename record (zeros: no name yet).
func CurrentMetaCommit(ctx context.Context, q DB, conv proto.UUID) ([32]byte, error) {
	var zero [32]byte
	var b []byte
	if err := q.QueryRow(ctx, `SELECT change_bytes FROM group_changes WHERE conversation_id = $1 AND kind IN ($2, $3)
		ORDER BY n DESC LIMIT 1`, conv, int16(proto.KindCreate), int16(proto.KindRename)).Scan(&b); err != nil {
		return zero, notFound(err)
	}
	c, err := proto.DecodeChange(b)
	if err != nil {
		return zero, err
	}
	body, err := proto.ParseBody(c.Kind, c.Body)
	return body.MetaCommit, err
}

// ---- escrow rewrap of group epochs ----

// GroupsOfUser lists the groups with a membership row of the user, current or past. The verified
// chain, not this list, decides what the user may receive.
func GroupsOfUser(ctx context.Context, q DB, user proto.UUID) ([]proto.UUID, error) {
	rows, err := q.Query(ctx, `SELECT DISTINCT m.conversation_id FROM conversation_members m
		JOIN conversations c ON c.id = m.conversation_id AND c.kind = 'group'
		WHERE m.user_id = $1 ORDER BY 1`, user)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[proto.UUID])
}

// GroupEpoch is a group epoch with its escrow wrap; Done says the device already has a wrap.
type GroupEpoch struct {
	EscrowEpoch
	Done bool
}

// ListGroupEpochs returns every epoch of the group, ascending.
func ListGroupEpochs(ctx context.Context, q DB, conv, device proto.UUID) ([]GroupEpoch, error) {
	rows, err := q.Query(ctx, `
		SELECT e.epoch, e.created_by_device, d.sign_pub, e.key_commitment, e.recipients, e.signature, w.wrapped_key,
			e.chain_n, e.chain_hash,
			EXISTS (SELECT 1 FROM epoch_key_wraps x WHERE x.conversation_id = e.conversation_id
				AND x.epoch = e.epoch AND x.recipient_device_id = $2)
		FROM epochs e
		JOIN epoch_key_wraps w ON w.conversation_id = e.conversation_id AND w.epoch = e.epoch
			AND w.recipient_device_id IS NULL
		JOIN devices d ON d.id = e.created_by_device
		WHERE e.conversation_id = $1 ORDER BY e.epoch`, conv, device)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (GroupEpoch, error) {
		e := GroupEpoch{EscrowEpoch: EscrowEpoch{ConversationID: conv}}
		var chainN *uint64
		var chainHash []byte
		if err := r.Scan(&e.Epoch, &e.CreatorDevice, &e.CreatorSignPub, &e.Commitment, &e.Recipients,
			&e.Signature, &e.EscrowWrap, &chainN, &chainHash, &e.Done); err != nil {
			return e, err
		}
		if chainN != nil {
			e.ChainN = *chainN
		}
		copy(e.ChainHash[:], chainHash)
		return e, nil
	})
}
