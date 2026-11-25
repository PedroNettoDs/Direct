package server

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/nettotech/direct/server/internal/proto"
)

// conn is one authenticated WebSocket connection.
type conn struct {
	seq    uint64
	device proto.UUID
	user   proto.UUID
	scope  map[proto.UUID]bool // nil = every conversation of the user
	out    chan []byte
	ws     *websocket.Conn

	once sync.Once

	// directory_changed coalescing: at most one frame every dirEvery.
	dirMu   sync.Mutex
	dirLast time.Time
	dirNext any // waiting for its timer
}

// dirEvery is the minimum interval between two directory_changed frames on a connection.
const dirEvery = 3 * time.Second

// sendDirectory sends the first change at once and merges those that follow into a single frame:
// the client refetches the whole directory anyway.
func (c *conn) sendDirectory(v any) {
	c.dirMu.Lock()
	defer c.dirMu.Unlock()
	if c.dirNext != nil {
		c.dirNext = v
		return
	}
	wait := dirEvery - time.Since(c.dirLast)
	if wait <= 0 {
		c.dirLast = time.Now()
		c.send(v)
		return
	}
	c.dirNext = v
	time.AfterFunc(wait, func() {
		c.dirMu.Lock()
		defer c.dirMu.Unlock()
		c.dirLast = time.Now()
		c.send(c.dirNext)
		c.dirNext = nil
	})
}

func (c *conn) allows(conv proto.UUID) bool { return c.scope == nil || c.scope[conv] }

// close ends the connection with a WebSocket close code (4xxx codes of protocolo.md 11.7).
func (c *conn) close(code int, reason string) {
	c.once.Do(func() { go c.ws.Close(websocket.StatusCode(code), reason) })
}

// send queues a frame without blocking; a client that cannot keep up is dropped.
func (c *conn) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	select {
	case c.out <- b:
	default:
		c.close(4029, "cliente lento")
	}
}

type hub struct {
	mu    sync.RWMutex
	conns map[*conn]struct{}
	next  uint64
}

func newHub() *hub { return &hub{conns: map[*conn]struct{}{}} }

// add registers c, closing the oldest connections of the same device beyond the limit of 4.
func (h *hub) add(c *conn) {
	h.mu.Lock()
	h.next++
	c.seq = h.next
	var same []*conn
	for o := range h.conns {
		if o.device == c.device {
			same = append(same, o)
		}
	}
	for len(same) >= maxConnsPerDv {
		oldest := 0
		for i, o := range same {
			if o.seq < same[oldest].seq {
				oldest = i
			}
		}
		same[oldest].close(4009, "substituída por conexão mais nova")
		delete(h.conns, same[oldest])
		same = append(same[:oldest], same[oldest+1:]...)
	}
	h.conns[c] = struct{}{}
	h.mu.Unlock()
}

func (h *hub) remove(c *conn) {
	h.mu.Lock()
	delete(h.conns, c)
	h.mu.Unlock()
}

func (h *hub) each(f func(*conn)) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.conns {
		f(c)
	}
}

func has(ids []proto.UUID, id proto.UUID) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

// messageCreated takes a *MessageJSON or a proto.SealedMessage.
func (h *hub) messageCreated(conv proto.UUID, m any, members []proto.UUID, except *conn) {
	h.each(func(c *conn) {
		if c != except && has(members, c.user) && c.allows(conv) {
			c.send(map[string]any{"type": "message", "message": m})
		}
	})
}

func (h *hub) epochCreated(conv proto.UUID, items map[proto.UUID]EpochItem) {
	h.each(func(c *conn) {
		if it, ok := items[c.device]; ok && c.allows(conv) {
			c.send(map[string]any{"type": "epoch", "item": it})
		}
	})
}

func (h *hub) conversationCreated(conv *ConversationJSON, members []proto.UUID) {
	h.each(func(c *conn) {
		if c.scope == nil && has(members, c.user) {
			c.send(map[string]any{"type": "conversation", "conversation": conv})
		}
	})
}

func (h *hub) groupChanged(conv proto.UUID, change ChangeJSON, meta *GroupMetaJSON, users []proto.UUID) {
	h.each(func(c *conn) {
		if has(users, c.user) && c.allows(conv) {
			c.send(map[string]any{"type": "group_change", "conversation_id": proto.FormatUUID(conv),
				"change": change, "meta": meta})
		}
	})
}

// memberAccess sends each connection the groups of its scope among convs.
func (h *hub) memberAccess(ev proto.MemberAccessEvent, convs []proto.UUID, members map[proto.UUID][]proto.UUID) {
	h.each(func(c *conn) {
		out := ev
		for _, conv := range convs {
			if has(members[conv], c.user) && c.allows(conv) {
				out.Conversations = append(out.Conversations, proto.FormatUUID(conv))
			}
		}
		if len(out.Conversations) > 0 {
			c.send(out)
		}
	})
}

func (h *hub) directoryChanged(user proto.UUID) {
	h.each(func(c *conn) {
		c.sendDirectory(map[string]any{"type": "directory_changed", "user_id": proto.FormatUUID(user)})
	})
}

// devices returns the ids of the connected devices.
func (h *hub) devices() []proto.UUID {
	var out []proto.UUID
	h.each(func(c *conn) {
		if !has(out, c.device) {
			out = append(out, c.device)
		}
	})
	return out
}

func (h *hub) closeDevice(dev proto.UUID, code int, reason string) {
	h.each(func(c *conn) {
		if c.device == dev {
			c.close(code, reason)
		}
	})
}

func (h *hub) closeAll(code int, reason string) { h.each(func(c *conn) { c.close(code, reason) }) }
