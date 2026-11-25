package server

import (
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

type enrollReq struct {
	InvitePub  string `json:"invite_pub"`
	SignPub    string `json:"sign_pub"`
	KexPub     string `json:"kex_pub"`
	Platform   string `json:"platform"`
	Model      string `json:"model"`
	OSVersion  string `json:"os_version"`
	AppVersion string `json:"app_version"`
	InviteSig  string `json:"invite_sig"`
	Proof      string `json:"proof"`
}

// CertJSON is the DeviceCert wire form (protocolo.md 5.3).
type CertJSON struct {
	DeviceID   string `json:"device_id"`
	UserID     string `json:"user_id"`
	AdminLabel string `json:"admin_label"`
	SignPub    string `json:"sign_pub"`
	KexPub     string `json:"kex_pub"`
	EnrolledAt uint64 `json:"enrolled_at"`
	ExpiresAt  uint64 `json:"expires_at"`
	Sig        string `json:"sig"`
}

func certJSON(device, user proto.UUID, label string, signPub, kexPub []byte, enrolled, expires time.Time, sig []byte) CertJSON {
	return CertJSON{
		DeviceID: proto.FormatUUID(device), UserID: proto.FormatUUID(user), AdminLabel: label,
		SignPub: proto.B64Encode(signPub), KexPub: proto.B64Encode(kexPub),
		EnrolledAt: ms(enrolled), ExpiresAt: ms(expires), Sig: proto.B64Encode(sig),
	}
}

func inviteInvalid() *apiError {
	return &apiError{Status: 401, Code: "invite_invalid", Message: "convite inválido"}
}

func (s *Server) handleServerInfo(w http.ResponseWriter, r *http.Request) {
	var escrow, mod []byte
	if err := s.db.QueryRow(r.Context(), `SELECT escrow_pub, mod_pub FROM server_keys`).Scan(&escrow, &mod); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if escrow == nil {
		s.writeAPIErr(w, &apiError{Status: 503, Code: "unavailable", Message: "escrow ainda não configurado"})
		return
	}
	// mod_pub is not authenticated: the app accepts it only by the comparison of protocolo-grupos 3.4.
	var modPub *string
	if mod != nil {
		v := proto.B64Encode(mod)
		modPub = &v
	}
	writeJSON(w, 200, map[string]any{"server_sign_pub": proto.B64Encode(s.signPub), "escrow_pub": proto.B64Encode(escrow),
		"mod_pub": modPub})
}

func (s *Server) handleEnroll(w http.ResponseWriter, r *http.Request) {
	if !s.enrollIP.Allow(s.clientIP(r)) {
		s.writeAPIErr(w, errRate())
		return
	}
	var req enrollReq
	if e := readJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	invitePub, e1 := proto.B64Fixed(req.InvitePub, 32)
	signPub, e2 := proto.B64Fixed(req.SignPub, 32)
	kexPub, e3 := proto.B64Fixed(req.KexPub, 32)
	inviteSig, e4 := proto.B64Fixed(req.InviteSig, 64)
	proof, e5 := proto.B64Fixed(req.Proof, 64)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil ||
		(req.Platform != "android" && req.Platform != "ios") ||
		!proto.ValidDeviceInfo(req.Model) || !proto.ValidDeviceInfo(req.OSVersion) || !proto.ValidDeviceInfo(req.AppVersion) {
		s.writeAPIErr(w, errBad("campos inválidos"))
		return
	}
	ctx := r.Context()
	now := s.nowMs()

	var tokID proto.UUID
	var tokUser *proto.UUID
	var label string
	var tokExp time.Time
	var ttl time.Duration
	var usedAt *time.Time
	var usedBy *proto.UUID
	err := s.db.QueryRow(ctx, `
		SELECT id, user_id, admin_label, expires_at, device_ttl, used_at, used_by_device
		FROM enrollment_tokens WHERE invite_pub = $1`, invitePub).
		Scan(&tokID, &tokUser, &label, &tokExp, &ttl, &usedAt, &usedBy)
	if errors.Is(err, pgx.ErrNoRows) {
		s.writeAPIErr(w, inviteInvalid())
		return
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	eb := proto.EnrollBytes(invitePub, signPub, kexPub)
	if !proto.Verify(invitePub, eb, inviteSig) || !proto.Verify(signPub, eb, proof) || proto.LowOrderX25519(kexPub) {
		s.writeAPIErr(w, inviteInvalid())
		return
	}

	if usedAt != nil {
		// Idempotent retry by the same device key.
		if usedBy != nil {
			if resp, ok := s.existingEnrollment(r, *usedBy, signPub, tokUser == nil); ok {
				writeJSON(w, 200, resp)
				return
			}
		}
		s.writeAPIErr(w, inviteInvalid())
		return
	}
	if !tokExp.After(now) {
		s.writeAPIErr(w, inviteInvalid())
		return
	}
	var taken bool
	if err := s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM devices WHERE sign_pub = $1)`, signPub).Scan(&taken); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if taken {
		s.writeAPIErr(w, &apiError{Status: 409, Code: "key_in_use", Message: "chave já cadastrada"})
		return
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer tx.Rollback(ctx)
	ct, err := tx.Exec(ctx, `UPDATE enrollment_tokens SET used_at = $2
		WHERE id = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > $2`, tokID, now)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if ct.RowsAffected() != 1 {
		s.writeAPIErr(w, inviteInvalid())
		return
	}
	var userID proto.UUID
	if tokUser == nil {
		userID = s.newUUID()
		_, err = tx.Exec(ctx, `INSERT INTO users (id, admin_label, created_at) VALUES ($1,$2,$3)`, userID, label, now)
	} else {
		userID = *tokUser
		// Label comes from the user row (signed into the certificate), and the user must be active.
		err = tx.QueryRow(ctx, `SELECT admin_label FROM users WHERE id = $1 AND disabled_at IS NULL`, userID).Scan(&label)
		if errors.Is(err, pgx.ErrNoRows) {
			s.writeAPIErr(w, inviteInvalid())
			return
		}
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if tokUser != nil {
		// An expiry the sweep has not seen yet is recorded before the user becomes active again.
		if err := store.SyncAccess(ctx, tx, userID, now); err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		var active int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > $2`,
			userID, now).Scan(&active); err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		if active >= maxDevicesPerUser {
			s.writeAPIErr(w, &apiError{Status: 409, Code: "device_limit", Message: "limite de aparelhos ativos"})
			return
		}
	}
	devID := s.newUUID()
	expires := now.Add(ttl).Truncate(time.Millisecond)
	cb := proto.CertBytes(proto.Cert{DeviceID: devID, UserID: userID, SignPub: signPub, KexPub: kexPub,
		EnrolledAt: ms(now), ExpiresAt: ms(expires), AdminLabel: label})
	certSig := signBytes(s.signKey, cb)
	_, err = tx.Exec(ctx, `
		INSERT INTO devices (id, user_id, platform, model, os_version, app_version, sign_pub, kex_pub, cert_sig, enrolled_at, expires_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
		devID, userID, req.Platform, req.Model, req.OSVersion, req.AppVersion, signPub, kexPub, certSig, now, expires)
	if err == nil {
		_, err = tx.Exec(ctx, `UPDATE enrollment_tokens SET used_by_device = $2 WHERE id = $1`, tokID, devID)
	}
	if err == nil {
		err = store.SyncAccess(ctx, tx, userID, now)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if isUniqueViolation(err) {
		s.writeAPIErr(w, &apiError{Status: 409, Code: "key_in_use", Message: "chave já cadastrada"})
		return
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	s.hub.directoryChanged(userID)
	writeJSON(w, 200, map[string]any{"new_user": tokUser == nil,
		"cert": certJSON(devID, userID, label, signPub, kexPub, now, expires, certSig)})
}

func (s *Server) existingEnrollment(r *http.Request, devID proto.UUID, signPub []byte, newUser bool) (map[string]any, bool) {
	var userID proto.UUID
	var label string
	var kex, sig, sp []byte
	var enrolled, expires time.Time
	err := s.db.QueryRow(r.Context(), `
		SELECT d.user_id, u.admin_label, d.sign_pub, d.kex_pub, d.cert_sig, d.enrolled_at, d.expires_at
		FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = $1`, devID).
		Scan(&userID, &label, &sp, &kex, &sig, &enrolled, &expires)
	if err != nil || string(sp) != string(signPub) {
		return nil, false
	}
	return map[string]any{"new_user": newUser, "cert": certJSON(devID, userID, label, sp, kex, enrolled, expires, sig)}, true
}
