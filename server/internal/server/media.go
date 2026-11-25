package server

import (
	"crypto/sha256"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

// Blob upload/download and save registration (docs/protocolo.md, seção 18).

const blobTransferTimeout = 3 * time.Minute // 10 MiB on a slow mobile link

func errTooLarge() *apiError {
	return &apiError{Status: 413, Code: "too_large", Message: "blob acima de 10 MiB"}
}

// extendDeadlines lets a large body finish despite the global 30 s read/write timeouts.
func extendDeadlines(w http.ResponseWriter) {
	rc := http.NewResponseController(w)
	d := time.Now().Add(blobTransferTimeout)
	_ = rc.SetReadDeadline(d)
	_ = rc.SetWriteDeadline(d)
}

// POST /v1/blobs?conversation_id=<uuid>
func (s *Server) handleUploadBlob(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, ok := idOK(r.URL.Query().Get("conversation_id"))
	if !ok {
		s.writeAPIErr(w, errBad("conversation_id inválido"))
		return
	}
	if !s.blobDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}
	ctx := r.Context()
	var exists bool
	if err := s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM conversations WHERE id = $1)`, conv).Scan(&exists); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if !exists {
		s.writeAPIErr(w, errNotFound("conversa inexistente"))
		return
	}
	if member, err := s.isMember(ctx, s.db, conv, p.UserID); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	} else if !member {
		s.writeAPIErr(w, errForbidden())
		return
	}
	if r.ContentLength > store.MaxBlob {
		s.writeAPIErr(w, errTooLarge())
		return
	}
	var closed bool
	if err := s.db.QueryRow(ctx, `SELECT closed_at IS NOT NULL FROM conversations WHERE id = $1`, conv).Scan(&closed); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if closed {
		s.writeAPIErr(w, errGroupClosed())
		return
	}
	extendDeadlines(w)
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, store.MaxBlob))
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		s.writeAPIErr(w, errTooLarge())
		return
	}
	if err != nil {
		s.writeAPIErr(w, errBad("corpo não lido"))
		return
	}
	if len(data) < store.MinBlob {
		s.writeAPIErr(w, errBad("blob curto demais"))
		return
	}
	used, err := store.BlobBytesSince(ctx, s.db, p.UserID, s.now().Add(-24*time.Hour))
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	// Parallel uploads may overshoot by the few that blobDev lets through at once.
	if used+int64(len(data)) > s.blobQuota {
		s.writeAPIErr(w, &apiError{Status: 429, Code: "rate_limited", Message: "cota diária de anexos esgotada"})
		return
	}
	sum := sha256.Sum256(data)
	b := &store.Blob{ID: s.newUUID(), ConversationID: conv, UploaderDevice: p.DeviceID,
		Size: len(data), SHA256: sum[:], Data: data, CreatedAt: s.nowMs()}
	if err := store.InsertBlob(ctx, s.db, b); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 201, map[string]any{"blob_id": proto.FormatUUID(b.ID), "size": b.Size, "sha256": proto.B64Encode(sum[:])})
}

// GET /v1/blobs/{id}
func (s *Server) handleGetBlob(w http.ResponseWriter, r *http.Request, p *Principal) {
	id, ok := idOK(r.PathValue("id"))
	if !ok {
		s.writeAPIErr(w, errBad("id inválido"))
		return
	}
	if !s.blobGetDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}
	ctx := r.Context()
	conv, err := store.BlobConversation(ctx, s.db, id)
	if errors.Is(err, store.ErrNotFound) {
		s.writeAPIErr(w, errNotFound("blob inexistente"))
		return
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if member, err := s.isMember(ctx, s.db, conv, p.UserID); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	} else if !member {
		s.writeAPIErr(w, errForbidden())
		return
	}
	var uploader proto.UUID
	if err := s.db.QueryRow(ctx, `SELECT uploader_device_id FROM blobs WHERE id = $1`, id).Scan(&uploader); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if inactive, err := s.groupSenderInactive(ctx, conv, uploader); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	} else if inactive {
		s.writeAPIErr(w, errSenderInactive())
		return
	}
	if !s.downloads.Take(p.UserID) {
		s.writeAPIErr(w, errRate())
		return
	}
	defer s.downloads.Release(p.UserID)
	b, err := store.GetBlob(ctx, s.db, id)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	extendDeadlines(w)
	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Length", strconv.Itoa(len(b.Data)))
	w.WriteHeader(200)
	_, _ = w.Write(b.Data)
}

// POST /v1/media/saves
func (s *Server) handleCreateSave(w http.ResponseWriter, r *http.Request, p *Principal) {
	var req struct {
		ConversationID string `json:"conversation_id"`
		Seq            uint64 `json:"seq"`
	}
	if e := readJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	conv, ok := idOK(req.ConversationID)
	if !ok || req.Seq < 1 || req.Seq >= maxSafeInt {
		s.writeAPIErr(w, errBad("campos inválidos"))
		return
	}
	if !s.saveDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}
	ctx := r.Context()
	var exists bool
	if err := s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM conversations WHERE id = $1)`, conv).Scan(&exists); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if !exists {
		s.writeAPIErr(w, errNotFound("conversa inexistente"))
		return
	}
	if member, err := s.isMember(ctx, s.db, conv, p.UserID); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	} else if !member {
		s.writeAPIErr(w, errForbidden())
		return
	}
	var sender proto.UUID
	err := s.db.QueryRow(ctx, `SELECT sender_device_id FROM messages WHERE conversation_id = $1 AND seq = $2`,
		conv, int64(req.Seq)).Scan(&sender)
	if errors.Is(err, pgx.ErrNoRows) {
		s.writeAPIErr(w, errNotFound("mensagem inexistente"))
		return
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if inactive, err := s.groupSenderInactive(ctx, conv, sender); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	} else if inactive {
		s.writeAPIErr(w, errSenderInactive())
		return
	}
	id, at := s.newUUID(), s.nowMs()
	if err := store.InsertMediaSave(ctx, s.db, id, conv, req.Seq, p.UserID, p.DeviceID, at); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 201, map[string]any{"save_id": proto.FormatUUID(id), "saved_at": ms(at),
		"user_id": proto.FormatUUID(p.UserID), "device_id": proto.FormatUUID(p.DeviceID)})
}
