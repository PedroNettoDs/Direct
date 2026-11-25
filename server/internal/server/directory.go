package server

import (
	"net/http"
	"strings"
	"time"

	"github.com/nettotech/direct/server/internal/proto"
)

type dirUser struct {
	UserID      string     `json:"user_id"`
	AdminLabel  string     `json:"admin_label"`
	DisplayName string     `json:"display_name"`
	Status      string     `json:"status"`
	Devices     []CertJSON `json:"devices"`
}

func (s *Server) handleDirectory(w http.ResponseWriter, r *http.Request, p *Principal) {
	now := s.now()
	rows, err := s.db.Query(r.Context(), `
		SELECT u.id, u.admin_label, u.display_name, u.status,
		       d.id, d.sign_pub, d.kex_pub, d.cert_sig, d.enrolled_at, d.expires_at
		FROM users u
		LEFT JOIN devices d ON d.user_id = u.id AND d.revoked_at IS NULL AND d.expires_at > $1
		WHERE u.disabled_at IS NULL
		ORDER BY u.created_at, u.id, d.enrolled_at, d.id`, now)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer rows.Close()
	users := []*dirUser{}
	byID := map[proto.UUID]*dirUser{}
	for rows.Next() {
		var uid proto.UUID
		var label, name, status string
		var did *proto.UUID
		var sp, kp, sig []byte
		var enr, exp *time.Time
		if err := rows.Scan(&uid, &label, &name, &status, &did, &sp, &kp, &sig, &enr, &exp); err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		u := byID[uid]
		if u == nil {
			u = &dirUser{UserID: proto.FormatUUID(uid), AdminLabel: label, DisplayName: name, Status: status, Devices: []CertJSON{}}
			byID[uid] = u
			users = append(users, u)
		}
		if did != nil {
			u.Devices = append(u.Devices, certJSON(*did, uid, label, sp, kp, *enr, *exp, sig))
		}
	}
	if err := rows.Err(); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 200, map[string]any{"users": users})
}

func (s *Server) handleDevices(w http.ResponseWriter, r *http.Request, p *Principal) {
	raw := r.URL.Query().Get("ids")
	if raw == "" {
		s.writeAPIErr(w, errBad("ids ausente"))
		return
	}
	parts := strings.Split(raw, ",")
	if len(parts) > 100 {
		s.writeAPIErr(w, errBad("máximo 100 ids"))
		return
	}
	ids := make([]proto.UUID, 0, len(parts))
	for _, x := range parts {
		u, ok := idOK(x)
		if !ok {
			s.writeAPIErr(w, errBad("id inválido"))
			return
		}
		ids = append(ids, u)
	}
	rows, err := s.db.Query(r.Context(), `
		SELECT d.id, d.user_id, u.admin_label, d.sign_pub, d.kex_pub, d.cert_sig, d.enrolled_at, d.expires_at, d.revoked_at
		FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = ANY($1) ORDER BY d.id`, ids)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer rows.Close()
	type item struct {
		Cert      CertJSON `json:"cert"`
		RevokedAt *uint64  `json:"revoked_at"`
	}
	out := []item{}
	for rows.Next() {
		var did, uid proto.UUID
		var label string
		var sp, kp, sig []byte
		var enr, exp time.Time
		var rev *time.Time
		if err := rows.Scan(&did, &uid, &label, &sp, &kp, &sig, &enr, &exp, &rev); err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		it := item{Cert: certJSON(did, uid, label, sp, kp, enr, exp, sig)}
		if rev != nil {
			v := ms(*rev)
			it.RevokedAt = &v
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 200, map[string]any{"devices": out})
}

func (s *Server) handleProfile(w http.ResponseWriter, r *http.Request, p *Principal) {
	// Every change is pushed to every connection.
	if !s.profileDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}
	var req struct {
		DisplayName string `json:"display_name"`
		Status      string `json:"status"`
	}
	if e := readJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	if !proto.ValidDisplayName(req.DisplayName) || !proto.ValidStatus(req.Status) {
		s.writeAPIErr(w, errBad("nome ou status inválido"))
		return
	}
	if _, err := s.db.Exec(r.Context(), `UPDATE users SET display_name = $2, status = $3 WHERE id = $1`,
		p.UserID, req.DisplayName, req.Status); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	s.hub.directoryChanged(p.UserID)
	w.WriteHeader(204)
}
