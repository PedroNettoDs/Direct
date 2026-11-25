package store

// Queries used only by the moderator CLI (cmd/direct-admin).

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
)

// Keys is the server_keys row. EscrowPub is nil until "escrow init".
type Keys struct {
	ServerSignPub []byte
	EscrowPub     []byte
	ModPub        []byte // nil until "moderator register"
}

// GetKeys returns ErrNotFound if directd never started against this database.
func GetKeys(ctx context.Context, q DB) (Keys, error) {
	var k Keys
	err := q.QueryRow(ctx, `SELECT server_sign_pub, escrow_pub, mod_pub FROM server_keys`).Scan(&k.ServerSignPub, &k.EscrowPub, &k.ModPub)
	return k, notFound(err)
}

// SetEscrowPub records the escrow public key once; false if one is already there (no key change in v1).
func SetEscrowPub(ctx context.Context, q DB, pub []byte) (bool, error) {
	ct, err := q.Exec(ctx, `UPDATE server_keys SET escrow_pub = $1 WHERE escrow_pub IS NULL`, pub)
	return ct.RowsAffected() == 1, err
}

// SetModPub records the moderator public key once; false if one is already there (no key change in v1).
func SetModPub(ctx context.Context, q DB, pub []byte) (bool, error) {
	ct, err := q.Exec(ctx, `UPDATE server_keys SET mod_pub = $1 WHERE mod_pub IS NULL`, pub)
	return ct.RowsAffected() == 1, err
}

func notFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

// ---- enrollment tokens ----

// Token is an enrollment invite. UserID is nil for a new user.
type Token struct {
	ID           proto.UUID
	UserID       *proto.UUID
	AdminLabel   string
	ExpiresAt    time.Time
	DeviceTTL    time.Duration
	UsedAt       *time.Time
	UsedByDevice *proto.UUID
	RevokedAt    *time.Time
}

// InsertToken stores an unused invite. Only the public half of the invite key is kept.
func InsertToken(ctx context.Context, q DB, t *Token, invitePub []byte) error {
	var user any
	if t.UserID != nil {
		user = *t.UserID
	}
	_, err := q.Exec(ctx, `INSERT INTO enrollment_tokens (id, invite_pub, user_id, admin_label, expires_at, device_ttl)
		VALUES ($1,$2,$3,$4,$5,$6)`, t.ID, invitePub, user, t.AdminLabel, t.ExpiresAt, t.DeviceTTL)
	return err
}

// ListTokens returns all invites, latest expiry first.
func ListTokens(ctx context.Context, q DB) ([]Token, error) {
	rows, err := q.Query(ctx, `SELECT id, user_id, admin_label, expires_at, device_ttl, used_at, used_by_device, revoked_at
		FROM enrollment_tokens ORDER BY expires_at DESC, id`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Token, error) {
		var t Token
		err := r.Scan(&t.ID, &t.UserID, &t.AdminLabel, &t.ExpiresAt, &t.DeviceTTL, &t.UsedAt, &t.UsedByDevice, &t.RevokedAt)
		return t, err
	})
}

// RevokeUnusedToken revokes a pending invite; false if it does not exist, was used or was revoked.
// The row stays so that "token reactivate" cannot bring it back.
func RevokeUnusedToken(ctx context.Context, q DB, id proto.UUID, now time.Time) (bool, error) {
	ct, err := q.Exec(ctx, `UPDATE enrollment_tokens SET revoked_at = $2
		WHERE id = $1 AND used_at IS NULL AND revoked_at IS NULL`, id, now)
	return ct.RowsAffected() == 1, err
}

// ---- users and devices ----

// User is a row of users plus its number of active devices.
type User struct {
	ID            proto.UUID
	AdminLabel    string
	DisplayName   string
	Status        string
	CreatedAt     time.Time
	DisabledAt    *time.Time
	ActiveDevices int
}

const userSelect = `SELECT u.id, u.admin_label, u.display_name, u.status, u.created_at, u.disabled_at,
		(SELECT count(*) FROM devices d WHERE d.user_id = u.id AND d.revoked_at IS NULL AND d.expires_at > $1
			AND u.disabled_at IS NULL)
	FROM users u`

func scanUser(r pgx.CollectableRow) (User, error) {
	var u User
	err := r.Scan(&u.ID, &u.AdminLabel, &u.DisplayName, &u.Status, &u.CreatedAt, &u.DisabledAt, &u.ActiveDevices)
	return u, err
}

// ListUsers returns every user, by label.
func ListUsers(ctx context.Context, q DB, now time.Time) ([]User, error) {
	rows, err := q.Query(ctx, userSelect+` ORDER BY u.admin_label, u.id`, now)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanUser)
}

// GetUser returns one user or ErrNotFound.
func GetUser(ctx context.Context, q DB, id proto.UUID, now time.Time) (User, error) {
	rows, err := q.Query(ctx, userSelect+` WHERE u.id = $2`, now, id)
	if err != nil {
		return User{}, err
	}
	u, err := pgx.CollectExactlyOneRow(rows, scanUser)
	return u, notFound(err)
}

// Device is a row of devices plus the owner's label and state.
type Device struct {
	ID, UserID   proto.UUID
	AdminLabel   string
	Platform     string
	Model        string // client-supplied text
	OSVersion    string // client-supplied text
	AppVersion   string // client-supplied text
	SignPub      []byte
	KexPub       []byte
	EnrolledAt   time.Time
	LastSeenAt   *time.Time
	ExpiresAt    time.Time
	RevokedAt    *time.Time
	UserDisabled bool
}

// Active reports whether the device may authenticate (docs/protocolo.md 3).
func (d *Device) Active(now time.Time) bool {
	return d.RevokedAt == nil && !d.UserDisabled && d.ExpiresAt.After(now)
}

const deviceSelect = `SELECT d.id, d.user_id, u.admin_label, d.platform, d.model, d.os_version, d.app_version,
		d.sign_pub, d.kex_pub, d.enrolled_at, d.last_seen_at, d.expires_at, d.revoked_at, u.disabled_at IS NOT NULL
	FROM devices d JOIN users u ON u.id = d.user_id`

func scanDevice(r pgx.CollectableRow) (Device, error) {
	var d Device
	err := r.Scan(&d.ID, &d.UserID, &d.AdminLabel, &d.Platform, &d.Model, &d.OSVersion, &d.AppVersion,
		&d.SignPub, &d.KexPub, &d.EnrolledAt, &d.LastSeenAt, &d.ExpiresAt, &d.RevokedAt, &d.UserDisabled)
	return d, err
}

// ListDevices returns all devices, or only those of one user.
func ListDevices(ctx context.Context, q DB, user *proto.UUID) ([]Device, error) {
	var u any
	if user != nil {
		u = *user
	}
	rows, err := q.Query(ctx, deviceSelect+` WHERE ($1::uuid IS NULL OR d.user_id = $1)
		ORDER BY u.admin_label, d.enrolled_at, d.id`, u)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanDevice)
}

// GetDevice returns one device or ErrNotFound.
func GetDevice(ctx context.Context, q DB, id proto.UUID) (Device, error) {
	rows, err := q.Query(ctx, deviceSelect+` WHERE d.id = $1`, id)
	if err != nil {
		return Device{}, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanDevice)
	return d, notFound(err)
}

// ---- revocation (docs/protocolo.md 12); call inside a transaction ----

// Values of devices.revoked_reason.
const (
	RevokedByAdmin      = "admin"
	RevokedBySelf       = "self"
	RevokedUserDisabled = "user_disabled"
)

// RevokeDevice marks the device revoked, drops its sessions, records the access transition of the
// owner and notifies directd on commit. Repeating it keeps the original revoked_at and reason and
// notifies again.
func RevokeDevice(ctx context.Context, q DB, id proto.UUID, reason string, now time.Time) error {
	var user proto.UUID
	if err := q.QueryRow(ctx, `SELECT user_id FROM devices WHERE id = $1`, id).Scan(&user); err != nil {
		return notFound(err)
	}
	if err := LockUser(ctx, q, user); err != nil {
		return err
	}
	if _, err := q.Exec(ctx, `UPDATE devices SET revoked_at = $2, revoked_reason = $3 WHERE id = $1 AND revoked_at IS NULL`,
		id, now, reason); err != nil {
		return err
	}
	for _, sql := range []string{
		`DELETE FROM access_tokens WHERE device_id = $1`,
		`DELETE FROM auth_challenges WHERE device_id = $1`,
	} {
		if _, err := q.Exec(ctx, sql, id); err != nil {
			return err
		}
	}
	if _, err := q.Exec(ctx, `SELECT pg_notify('device_revoked', $1)`, proto.FormatUUID(id)); err != nil {
		return err
	}
	return SyncAccess(ctx, q, user, now)
}

// DisableUser disables the user, revokes every device and drops pending invites for it.
// It returns the number of devices revoked.
func DisableUser(ctx context.Context, q DB, id proto.UUID, now time.Time) (int, error) {
	ct, err := q.Exec(ctx, `UPDATE users SET disabled_at = COALESCE(disabled_at, $2) WHERE id = $1`, id, now)
	if err != nil {
		return 0, err
	}
	if ct.RowsAffected() != 1 {
		return 0, ErrNotFound
	}
	if _, err := q.Exec(ctx, `DELETE FROM enrollment_tokens WHERE user_id = $1 AND used_at IS NULL`, id); err != nil {
		return 0, err
	}
	devs, err := ListDevices(ctx, q, &id)
	if err != nil {
		return 0, err
	}
	for _, d := range devs {
		if err := RevokeDevice(ctx, q, d.ID, RevokedUserDisabled, now); err != nil {
			return 0, err
		}
	}
	return len(devs), SyncAccess(ctx, q, id, now)
}

// ---- escrow rewrap (docs/protocolo.md 13.3) ----

// LockWraps blocks other writers of epoch_key_wraps until the transaction ends. wrap_id is the
// client's sync cursor, so ids taken here must not commit after higher ids taken concurrently.
func LockWraps(ctx context.Context, q DB) error {
	_, err := q.Exec(ctx, `LOCK TABLE epoch_key_wraps IN EXCLUSIVE MODE`)
	return err
}

// EscrowEpoch is an epoch with its escrow wrap that a device does not have a wrap for yet.
type EscrowEpoch struct {
	ConversationID proto.UUID
	Epoch          uint32
	CreatorDevice  proto.UUID
	CreatorSignPub []byte
	Commitment     []byte
	Recipients     []byte // concatenated 16-byte device ids
	Signature      []byte
	EscrowWrap     []byte
	ChainN         uint64 // group epochs only; 0 in direct conversations
	ChainHash      [32]byte
}

// PendingEscrow is what a rewrap for a device may and may not do.
type PendingEscrow struct {
	Epochs   []EscrowEpoch
	Have     int           // epochs the device already has a wrap for
	Outside  int           // epochs left out: nothing signed says the user was in the conversation
	Rejected []EscrowEpoch // left out too: they list the user but the signature does not hold
}

// PendingEscrowEpochs lists, for the direct conversations the user is a member of, the epochs with an escrow
// wrap and no wrap for the device. Membership comes from the database alone, so it is not enough: a
// conversation counts only if some epoch of it has a device of the user in recipients and signed
// confirms the creator's signature over them. Then all of its epochs are eligible, including those
// created while the user had no active device. This holds because members of a direct conversation
// never change. Groups have a rule of their own, from the signed chain (docs/protocolo-grupos.md 5.4).
func PendingEscrowEpochs(ctx context.Context, q DB, user, device proto.UUID, signed func(EscrowEpoch) bool) (PendingEscrow, error) {
	var p PendingEscrow
	devs, err := ListDevices(ctx, q, &user) // revoked and expired ones included
	if err != nil {
		return p, err
	}
	own := map[proto.UUID]bool{}
	for _, d := range devs {
		own[d.ID] = true
	}
	rows, err := q.Query(ctx, `
		SELECT e.conversation_id, e.epoch, e.created_by_device, d.sign_pub, e.key_commitment, e.recipients,
			e.signature, w.wrapped_key,
			EXISTS (SELECT 1 FROM epoch_key_wraps x WHERE x.conversation_id = e.conversation_id
				AND x.epoch = e.epoch AND x.recipient_device_id = $2)
		FROM conversation_members m
		JOIN conversations c ON c.id = m.conversation_id AND c.kind = 'direct'
		JOIN epochs e ON e.conversation_id = m.conversation_id AND e.chain_n IS NULL
		JOIN epoch_key_wraps w ON w.conversation_id = e.conversation_id AND w.epoch = e.epoch
			AND w.recipient_device_id IS NULL
		JOIN devices d ON d.id = e.created_by_device
		WHERE m.user_id = $1 AND m.left_at IS NULL
		ORDER BY e.conversation_id, e.epoch`, user, device)
	if err != nil {
		return p, err
	}
	defer rows.Close()
	member := map[proto.UUID]bool{} // conversations the signed data puts the user in
	var missing, bad []EscrowEpoch
	for rows.Next() {
		var e EscrowEpoch
		var done bool
		if err := rows.Scan(&e.ConversationID, &e.Epoch, &e.CreatorDevice, &e.CreatorSignPub, &e.Commitment,
			&e.Recipients, &e.Signature, &e.EscrowWrap, &done); err != nil {
			return p, err
		}
		if hasAny(e.Recipients, own) {
			if signed(e) {
				member[e.ConversationID] = true
			} else if !done {
				bad = append(bad, e)
			}
		}
		if done {
			p.Have++
		} else {
			missing = append(missing, e)
		}
	}
	for _, e := range missing {
		if member[e.ConversationID] {
			p.Epochs = append(p.Epochs, e)
		} else {
			p.Outside++
		}
	}
	for _, e := range bad {
		if !member[e.ConversationID] {
			p.Rejected = append(p.Rejected, e)
			p.Outside--
		}
	}
	return p, rows.Err()
}

// hasAny reports whether the concatenated 16-byte ids include one of set.
func hasAny(ids []byte, set map[proto.UUID]bool) bool {
	for i := 0; i+16 <= len(ids); i += 16 {
		if set[proto.UUID(ids[i:i+16])] {
			return true
		}
	}
	return false
}

// OtherMemberLabels returns the labels of the conversation members other than user.
func OtherMemberLabels(ctx context.Context, q DB, conv, user proto.UUID) ([]string, error) {
	rows, err := q.Query(ctx, `SELECT u.admin_label FROM conversation_members m JOIN users u ON u.id = m.user_id
		WHERE m.conversation_id = $1 AND m.user_id <> $2 AND m.left_at IS NULL ORDER BY u.admin_label`, conv, user)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// Values of epoch_key_wraps.source.
const (
	WrapByCreator = "creator"
	WrapByHistory = "history"
	WrapByEscrow  = "escrow"
)

// InsertWrap adds the epoch key wrapped for a device (new wrap_id).
func InsertWrap(ctx context.Context, q DB, conv proto.UUID, epoch uint32, device proto.UUID, wrapped []byte, source string) (int64, error) {
	var id int64
	err := q.QueryRow(ctx, `INSERT INTO epoch_key_wraps (conversation_id, epoch, recipient_device_id, wrapped_key, source)
		VALUES ($1,$2,$3,$4,$5) RETURNING wrap_id`, conv, epoch, device, wrapped, source).Scan(&id)
	return id, err
}
