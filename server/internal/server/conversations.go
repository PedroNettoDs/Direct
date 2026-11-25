package server

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
)

type ConversationJSON struct {
	ID          string   `json:"conversation_id"`
	Kind        string   `json:"kind"`
	Members     []string `json:"members"`
	LatestEpoch uint32   `json:"latest_epoch"`
	LastSeq     uint64   `json:"last_seq"`
	Created     *bool    `json:"created,omitempty"`
	*GroupInfo           // nil in direct conversations
}

// GroupInfo are the fields of a group (docs/protocolo-grupos.md 10.5). Members is informative:
// the client trusts only the signed chain.
type GroupInfo struct {
	ChainN     uint64  `json:"chain_n"`
	AdminLabel *string `json:"admin_label"`
	Closed     bool    `json:"closed"`
}

type queryer interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func (s *Server) loadConversation(ctx context.Context, q queryer, id proto.UUID) (*ConversationJSON, []proto.UUID, error) {
	c := ConversationJSON{ID: proto.FormatUUID(id), Members: []string{}}
	var g GroupInfo
	if err := q.QueryRow(ctx, `SELECT kind, latest_epoch, last_seq, chain_n, admin_label, closed_at IS NOT NULL
		FROM conversations WHERE id = $1`, id).
		Scan(&c.Kind, &c.LatestEpoch, &c.LastSeq, &g.ChainN, &g.AdminLabel, &g.Closed); err != nil {
		return nil, nil, err
	}
	if c.Kind == "group" {
		c.GroupInfo = &g
	}
	rows, err := q.Query(ctx, `SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND left_at IS NULL ORDER BY user_id`, id)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var members []proto.UUID
	for rows.Next() {
		var u proto.UUID
		if err := rows.Scan(&u); err != nil {
			return nil, nil, err
		}
		members = append(members, u)
		c.Members = append(c.Members, proto.FormatUUID(u))
	}
	return &c, members, rows.Err()
}

func (s *Server) isMember(ctx context.Context, q queryer, conv, user proto.UUID) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2 AND left_at IS NULL)`,
		conv, user).Scan(&ok)
	return ok, err
}

func (s *Server) handleCreateConversation(w http.ResponseWriter, r *http.Request, p *Principal) {
	var req struct {
		Kind       string `json:"kind"`
		PeerUserID string `json:"peer_user_id"`
	}
	if e := readJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	peer, ok := idOK(req.PeerUserID)
	if req.Kind != "direct" || !ok || peer == p.UserID {
		s.writeAPIErr(w, errBad("conversa inválida"))
		return
	}
	ctx := r.Context()
	var active bool
	if err := s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE id = $1 AND disabled_at IS NULL)`, peer).Scan(&active); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if !active {
		s.writeAPIErr(w, errNotFound("usuário inexistente"))
		return
	}
	lo, hi := p.UserID, peer
	if bytes.Compare(lo[:], hi[:]) > 0 {
		lo, hi = hi, lo
	}
	key := proto.FormatUUID(lo) + ":" + proto.FormatUUID(hi)
	now := s.nowMs()

	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer tx.Rollback(ctx)
	id := s.newUUID()
	var got proto.UUID
	created := true
	err = tx.QueryRow(ctx, `INSERT INTO conversations (id, kind, direct_key, created_at) VALUES ($1,'direct',$2,$3)
		ON CONFLICT (direct_key) DO NOTHING RETURNING id`, id, key, now).Scan(&got)
	if errors.Is(err, pgx.ErrNoRows) {
		created = false
		err = tx.QueryRow(ctx, `SELECT id FROM conversations WHERE direct_key = $1`, key).Scan(&got)
	} else if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO conversation_members (conversation_id, user_id, joined_at) VALUES ($1,$2,$4),($1,$3,$4)`,
			got, p.UserID, peer, now)
	}
	var conv *ConversationJSON
	if err == nil {
		conv, _, err = s.loadConversation(ctx, tx, got)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if created {
		ev := *conv
		s.hub.conversationCreated(&ev, []proto.UUID{p.UserID, peer})
	}
	conv.Created = &created
	writeJSON(w, 200, conv)
}

func (s *Server) handleListConversations(w http.ResponseWriter, r *http.Request, p *Principal) {
	ctx := r.Context()
	rows, err := s.db.Query(ctx, `SELECT c.id FROM conversations c
		JOIN conversation_members m ON m.conversation_id = c.id AND m.user_id = $1 AND m.left_at IS NULL
		ORDER BY c.created_at, c.id`, p.UserID)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	var ids []proto.UUID
	for rows.Next() {
		var id proto.UUID
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			s.writeAPIErr(w, errInternal(err))
			return
		}
		ids = append(ids, id)
	}
	rows.Close()
	out := []*ConversationJSON{}
	for _, id := range ids {
		c, _, err := s.loadConversation(ctx, s.db, id)
		if err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		out = append(out, c)
	}
	writeJSON(w, 200, map[string]any{"conversations": out})
}

// activeDevices returns the ids of every active device of the conversation members, ascending.
func (s *Server) activeDevices(ctx context.Context, q queryer, conv proto.UUID, now time.Time) ([]proto.UUID, error) {
	rows, err := q.Query(ctx, `
		SELECT d.id FROM devices d
		JOIN users u ON u.id = d.user_id AND u.disabled_at IS NULL
		JOIN conversation_members m ON m.user_id = u.id AND m.conversation_id = $1 AND m.left_at IS NULL
		WHERE d.revoked_at IS NULL AND d.expires_at > $2
		ORDER BY d.id`, conv, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []proto.UUID
	for rows.Next() {
		var id proto.UUID
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func concat(ids []proto.UUID) []byte {
	b := make([]byte, 0, 16*len(ids))
	for _, id := range ids {
		b = append(b, id[:]...)
	}
	return b
}

func uuidLess(a, b proto.UUID) bool { return bytes.Compare(a[:], b[:]) < 0 }

func sortUUIDs(ids []proto.UUID) {
	sort.Slice(ids, func(i, j int) bool { return uuidLess(ids[i], ids[j]) })
}
