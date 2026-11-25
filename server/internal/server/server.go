// Package server implements the directd HTTP API and WebSocket (docs/protocolo.md).
// The server never sees message plaintext or epoch keys.
package server

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

const (
	maxBody       = 64 << 10
	maxGroupBody  = 256 << 10 // group and epoch routes (docs/protocolo-grupos.md 1)
	accessTTL     = 15 * time.Minute
	challengeTTL  = 60 * time.Second
	maxTokensPer  = 5
	maxConnsPerDv = 4

	maxDevicesPerUser = 4 // active ones (docs/protocolo-grupos.md 1)

	// Blobs (docs/protocolo.md 18): bytes a user may upload per 24 h, and downloads in flight,
	// since each one holds up to 10 MiB in memory.
	blobDayQuota   = 1 << 30
	maxDownloads   = 16
	maxUserDownlds = 4
)

type Config struct {
	Pool            *pgxpool.Pool
	SignKey         ed25519.PrivateKey
	Log             *slog.Logger
	Now             func() time.Time  // default time.Now
	NewUUID         func() proto.UUID // default random UUIDv4
	TrustedIPHeader string            // e.g. "CF-Connecting-IP"; empty = use the socket address
	TrustedProxy    string            // host name or IP of the only peer whose TrustedIPHeader counts
	BlobDayQuota    int64             // bytes per user per 24 h; default 1 GiB
}

type Server struct {
	db      *pgxpool.Pool
	signKey ed25519.PrivateKey
	signPub []byte
	log     *slog.Logger
	now     func() time.Time
	newUUID func() proto.UUID
	ipHdr   string
	proxy   string
	hub     *hub

	enrollIP, authDev, authIP, sendDev, wsIP, blobDev, saveDev *limiter
	profileDev, blobGetDev, epochDev, revokeIP                 *limiter

	blobQuota int64
	downloads *slots
}

func New(ctx context.Context, c Config) (*Server, error) {
	s := &Server{
		db: c.Pool, signKey: c.SignKey, log: c.Log, now: c.Now, newUUID: c.NewUUID, ipHdr: c.TrustedIPHeader, proxy: c.TrustedProxy,
		signPub:  c.SignKey.Public().(ed25519.PublicKey),
		hub:      newHub(),
		enrollIP: newLimiter(5.0/60, 5),
		authDev:  newLimiter(10.0/60, 10),
		authIP:   newLimiter(30.0/60, 30),
		sendDev:  newLimiter(10, 30),
		wsIP:     newLimiter(60.0/60, 60),
		blobDev:  newLimiter(20.0/60, 20),
		saveDev:  newLimiter(20.0/60, 20),

		profileDev: newLimiter(5.0/60, 5),
		blobGetDev: newLimiter(120.0/60, 120),
		epochDev:   newLimiter(30.0/60, 30),
		revokeIP:   newLimiter(5.0/60, 5),
		blobQuota:  c.BlobDayQuota,
		downloads:  newSlots(maxDownloads, maxUserDownlds),
	}
	if s.blobQuota == 0 {
		s.blobQuota = blobDayQuota
	}
	if s.log == nil {
		s.log = slog.Default()
	}
	if s.now == nil {
		s.now = time.Now
	}
	if s.newUUID == nil {
		s.newUUID = randomUUID
	}
	for _, l := range []*limiter{s.enrollIP, s.authDev, s.authIP, s.sendDev, s.wsIP, s.blobDev, s.saveDev,
		s.profileDev, s.blobGetDev, s.epochDev, s.revokeIP} {
		l.now = s.now
	}
	if err := store.EnsureServerKey(ctx, s.db, s.signPub); err != nil {
		return nil, err
	}
	return s, nil
}

func randomUUID() proto.UUID {
	var u proto.UUID
	if _, err := rand.Read(u[:]); err != nil {
		panic(err)
	}
	u[6] = u[6]&0x0f | 0x40
	u[8] = u[8]&0x3f | 0x80
	return u
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

// Handler returns the HTTP handler (API + WebSocket).
func (s *Server) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /v1/server-info", s.handleServerInfo)
	m.HandleFunc("POST /v1/enroll", s.handleEnroll)
	m.HandleFunc("POST /v1/auth/challenge", s.handleChallenge)
	m.HandleFunc("POST /v1/auth/verify", s.handleVerify)
	m.HandleFunc("GET /v1/directory", s.authed(s.handleDirectory))
	m.HandleFunc("GET /v1/devices", s.authed(s.handleDevices))
	m.HandleFunc("PUT /v1/me/profile", s.authed(s.handleProfile))
	m.HandleFunc("POST /v1/conversations", s.authed(s.handleCreateConversation))
	m.HandleFunc("GET /v1/conversations", s.authed(s.handleListConversations))
	m.HandleFunc("POST /v1/conversations/{id}/epochs", s.authed(s.handleCreateEpoch))
	m.HandleFunc("GET /v1/conversations/{id}/messages", s.authed(s.handleHistory))
	m.HandleFunc("GET /v1/epochs/mine", s.authed(s.handleMyEpochs))
	m.HandleFunc("GET /v1/conversations/{id}/epochs/mine", s.authed(s.handleConversationEpochs))
	m.HandleFunc("GET /v1/conversations/{id}/access-events", s.authed(s.handleAccessEvents))
	m.HandleFunc("POST /v1/groups", s.authed(s.handleCreateGroup))
	m.HandleFunc("POST /v1/groups/{id}/changes", s.authed(s.handleAppendChange))
	m.HandleFunc("GET /v1/groups/{id}/changes", s.authed(s.handleListChanges))
	m.HandleFunc("GET /v1/groups/{id}/meta", s.authed(s.handleGroupMeta))
	m.HandleFunc("POST /v1/groups/{id}/history-wraps", s.authed(s.handleHistoryWraps))
	m.HandleFunc("POST /v1/devices/self-revoke", s.handleSelfRevoke)
	m.HandleFunc("POST /v1/blobs", s.authed(s.handleUploadBlob))
	m.HandleFunc("GET /v1/blobs/{id}", s.authed(s.handleGetBlob))
	m.HandleFunc("POST /v1/media/saves", s.authed(s.handleCreateSave))
	m.HandleFunc("GET /v1/ws", s.handleWS)
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeErr(w, errNotFound("rota inexistente"))
	})
	return s.logging(m)
}

// Run starts background work (database notifications, token cleanup, expiry sweep) until ctx ends.
func (s *Server) Run(ctx context.Context) {
	go s.listenNotifications(ctx)
	sweep := func() {
		if err := s.SweepAccess(ctx); err != nil && ctx.Err() == nil {
			s.log.Error("varredura de acesso", "err", err.Error())
		}
	}
	go func() {
		sweep()
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				now := s.now()
				_, _ = s.db.Exec(ctx, `DELETE FROM access_tokens WHERE expires_at <= $1`, now)
				_, _ = s.db.Exec(ctx, `DELETE FROM auth_challenges WHERE expires_at <= $1`, now)
				sweep()
			}
		}
	}()
}

// CloseAll closes every WebSocket (used on shutdown).
func (s *Server) CloseAll() { s.hub.closeAll(1001, "servidor reiniciando") }

// ---- request plumbing ----

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(c int)           { w.status = c; w.ResponseWriter.WriteHeader(c) }
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return http.NewResponseController(w.ResponseWriter).Hijack()
}

// logging records method, path (no query string), status and duration. Never bodies or tokens.
func (s *Server) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r)
		s.log.Info("http", "method", r.Method, "path", r.URL.Path, "status", sw.status,
			"ms", time.Since(start).Milliseconds())
	})
}

// clientIP is the address the per-IP limits count. The header is believed only when the connection
// comes from the trusted proxy: anyone else could forge it.
func (s *Server) clientIP(r *http.Request) string {
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		h = r.RemoteAddr
	}
	if s.ipHdr != "" && s.proxy != "" {
		if v := strings.TrimSpace(r.Header.Get(s.ipHdr)); v != "" {
			// Resolved on each use: the proxy container gets a new address when recreated.
			if addrs, err := net.DefaultResolver.LookupHost(r.Context(), s.proxy); err == nil && slices.Contains(addrs, h) {
				return v
			}
		}
	}
	return h
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) *apiError {
	return readJSONUpTo(w, r, v, maxBody)
}

// readBigJSON is for the group and epoch routes.
func readBigJSON(w http.ResponseWriter, r *http.Request, v any) *apiError {
	return readJSONUpTo(w, r, v, maxGroupBody)
}

func readJSONUpTo(w http.ResponseWriter, r *http.Request, v any, limit int64) *apiError {
	body := http.MaxBytesReader(w, r.Body, limit)
	if err := json.NewDecoder(body).Decode(v); err != nil {
		return errBad("JSON inválido")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ---- errors ----

type apiError struct {
	Status  int
	Code    string
	Message string
	Extra   map[string]any // merged at top level of the body (e.g. revoked_sig)
	Detail  map[string]any // merged inside "error" (e.g. latest_epoch)
}

func (e *apiError) Error() string { return e.Code + ": " + e.Message }

func errBad(m string) *apiError      { return &apiError{Status: 400, Code: "bad_request", Message: m} }
func errNotFound(m string) *apiError { return &apiError{Status: 404, Code: "not_found", Message: m} }
func errForbidden() *apiError {
	return &apiError{Status: 403, Code: "forbidden", Message: "sem permissão"}
}
func errInternal(err error) *apiError {
	return &apiError{Status: 500, Code: "internal", Message: "erro interno", Extra: map[string]any{"_err": err}}
}
func errRate() *apiError {
	return &apiError{Status: 429, Code: "rate_limited", Message: "muitas requisições"}
}

func (s *Server) writeAPIErr(w http.ResponseWriter, e *apiError) {
	if e.Status == 500 {
		if err, ok := e.Extra["_err"].(error); ok {
			s.log.Error("erro interno", "err", err.Error())
		}
		e = &apiError{Status: 500, Code: "internal", Message: "erro interno"}
	}
	writeErr(w, e)
}

func writeErr(w http.ResponseWriter, e *apiError) {
	inner := map[string]any{"code": e.Code, "message": e.Message}
	for k, v := range e.Detail {
		inner[k] = v
	}
	body := map[string]any{"error": inner}
	for k, v := range e.Extra {
		if !strings.HasPrefix(k, "_") {
			body[k] = v
		}
	}
	writeJSON(w, e.Status, body)
}

func isCtxErr(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

func ms(t time.Time) uint64 { return uint64(t.UnixMilli()) }

func (s *Server) nowMs() time.Time { return s.now().Truncate(time.Millisecond) }

func idOK(s string) (proto.UUID, bool) {
	u, err := proto.ParseUUID(s)
	return u, err == nil
}
