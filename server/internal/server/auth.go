package server

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/nettotech/direct/server/internal/proto"
)

// Principal is the authenticated device behind an access token.
type Principal struct {
	DeviceID, UserID proto.UUID
	TokenExpires     time.Time
}

// authenticate resolves a base64url access token. The device state is checked on every call.
func (s *Server) authenticate(ctx context.Context, tokenB64 string) (*Principal, *apiError) {
	raw, err := proto.B64Fixed(tokenB64, 32)
	if err != nil {
		return nil, &apiError{Status: 401, Code: "unauthorized", Message: "token inválido"}
	}
	now := s.now()
	var p Principal
	var revoked, disabled *time.Time
	var devExpires time.Time
	err = s.db.QueryRow(ctx, `
		SELECT t.expires_at, d.id, d.user_id, d.expires_at, d.revoked_at, u.disabled_at
		FROM access_tokens t
		JOIN devices d ON d.id = t.device_id
		JOIN users u ON u.id = d.user_id
		WHERE t.token_hash = $1`, proto.TokenHash(raw)).
		Scan(&p.TokenExpires, &p.DeviceID, &p.UserID, &devExpires, &revoked, &disabled)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.TokenExpires.After(now)) {
		return nil, &apiError{Status: 401, Code: "unauthorized", Message: "token inválido ou vencido"}
	}
	if err != nil {
		return nil, errInternal(err)
	}
	if revoked != nil || disabled != nil {
		return nil, &apiError{Status: 401, Code: "device_revoked", Message: "aparelho revogado"}
	}
	if !devExpires.After(now) {
		return nil, &apiError{Status: 401, Code: "device_expired", Message: "aparelho vencido"}
	}
	// last_seen_at is only refreshed once a minute to avoid a write per request.
	_, _ = s.db.Exec(ctx, `UPDATE devices SET last_seen_at = $2
		WHERE id = $1 AND (last_seen_at IS NULL OR last_seen_at < $2 - interval '1 minute')`, p.DeviceID, now)
	return &p, nil
}

func (s *Server) authed(h func(http.ResponseWriter, *http.Request, *Principal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok {
			s.writeAPIErr(w, &apiError{Status: 401, Code: "unauthorized", Message: "token ausente"})
			return
		}
		p, e := s.authenticate(r.Context(), tok)
		if e != nil {
			s.writeAPIErr(w, e)
			return
		}
		h(w, r, p)
	}
}

type challengeReq struct {
	DeviceID string `json:"device_id"`
}

func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request) {
	var req challengeReq
	if e := readJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	dev, ok := idOK(req.DeviceID)
	if !ok {
		s.writeAPIErr(w, errBad("device_id inválido"))
		return
	}
	// By IP only: device ids are public and nothing has been proven yet, so a per-device limit
	// here would let anyone lock another device out.
	if !s.authIP.Allow(s.clientIP(r)) {
		s.writeAPIErr(w, errRate())
		return
	}
	ch := randBytes(32)
	exp := s.now().Add(challengeTTL)
	// Unknown device: same answer, nothing stored (no existence oracle).
	if _, err := s.db.Exec(r.Context(), `
		INSERT INTO auth_challenges (device_id, challenge, expires_at)
		SELECT id, $2, $3 FROM devices WHERE id = $1`, dev, ch, exp); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 200, map[string]any{"challenge": proto.B64Encode(ch), "expires_at": ms(exp)})
}

type verifyReq struct {
	DeviceID  string `json:"device_id"`
	Challenge string `json:"challenge"`
	Sig       string `json:"sig"`
}

func authFailed() *apiError {
	return &apiError{Status: 401, Code: "auth_failed", Message: "falha na autenticação"}
}

func (s *Server) handleVerify(w http.ResponseWriter, r *http.Request) {
	var req verifyReq
	if e := readJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	dev, ok1 := idOK(req.DeviceID)
	chal, err1 := proto.B64Fixed(req.Challenge, 32)
	sig, err2 := proto.B64Fixed(req.Sig, 64)
	if !ok1 || err1 != nil || err2 != nil {
		s.writeAPIErr(w, errBad("campos inválidos"))
		return
	}
	// Per (IP, device): a challenge for any device id is free to get, so a bucket keyed by the
	// device alone could be drained by someone else.
	ip := s.clientIP(r)
	if !s.authIP.Allow(ip) || !s.authDev.Allow(ip+"|"+req.DeviceID) {
		s.writeAPIErr(w, errRate())
		return
	}
	ctx := r.Context()
	now := s.now()

	// 1. Challenge is single use, success or failure.
	var chalExp time.Time
	err := s.db.QueryRow(ctx, `DELETE FROM auth_challenges WHERE device_id = $1 AND challenge = $2 RETURNING expires_at`,
		dev, chal).Scan(&chalExp)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !chalExp.After(now)) {
		s.writeAPIErr(w, authFailed())
		return
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}

	// 2. Signature.
	var signPub []byte
	var devExpires time.Time
	var revoked, disabled *time.Time
	err = s.db.QueryRow(ctx, `
		SELECT d.sign_pub, d.expires_at, d.revoked_at, u.disabled_at
		FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = $1`, dev).
		Scan(&signPub, &devExpires, &revoked, &disabled)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if !proto.Verify(signPub, proto.AuthBytes(s.signPub, dev, chal), sig) {
		s.writeAPIErr(w, authFailed())
		return
	}

	// 3. State, only after a valid signature.
	if revoked != nil || disabled != nil {
		proof := ed25519.Sign(s.signKey, proto.RevokedBytes(dev, chal))
		s.writeAPIErr(w, &apiError{Status: 401, Code: "device_revoked", Message: "aparelho revogado",
			Extra: map[string]any{"revoked_sig": proto.B64Encode(proof)}})
		return
	}
	if !devExpires.After(now) {
		s.writeAPIErr(w, &apiError{Status: 401, Code: "device_expired", Message: "aparelho vencido"})
		return
	}

	// 4. New token, at most 5 live per device.
	tok := randBytes(32)
	exp := now.Add(accessTTL)
	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `INSERT INTO access_tokens (token_hash, device_id, created_at, expires_at) VALUES ($1,$2,$3,$4)`,
		proto.TokenHash(tok), dev, now, exp)
	if err == nil {
		_, err = tx.Exec(ctx, `DELETE FROM access_tokens WHERE device_id = $1 AND token_hash NOT IN (
			SELECT token_hash FROM access_tokens WHERE device_id = $1 AND expires_at > $2
			ORDER BY created_at DESC, token_hash LIMIT $3)`, dev, now, maxTokensPer)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 200, map[string]any{"access_token": proto.B64Encode(tok), "expires_at": ms(exp), "server_time": ms(now)})
}

func isUniqueViolation(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg) && pg.Code == "23505"
}

func signBytes(k ed25519.PrivateKey, msg []byte) []byte { return ed25519.Sign(k, msg) }
