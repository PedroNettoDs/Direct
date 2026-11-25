package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
)

const (
	wsAuthTimeout = 10 * time.Second
	wsIdleTimeout = 75 * time.Second
)

type wsFrame struct {
	Type          string          `json:"type"`
	ReqID         string          `json:"req_id"`
	TS            json.RawMessage `json:"ts"`
	AccessToken   string          `json:"access_token"`
	Conversations []string        `json:"conversations"`
	Message       *MessageIn      `json:"message"`
}

// deviceState returns "" for an active device, else "device_revoked" or "device_expired".
func (s *Server) deviceState(ctx context.Context, dev proto.UUID) (string, error) {
	var exp time.Time
	var rev, dis *time.Time
	err := s.db.QueryRow(ctx, `SELECT d.expires_at, d.revoked_at, u.disabled_at FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = $1`, dev).
		Scan(&exp, &rev, &dis)
	switch {
	case err != nil:
		return "", err
	case rev != nil || dis != nil:
		return "device_revoked", nil
	case !exp.After(s.now()):
		return "device_expired", nil
	}
	return "", nil
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	if !s.wsIP.Allow(s.clientIP(r)) {
		s.writeAPIErr(w, errRate())
		return
	}
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return // Accept already replied
	}
	defer ws.CloseNow()
	ws.SetReadLimit(maxBody)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	c := &conn{ws: ws, out: make(chan []byte, 64)}

	// First frame: auth, within 10 s.
	authTimer := time.AfterFunc(wsAuthTimeout, func() { c.close(4001, "auth atrasado") })
	typ, data, err := ws.Read(ctx)
	authTimer.Stop()
	if err != nil {
		return
	}
	var f wsFrame
	if typ != websocket.MessageText || json.Unmarshal(data, &f) != nil || f.Type != "auth" {
		c.close(4000, "protocolo")
		<-time.After(100 * time.Millisecond)
		return
	}
	p, aerr := s.authenticate(ctx, f.AccessToken)
	if aerr != nil {
		code := 4001
		switch aerr.Code {
		case "device_revoked":
			code = 4003
		case "device_expired":
			code = 4004
		case "internal":
			code = 1011
		}
		_ = ws.Close(websocket.StatusCode(code), aerr.Code)
		return
	}
	c.device, c.user = p.DeviceID, p.UserID
	if f.Conversations != nil {
		if len(f.Conversations) < 1 || len(f.Conversations) > 10 {
			_ = ws.Close(4000, "conversations")
			return
		}
		c.scope = map[proto.UUID]bool{}
		for _, x := range f.Conversations {
			id, ok := idOK(x)
			if ok {
				ok, err = s.isMember(ctx, s.db, id, p.UserID)
			}
			if err != nil || !ok {
				_ = ws.Close(4000, "conversations")
				return
			}
			c.scope[id] = true
		}
	}

	// Writer goroutine: the only writer of data frames.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case b := <-c.out:
				wctx, wc := context.WithTimeout(ctx, 10*time.Second)
				err := ws.Write(wctx, websocket.MessageText, b)
				wc()
				if err != nil {
					return
				}
			}
		}
	}()
	c.send(map[string]any{"type": "ready", "device_id": proto.FormatUUID(p.DeviceID),
		"server_time": ms(s.now()), "token_expires_at": ms(p.TokenExpires)})
	s.hub.add(c)
	defer s.hub.remove(c)

	expiry := time.AfterFunc(max(p.TokenExpires.Sub(s.now()), 0), func() { c.close(4001, "token vencido") })
	defer expiry.Stop()
	idle := time.AfterFunc(wsIdleTimeout, func() { c.close(4008, "ocioso") })
	defer idle.Stop()
	flood := newLimiter(50, 100)
	flood.now = s.now

	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			return
		}
		idle.Reset(wsIdleTimeout)
		if !flood.Allow("c") {
			c.close(4029, "limite de taxa")
			continue
		}
		var f wsFrame
		if typ != websocket.MessageText || json.Unmarshal(data, &f) != nil {
			c.close(4000, "protocolo")
			continue
		}
		switch f.Type {
		case "ping":
			c.send(map[string]any{"type": "pong", "ts": f.TS})
		case "send":
			s.wsSend(ctx, c, p, &f)
		default:
			c.close(4000, "protocolo")
		}
	}
}

func (s *Server) wsSend(ctx context.Context, c *conn, p *Principal, f *wsFrame) {
	if f.ReqID == "" || len(f.ReqID) > 64 || f.Message == nil {
		c.close(4000, "protocolo")
		return
	}
	reply := func(e *apiError) {
		fr := map[string]any{"type": "error", "req_id": f.ReqID, "code": e.Code, "message": e.Message}
		for k, v := range e.Detail {
			fr[k] = v
		}
		c.send(fr)
	}
	if st, err := s.deviceState(ctx, p.DeviceID); err != nil {
		s.log.Error("ws device state", "err", err.Error())
		reply(&apiError{Code: "internal", Message: "erro interno"})
		return
	} else if st != "" {
		if st == "device_revoked" {
			c.close(4003, "revogado")
		} else {
			c.close(4004, "vencido")
		}
		return
	}
	if !s.sendDev.Allow(proto.FormatUUID(p.DeviceID)) {
		reply(&apiError{Code: "rate_limited", Message: "muitas mensagens"})
		return
	}
	// storeMessage only needs the request context.
	req := (&http.Request{}).WithContext(ctx)
	m, members, dup, e := s.storeMessage(req, p, *f.Message)
	if e != nil {
		if e.Status == 500 {
			if err, ok := e.Extra["_err"].(error); ok && !errors.Is(err, context.Canceled) {
				s.log.Error("ws send", "err", err.Error())
			}
			e = &apiError{Code: "internal", Message: "erro interno"}
		}
		reply(e)
		return
	}
	c.send(map[string]any{"type": "ack", "req_id": f.ReqID, "conversation_id": f.Message.ConversationID,
		"message_id": f.Message.MessageID, "seq": m.Seq, "created_at": m.CreatedAt})
	if !dup {
		conv, _ := proto.ParseUUID(f.Message.ConversationID)
		out, err := s.wireMessage(ctx, p, m)
		if err != nil { // unknown state: the others get it from the history
			s.log.Error("ws send", "err", err.Error())
			return
		}
		s.hub.messageCreated(conv, out, members, c)
	}
}

// listenNotifications handles the NOTIFY of the CLI and of directd itself:
// device_revoked '<device>', member_access '<user> <0|1> <ms>', group_change '<conversation> <n>'.
func (s *Server) listenNotifications(ctx context.Context) {
	for again := false; ctx.Err() == nil; again = true {
		if err := s.listenOnce(ctx, again); err != nil && ctx.Err() == nil {
			s.log.Error("listen", "err", err.Error())
		}
		select {
		case <-ctx.Done():
		case <-time.After(2 * time.Second):
		}
	}
}

func (s *Server) listenOnce(ctx context.Context, again bool) error {
	pc, err := s.db.Acquire(ctx)
	if err != nil {
		return err
	}
	defer pc.Release()
	for _, sql := range []string{`LISTEN device_revoked`, `LISTEN member_access`, `LISTEN group_change`} {
		if _, err := pc.Exec(ctx, sql); err != nil {
			return err
		}
	}
	// Access and group events may have been lost meanwhile: reconnecting clients fetch everything.
	if again {
		s.hub.closeAll(1001, "reconecte")
	}
	// A NOTIFY sent while not listening is lost: check whoever is connected.
	for _, dev := range s.hub.devices() {
		st, err := s.deviceState(ctx, dev)
		if err != nil {
			return err
		}
		if st == "device_revoked" {
			s.hub.closeDevice(dev, 4003, "revogado")
		}
	}
	for {
		n, err := pc.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		switch n.Channel {
		case "member_access":
			if err := s.announceAccess(ctx, n.Payload); err != nil {
				return err
			}
			continue
		case "group_change":
			id, num, _ := strings.Cut(n.Payload, " ")
			conv, ok := idOK(id)
			if pos, err := strconv.ParseUint(num, 10, 63); ok && err == nil && pos > 0 {
				s.announceChange(ctx, conv, pos, nil)
			}
			continue
		}
		dev, ok := idOK(n.Payload)
		if !ok {
			continue
		}
		s.hub.closeDevice(dev, 4003, "revogado")
		var user proto.UUID
		switch err := s.db.QueryRow(ctx, `SELECT user_id FROM devices WHERE id = $1`, dev).Scan(&user); {
		case err == nil:
			s.hub.directoryChanged(user)
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
	}
}
