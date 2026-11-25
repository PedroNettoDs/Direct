package server

// D11: access transitions and the pre-signed revocation (docs/protocolo-grupos.md 7 and 8).

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

func errSenderInactive() *apiError {
	return &apiError{Status: 403, Code: "sender_inactive", Message: "remetente sem acesso"}
}

// groupSenderInactive is true when conv is a group and the owner of device is not active now.
func (s *Server) groupSenderInactive(ctx context.Context, conv, device proto.UUID) (bool, error) {
	var inactive bool
	err := s.db.QueryRow(ctx, `SELECT c.kind = 'group' AND NOT `+store.ActiveUserSQL+`
		FROM conversations c, devices d JOIN users u ON u.id = d.user_id
		WHERE c.id = $2 AND d.id = $3`, s.now(), conv, device).Scan(&inactive)
	return inactive, err
}

// SweepAccess records the users who lost their last device by expiry (run every minute).
func (s *Server) SweepAccess(ctx context.Context) error {
	users, err := store.StaleAccessUsers(ctx, s.db, s.now())
	if err != nil {
		return err
	}
	for _, u := range users {
		tx, err := s.db.Begin(ctx)
		if err != nil {
			return err
		}
		err = store.SyncAccess(ctx, tx, u, s.now())
		if err == nil {
			err = tx.Commit(ctx)
		}
		_ = tx.Rollback(ctx)
		if err != nil {
			return err
		}
	}
	return nil
}

// announceAccess sends member_access to every connection whose scope has a group with messages
// of the user. The payload is "<user> <0|1> <ms>".
func (s *Server) announceAccess(ctx context.Context, payload string) error {
	f := strings.Fields(payload)
	if len(f) != 3 {
		return nil
	}
	user, ok := idOK(f[0])
	at, err := strconv.ParseUint(f[2], 10, 63)
	if !ok || err != nil {
		return nil
	}
	rows, err := s.db.Query(ctx, `SELECT m.conversation_id, m.user_id FROM conversation_members m
		WHERE m.left_at IS NULL AND m.conversation_id IN (
			SELECT c.id FROM conversations c
			JOIN messages msg ON msg.conversation_id = c.id
			JOIN devices d ON d.id = msg.sender_device_id
			WHERE c.kind = 'group' AND d.user_id = $1)
		ORDER BY m.conversation_id`, user)
	if err != nil {
		return err
	}
	defer rows.Close()
	var convs []proto.UUID
	members := map[proto.UUID][]proto.UUID{}
	for rows.Next() {
		var conv, u proto.UUID
		if err := rows.Scan(&conv, &u); err != nil {
			return err
		}
		if _, ok := members[conv]; !ok {
			convs = append(convs, conv)
		}
		members[conv] = append(members[conv], u)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	s.hub.memberAccess(proto.MemberAccessEvent{Type: "member_access", UserID: f[0], Active: f[1] == "1", At: at}, convs, members)
	return nil
}

// GET /v1/conversations/{id}/access-events?after= (groups, members).
func (s *Server) handleAccessEvents(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, ok := s.groupRoute(w, r, p)
	if !ok {
		return
	}
	after, ok := queryAfter(r)
	if !ok {
		s.writeAPIErr(w, errBad("after inválido"))
		return
	}
	const limit = 500
	// Only users who were members, by the server's table, when it happened.
	rows, err := s.db.Query(r.Context(), `SELECT e.id, e.user_id, e.active, e.at FROM user_access_events e
		WHERE e.id > $2 AND EXISTS (SELECT 1 FROM conversation_members m WHERE m.conversation_id = $1
			AND m.user_id = e.user_id AND m.joined_at <= e.at AND (m.left_at IS NULL OR m.left_at > e.at))
		ORDER BY e.id LIMIT $3`, conv, int64(after), limit+1)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer rows.Close()
	events := []proto.AccessEvent{}
	for rows.Next() {
		var ev proto.AccessEvent
		var user proto.UUID
		var at time.Time
		if err := rows.Scan(&ev.ID, &user, &ev.Active, &at); err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		ev.UserID, ev.At = proto.FormatUUID(user), ms(at)
		events = append(events, ev)
	}
	if err := rows.Err(); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	more := len(events) > limit
	if more {
		events = events[:limit]
	}
	writeJSON(w, 200, map[string]any{"events": events, "has_more": more})
}

// POST /v1/devices/self-revoke, without access token: whoever forgot the password cannot log in.
// The signature binds server and device, device ids are never reused and revocation is final, so
// a replay changes nothing (docs/protocolo-grupos.md 8.4).
func (s *Server) handleSelfRevoke(w http.ResponseWriter, r *http.Request) {
	if !s.revokeIP.Allow(s.clientIP(r)) {
		s.writeAPIErr(w, errRate())
		return
	}
	var req proto.SelfRevokeRequest
	if e := readJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	dev, ok := idOK(req.DeviceID)
	if _, err := proto.B64Fixed(req.Sig, 64); !ok || err != nil || req.CreatedAt >= maxSafeInt {
		s.writeAPIErr(w, errBad("campos inválidos"))
		return
	}
	ctx := r.Context()
	var signPub []byte
	var user proto.UUID
	err := s.db.QueryRow(ctx, `SELECT sign_pub, user_id FROM devices WHERE id = $1`, dev).Scan(&signPub, &user)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	// Same answer for an unknown device and for a bad signature.
	if _, valid := proto.VerifySelfRevoke(s.signPub, signPub, req); err != nil || !valid {
		s.writeAPIErr(w, authFailed())
		return
	}
	at, done, err := s.selfRevoke(ctx, dev, user, req.CreatedAt)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if done {
		s.log.Info("self-revoke", "device", req.DeviceID, "signed_at", req.CreatedAt)
	}
	writeJSON(w, 200, map[string]any{"revoked_at": ms(at)})
}

// selfRevoke revokes the device unless it already is; it returns the original revoked_at.
func (s *Server) selfRevoke(ctx context.Context, dev, user proto.UUID, signedAt uint64) (at time.Time, done bool, err error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return at, false, err
	}
	defer tx.Rollback(ctx)
	if err := store.LockUser(ctx, tx, user); err != nil {
		return at, false, err
	}
	var prev *time.Time
	if err := tx.QueryRow(ctx, `SELECT revoked_at FROM devices WHERE id = $1`, dev).Scan(&prev); err != nil {
		return at, false, err
	}
	if prev != nil {
		return *prev, false, nil
	}
	at = s.nowMs()
	if err := store.RevokeDevice(ctx, tx, dev, store.RevokedBySelf, at); err != nil {
		return at, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE devices SET revoke_signed_at = $2 WHERE id = $1`, dev, int64(signedAt)); err != nil {
		return at, false, err
	}
	return at, true, tx.Commit(ctx)
}
