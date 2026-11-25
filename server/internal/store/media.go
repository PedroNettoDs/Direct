package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/nettotech/direct/server/internal/proto"
)

// DB is what the media functions need; *pgxpool.Pool and pgx.Tx both satisfy it.
type DB interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ErrNotFound is returned when the requested row does not exist.
var ErrNotFound = errors.New("not found")

// Blob size limits (docs/protocolo.md 18.2): nonce 24 + tag 16 + at least 1 byte; 10 MiB.
const (
	MinBlob = 41
	MaxBlob = 10 << 20
)

// Blob is a stored encrypted attachment.
type Blob struct {
	ID             proto.UUID
	ConversationID proto.UUID
	UploaderDevice proto.UUID
	Size           int
	SHA256         []byte
	Data           []byte
	CreatedAt      time.Time
}

// InsertBlob stores b (Size and SHA256 must already be set by the caller).
func InsertBlob(ctx context.Context, q DB, b *Blob) error {
	_, err := q.Exec(ctx, `INSERT INTO blobs (id, conversation_id, uploader_device_id, size, sha256, data, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7)`, b.ID, b.ConversationID, b.UploaderDevice, b.Size, b.SHA256, b.Data, b.CreatedAt)
	return err
}

// GetBlob returns the blob with its data, or ErrNotFound.
func GetBlob(ctx context.Context, q DB, id proto.UUID) (*Blob, error) {
	var b Blob
	err := q.QueryRow(ctx, `SELECT id, conversation_id, uploader_device_id, size, sha256, data, created_at
		FROM blobs WHERE id = $1`, id).
		Scan(&b.ID, &b.ConversationID, &b.UploaderDevice, &b.Size, &b.SHA256, &b.Data, &b.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &b, err
}

// BlobBytesSince is how much the user has uploaded since t, over all of their devices.
func BlobBytesSince(ctx context.Context, q DB, user proto.UUID, t time.Time) (int64, error) {
	var n int64
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(b.size), 0) FROM blobs b JOIN devices d ON d.id = b.uploader_device_id
		WHERE d.user_id = $1 AND b.created_at > $2`, user, t).Scan(&n)
	return n, err
}

// PruneOrphanBlobs deletes blobs created before t that no message can refer to: the id travels
// inside the ciphertext, so the test is that the uploading device sent nothing in that
// conversation afterwards. Orphans followed by another message are kept. It returns how many
// were deleted and their total size.
func PruneOrphanBlobs(ctx context.Context, q DB, t time.Time) (n, size int64, err error) {
	err = q.QueryRow(ctx, `WITH gone AS (
			DELETE FROM blobs b WHERE b.created_at < $1 AND NOT EXISTS (
				SELECT 1 FROM messages m WHERE m.conversation_id = b.conversation_id
					AND m.sender_device_id = b.uploader_device_id AND m.created_at >= b.created_at)
			RETURNING b.size)
		SELECT count(*), COALESCE(sum(size), 0) FROM gone`, t).Scan(&n, &size)
	return n, size, err
}

// BlobConversation returns only the conversation of a blob (authorization before reading data).
func BlobConversation(ctx context.Context, q DB, id proto.UUID) (proto.UUID, error) {
	var c proto.UUID
	err := q.QueryRow(ctx, `SELECT conversation_id FROM blobs WHERE id = $1`, id).Scan(&c)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// MediaSave is one registered "save to gallery". The sender fields come from the saved message.
type MediaSave struct {
	SaveID         proto.UUID
	ConversationID proto.UUID
	Seq            uint64
	UserID         proto.UUID
	AdminLabel     string // who saved (users.admin_label)
	DeviceID       proto.UUID
	SavedAt        time.Time

	MessageID      proto.UUID // the saved message
	SenderDeviceID proto.UUID
	SenderUserID   proto.UUID
	SenderLabel    string // who sent the saved message
	SentAt         uint64 // ms, sender clock
}

// InsertMediaSave records a save. The row must reference an existing message.
func InsertMediaSave(ctx context.Context, q DB, id, conv proto.UUID, seq uint64, user, device proto.UUID, at time.Time) error {
	_, err := q.Exec(ctx, `INSERT INTO media_saves (save_id, conversation_id, seq, user_id, device_id, saved_at)
		VALUES ($1,$2,$3,$4,$5,$6)`, id, conv, int64(seq), user, device, at)
	return err
}

const saveSelect = `SELECT s.save_id, s.conversation_id, s.seq, s.user_id, su.admin_label, s.device_id, s.saved_at,
		m.message_id, m.sender_device_id, md.user_id, mu.admin_label, m.sent_at
	FROM media_saves s
	JOIN users su ON su.id = s.user_id
	JOIN messages m ON m.conversation_id = s.conversation_id AND m.seq = s.seq
	JOIN devices md ON md.id = m.sender_device_id
	JOIN users mu ON mu.id = md.user_id`

func scanSave(r pgx.Row) (*MediaSave, error) {
	var s MediaSave
	var seq int64
	err := r.Scan(&s.SaveID, &s.ConversationID, &seq, &s.UserID, &s.AdminLabel, &s.DeviceID, &s.SavedAt,
		&s.MessageID, &s.SenderDeviceID, &s.SenderUserID, &s.SenderLabel, &s.SentAt)
	s.Seq = uint64(seq)
	return &s, err
}

// GetMediaSave looks a save up by save_id (the value found in the photo EXIF), or ErrNotFound.
func GetMediaSave(ctx context.Context, q DB, id proto.UUID) (*MediaSave, error) {
	s, err := scanSave(q.QueryRow(ctx, saveSelect+` WHERE s.save_id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return s, err
}

// SaveFilter narrows ListMediaSaves. Zero values mean "no filter".
type SaveFilter struct {
	UserID         *proto.UUID
	ConversationID *proto.UUID
	Since          time.Time // saved_at >= Since
	Until          time.Time // saved_at < Until
	Limit          int       // default 100
}

// ListMediaSaves returns saves newest first.
func ListMediaSaves(ctx context.Context, q DB, f SaveFilter) ([]MediaSave, error) {
	if f.Limit <= 0 {
		f.Limit = 100
	}
	var u, c any
	if f.UserID != nil {
		u = *f.UserID
	}
	if f.ConversationID != nil {
		c = *f.ConversationID
	}
	var since, until any
	if !f.Since.IsZero() {
		since = f.Since
	}
	if !f.Until.IsZero() {
		until = f.Until
	}
	rows, err := q.Query(ctx, saveSelect+` WHERE ($1::uuid IS NULL OR s.user_id = $1)
		AND ($2::uuid IS NULL OR s.conversation_id = $2)
		AND ($3::timestamptz IS NULL OR s.saved_at >= $3)
		AND ($4::timestamptz IS NULL OR s.saved_at < $4)
		ORDER BY s.saved_at DESC, s.save_id LIMIT $5`, u, c, since, until, f.Limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []MediaSave
	for rows.Next() {
		s, err := scanSave(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}
