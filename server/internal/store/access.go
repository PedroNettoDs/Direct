package store

// Active members and their transitions (docs/protocolo-grupos.md 7.1). Used by directd and the CLI.

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
)

// ActiveUserSQL is true for an active user: not disabled and with at least one active device.
// It expects the users row aliased as u and "now" as $1.
const ActiveUserSQL = `(u.disabled_at IS NULL AND EXISTS (SELECT 1 FROM devices ad
	WHERE ad.user_id = u.id AND ad.revoked_at IS NULL AND ad.expires_at > $1))`

// lastAccessSQL is the last recorded state; a user without records counts as active.
const lastAccessSQL = `COALESCE((SELECT e.active FROM user_access_events e WHERE e.user_id = u.id
	ORDER BY e.id DESC LIMIT 1), true)`

// LockUser serializes the changes of one user's devices until the transaction ends. Whoever
// changes devices takes it first, so that lock order is the same everywhere.
func LockUser(ctx context.Context, q DB, user proto.UUID) error {
	_, err := q.Exec(ctx, `SELECT 1 FROM users WHERE id = $1 FOR NO KEY UPDATE`, user)
	return err
}

// SyncAccess records a transition if the user's state differs from the last recorded one and
// notifies directd when the transaction commits. Call inside a transaction.
func SyncAccess(ctx context.Context, q DB, user proto.UUID, now time.Time) error {
	if err := LockUser(ctx, q, user); err != nil {
		return err
	}
	var active, last bool
	if err := q.QueryRow(ctx, `SELECT `+ActiveUserSQL+`, `+lastAccessSQL+` FROM users u WHERE u.id = $2`,
		now, user).Scan(&active, &last); err != nil {
		return notFound(err)
	}
	if active == last {
		return nil
	}
	at := now.Truncate(time.Millisecond)
	if _, err := q.Exec(ctx, `INSERT INTO user_access_events (user_id, active, at) VALUES ($1,$2,$3)`, user, active, at); err != nil {
		return err
	}
	flag := 0
	if active {
		flag = 1
	}
	_, err := q.Exec(ctx, `SELECT pg_notify('member_access', $1)`,
		fmt.Sprintf("%s %d %d", proto.FormatUUID(user), flag, at.UnixMilli()))
	return err
}

// StaleAccessUsers lists the users whose state differs from the last recorded one (expired devices).
func StaleAccessUsers(ctx context.Context, q DB, now time.Time) ([]proto.UUID, error) {
	rows, err := q.Query(ctx, `SELECT u.id FROM users u WHERE `+ActiveUserSQL+` <> `+lastAccessSQL+` ORDER BY u.id`, now)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[proto.UUID])
}
