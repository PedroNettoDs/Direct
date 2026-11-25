package server

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

// MessageIn is the sender-supplied part of a message (protocolo.md 10.5).
type MessageIn struct {
	ConversationID string `json:"conversation_id"`
	Epoch          uint32 `json:"epoch"`
	SenderDeviceID string `json:"sender_device_id"`
	MessageID      string `json:"message_id"`
	SentAt         uint64 `json:"sent_at"`
	Nonce          string `json:"nonce"`
	Ciphertext     string `json:"ciphertext"`
	Signature      string `json:"signature"`
}

// MessageJSON is a stored message as delivered.
type MessageJSON struct {
	Seq uint64 `json:"seq"`
	MessageIn
	CreatedAt uint64 `json:"created_at"`
}

const maxSafeInt = 1 << 53

// storeMessage runs the checks of protocolo.md 10.6 and stores the message.
// dup is true when the same message_id was already stored by this sender (original returned).
func (s *Server) storeMessage(r *http.Request, p *Principal, in MessageIn) (msg *MessageJSON, members []proto.UUID, dup bool, e *apiError) {
	conv, okC := idOK(in.ConversationID)
	sender, okS := idOK(in.SenderDeviceID)
	mid, okM := idOK(in.MessageID)
	nonce, errN := proto.B64Fixed(in.Nonce, 24)
	sig, errG := proto.B64Fixed(in.Signature, 64)
	ct, errC := proto.B64Decode(in.Ciphertext)
	if !okC || !okS || !okM || errN != nil || errG != nil || errC != nil || in.Epoch < 1 || in.SentAt >= maxSafeInt {
		return nil, nil, false, errBad("campos inválidos")
	}
	if sender != p.DeviceID {
		return nil, nil, false, errForbidden()
	}
	if n := len(ct) - 16; n < proto.MinPlainBlocks || n > proto.MaxPadded || n%256 != 0 {
		return nil, nil, false, errBad("tamanho do ciphertext inválido")
	}

	ctx := r.Context()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, nil, false, errInternal(err)
	}
	defer tx.Rollback(ctx)
	var latest uint32
	var lastSeq uint64
	var closed bool
	err = tx.QueryRow(ctx, `SELECT latest_epoch, last_seq, closed_at IS NOT NULL FROM conversations WHERE id = $1 FOR UPDATE`, conv).
		Scan(&latest, &lastSeq, &closed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, false, errNotFound("conversa inexistente")
	}
	if err != nil {
		return nil, nil, false, errInternal(err)
	}
	// 1. Membership.
	member, err := s.isMember(ctx, tx, conv, p.UserID)
	if err != nil {
		return nil, nil, false, errInternal(err)
	}
	if !member {
		return nil, nil, false, errForbidden()
	}
	// 3. Retry of an already stored message.
	var prevSender proto.UUID
	var prevSeq uint64
	var prevCreated time.Time
	err = tx.QueryRow(ctx, `SELECT sender_device_id, seq, created_at FROM messages WHERE conversation_id = $1 AND message_id = $2`,
		conv, mid).Scan(&prevSender, &prevSeq, &prevCreated)
	if err == nil {
		if prevSender != sender {
			return nil, nil, false, errBad("message_id em uso")
		}
		return &MessageJSON{Seq: prevSeq, CreatedAt: ms(prevCreated)}, nil, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, false, errInternal(err)
	}
	if closed {
		return nil, nil, false, &apiError{Code: "group_closed", Message: "grupo encerrado"}
	}
	// 4. Epoch is the latest and covers exactly the devices active now.
	epochRequired := &apiError{Code: "epoch_required", Message: "época nova necessária", Detail: map[string]any{"latest_epoch": latest}}
	if in.Epoch != latest || latest == 0 {
		return nil, nil, false, epochRequired
	}
	var recips []byte
	if err := tx.QueryRow(ctx, `SELECT recipients FROM epochs WHERE conversation_id = $1 AND epoch = $2`, conv, latest).Scan(&recips); err != nil {
		return nil, nil, false, errInternal(err)
	}
	active, err := s.activeDevices(ctx, tx, conv, s.now())
	if err != nil {
		return nil, nil, false, errInternal(err)
	}
	if string(recips) != string(concat(active)) {
		return nil, nil, false, epochRequired
	}
	// 5. Signature.
	var signPub []byte
	if err := tx.QueryRow(ctx, `SELECT sign_pub FROM devices WHERE id = $1`, sender).Scan(&signPub); err != nil {
		return nil, nil, false, errInternal(err)
	}
	hdr := proto.MsgHeader(conv, in.Epoch, sender, mid, in.SentAt)
	if !proto.Verify(signPub, proto.MsgSigBytes(hdr, nonce, ct), sig) {
		return nil, nil, false, &apiError{Status: 400, Code: "bad_signature", Message: "assinatura inválida"}
	}
	// 6. Store.
	seq := lastSeq + 1
	created := s.nowMs()
	if _, err = tx.Exec(ctx, `INSERT INTO messages (conversation_id, seq, message_id, epoch, sender_device_id, sent_at, nonce, ciphertext, signature, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, conv, seq, mid, in.Epoch, sender, in.SentAt, nonce, ct, sig, created); err == nil {
		_, err = tx.Exec(ctx, `UPDATE conversations SET last_seq = $2 WHERE id = $1`, conv, seq)
	}
	if err == nil {
		var rows pgx.Rows
		rows, err = tx.Query(ctx, `SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND left_at IS NULL`, conv)
		if err == nil {
			for rows.Next() {
				var u proto.UUID
				if err = rows.Scan(&u); err != nil {
					break
				}
				members = append(members, u)
			}
			rows.Close()
			if err == nil {
				err = rows.Err()
			}
		}
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		return nil, nil, false, errInternal(err)
	}
	return &MessageJSON{Seq: seq, MessageIn: in, CreatedAt: ms(created)}, members, false, nil
}

// wireMessage is what the other connections receive for a new message. The sender may have lost
// the last device between the checks and now: then it goes sealed (docs/protocolo-grupos.md 7.2).
func (s *Server) wireMessage(ctx context.Context, p *Principal, m *MessageJSON) (any, error) {
	conv, _ := proto.ParseUUID(m.ConversationID)
	inactive, err := s.groupSenderInactive(ctx, conv, p.DeviceID)
	if err != nil || !inactive {
		return m, err
	}
	mid, _ := proto.ParseUUID(m.MessageID)
	ct, _ := proto.B64Decode(m.Ciphertext)
	return proto.NewSealed(conv, m.Seq, mid, p.DeviceID, p.UserID, m.CreatedAt, len(ct)), nil
}

// GET /v1/conversations/{id}/messages?after=&before=&limit=
func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request, p *Principal) {
	after, ok := queryAfter(r)
	if !ok {
		s.writeAPIErr(w, errBad("after inválido"))
		return
	}
	// before: the newest messages below it, for groups, which have no local copy.
	var before any
	if v := r.URL.Query().Get("before"); v != "" {
		n, err := strconv.ParseUint(v, 10, 63)
		if err != nil {
			s.writeAPIErr(w, errBad("before inválido"))
			return
		}
		before = int64(n)
	}
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			s.writeAPIErr(w, errBad("limit inválido"))
			return
		}
		limit = min(n, 500)
	}
	conv, kind, ok := s.memberRoute(w, r, p)
	if !ok {
		return
	}
	order := "ASC"
	if before != nil {
		order = "DESC"
	}
	rows, err := s.db.Query(r.Context(), `SELECT m.seq, m.epoch, m.sender_device_id, m.message_id, m.sent_at, m.nonce,
			m.ciphertext, m.signature, m.created_at, u.id, NOT `+store.ActiveUserSQL+`
		FROM messages m
		JOIN devices d ON d.id = m.sender_device_id
		JOIN users u ON u.id = d.user_id
		WHERE m.conversation_id = $2 AND m.seq > $3 AND ($5::bigint IS NULL OR m.seq < $5)
		ORDER BY m.seq `+order+` LIMIT $4`, s.now(), conv, int64(after), limit+1, before)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer rows.Close()
	out := []any{}
	for rows.Next() {
		var m MessageJSON
		var sender, mid, user proto.UUID
		var nonce, ct, sig []byte
		var created time.Time
		var inactive bool
		if err := rows.Scan(&m.Seq, &m.Epoch, &sender, &mid, &m.SentAt, &nonce, &ct, &sig, &created, &user, &inactive); err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		// D11: in a group, the ciphertext of an inactive author does not leave the server.
		if kind == "group" && inactive {
			out = append(out, proto.NewSealed(conv, m.Seq, mid, sender, user, ms(created), len(ct)))
			continue
		}
		m.ConversationID, m.SenderDeviceID, m.MessageID = proto.FormatUUID(conv), proto.FormatUUID(sender), proto.FormatUUID(mid)
		m.Nonce, m.Ciphertext, m.Signature, m.CreatedAt = proto.B64Encode(nonce), proto.B64Encode(ct), proto.B64Encode(sig), ms(created)
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	more := len(out) > limit
	if more {
		out = out[:limit]
	}
	if before != nil {
		slices.Reverse(out)
	}
	writeJSON(w, 200, map[string]any{"messages": out, "has_more": more})
}
