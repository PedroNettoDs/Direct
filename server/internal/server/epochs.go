package server

import (
	"context"
	"errors"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

type EpochItem struct {
	WrapID          int64    `json:"wrap_id"`
	ConversationID  string   `json:"conversation_id"`
	Epoch           uint32   `json:"epoch"`
	CreatorDeviceID string   `json:"creator_device_id"`
	KeyCommitment   string   `json:"key_commitment"`
	Recipients      []string `json:"recipients"`
	Signature       string   `json:"signature"`
	WrappedKey      string   `json:"wrapped_key"`
	ChainN          uint64   `json:"chain_n,omitempty"`    // groups only
	ChainHash       string   `json:"chain_hash,omitempty"` // groups only
}

type wrapReq struct {
	DeviceID   string `json:"device_id"`
	WrappedKey string `json:"wrapped_key"`
}

type epochReq struct {
	Epoch           uint32    `json:"epoch"`
	CreatorDeviceID string    `json:"creator_device_id"`
	KeyCommitment   string    `json:"key_commitment"`
	Recipients      []string  `json:"recipients"`
	Wraps           []wrapReq `json:"wraps"`
	EscrowWrap      string    `json:"escrow_wrap"`
	Signature       string    `json:"signature"`
	// Groups (docs/protocolo-grupos.md 10.3).
	ChainN    uint64         `json:"chain_n"`
	ChainHash string         `json:"chain_hash"`
	Meta      *GroupMetaJSON `json:"meta"`
}

// epochData is a parsed epochReq.
type epochData struct {
	epoch      uint32
	creator    proto.UUID
	commit     []byte
	escrowWrap []byte
	sig        []byte
	recips     []proto.UUID
	wraps      map[proto.UUID][]byte
	chainN     uint64   // 0 in direct conversations
	chainHash  [32]byte // groups only
}

func parseEpoch(req *epochReq) (*epochData, *apiError) {
	creator, okC := idOK(req.CreatorDeviceID)
	commit, errCm := proto.B64Fixed(req.KeyCommitment, 32)
	escrowWrap, errEw := proto.B64Fixed(req.EscrowWrap, 80)
	sig, errSg := proto.B64Fixed(req.Signature, 64)
	if !okC || errCm != nil || errEw != nil || errSg != nil || req.Epoch < 1 || len(req.Recipients) == 0 || len(req.Recipients) > 1000 {
		return nil, errBad("campos inválidos")
	}
	e := &epochData{epoch: req.Epoch, creator: creator, commit: commit, escrowWrap: escrowWrap, sig: sig,
		recips: make([]proto.UUID, len(req.Recipients)), wraps: make(map[proto.UUID][]byte, len(req.Wraps))}
	for i, x := range req.Recipients {
		u, ok := idOK(x)
		if !ok {
			return nil, errBad("recipients inválido")
		}
		e.recips[i] = u
	}
	for _, wr := range req.Wraps {
		d, ok := idOK(wr.DeviceID)
		wk, err := proto.B64Fixed(wr.WrappedKey, 80)
		if _, dup := e.wraps[d]; !ok || err != nil || dup {
			return nil, errBad("wraps inválido")
		}
		e.wraps[d] = wk
	}
	return e, nil
}

// parseChainRef reads chain_n and chain_hash of a group epoch.
func (e *epochData) parseChainRef(req *epochReq) bool {
	h, err := proto.B64Fixed(req.ChainHash, 32)
	if err != nil || req.ChainN < 1 || req.ChainN >= maxSafeInt {
		return false
	}
	e.chainN = req.ChainN
	copy(e.chainHash[:], h)
	return true
}

// checkEpoch runs steps 2 to 5 of protocolo.md 9.6 inside the transaction that locked the
// conversation. The caller checked the creator, the membership and, in groups, the chain position.
func (s *Server) checkEpoch(ctx context.Context, tx pgx.Tx, conv proto.UUID, e *epochData, latest uint32) *apiError {
	// 2. epoch = latest + 1.
	if e.epoch != latest+1 {
		return &apiError{Status: 409, Code: "epoch_conflict", Message: "época já existe",
			Detail: map[string]any{"latest_epoch": latest}}
	}
	// 3. recipients strictly ascending and equal to the active device set now.
	for i := 1; i < len(e.recips); i++ {
		if !uuidLess(e.recips[i-1], e.recips[i]) {
			return errBad("recipients fora de ordem")
		}
	}
	active, err := s.activeDevices(ctx, tx, conv, s.now())
	if err != nil {
		return errInternal(err)
	}
	if string(concat(active)) != string(concat(e.recips)) {
		return &apiError{Status: 409, Code: "device_set_changed", Message: "aparelhos mudaram"}
	}
	// 4. exactly one wrap per recipient.
	if len(e.wraps) != len(e.recips) {
		return errBad("wraps não cobre os destinatários")
	}
	for _, rc := range e.recips {
		if _, ok := e.wraps[rc]; !ok {
			return errBad("wraps não cobre os destinatários")
		}
	}
	// 5. signature over epoch_bytes with this server's escrow_pub, by the creator's sign key.
	var escrowPub, signPub []byte
	if err := tx.QueryRow(ctx, `SELECT escrow_pub FROM server_keys`).Scan(&escrowPub); err != nil {
		return errInternal(err)
	}
	if escrowPub == nil {
		return &apiError{Status: 503, Code: "unavailable", Message: "escrow ainda não configurado"}
	}
	if err := tx.QueryRow(ctx, `SELECT sign_pub FROM devices WHERE id = $1`, e.creator).Scan(&signPub); err != nil {
		return errInternal(err)
	}
	var signed []byte
	if e.chainN > 0 {
		signed = proto.GroupEpochBytes(conv, e.epoch, e.creator, e.commit, escrowPub, e.chainN, e.chainHash, e.recips)
	} else {
		signed = proto.EpochBytes(conv, e.epoch, e.creator, e.commit, escrowPub, e.recips)
	}
	if !proto.Verify(signPub, signed, e.sig) {
		return &apiError{Status: 400, Code: "bad_signature", Message: "assinatura inválida"}
	}
	return nil
}

// insertEpoch stores a checked epoch and returns the item of each recipient (step 6).
// wrap_id is the client's sync cursor: with the lock, a lower id never commits after a higher one.
func insertEpoch(ctx context.Context, tx pgx.Tx, s *Server, conv proto.UUID, e *epochData) (map[proto.UUID]EpochItem, error) {
	if err := store.LockWraps(ctx, tx); err != nil {
		return nil, err
	}
	var chainN, chainHash any
	if e.chainN > 0 {
		chainN, chainHash = int64(e.chainN), e.chainHash[:]
	}
	if _, err := tx.Exec(ctx, `INSERT INTO epochs (conversation_id, epoch, created_by_device, created_at, key_commitment,
		recipients, signature, chain_n, chain_hash) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		conv, e.epoch, e.creator, s.nowMs(), e.commit, concat(e.recips), e.sig, chainN, chainHash); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `UPDATE conversations SET latest_epoch = $2 WHERE id = $1`, conv, e.epoch); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO epoch_key_wraps (conversation_id, epoch, recipient_device_id, wrapped_key, source)
		VALUES ($1,$2,NULL,$3,'creator')`, conv, e.epoch, e.escrowWrap); err != nil {
		return nil, err
	}
	recips := make([]string, len(e.recips))
	for i, r := range e.recips {
		recips[i] = proto.FormatUUID(r)
	}
	items := make(map[proto.UUID]EpochItem, len(e.recips))
	for _, rc := range e.recips {
		id, err := store.InsertWrap(ctx, tx, conv, e.epoch, rc, e.wraps[rc], store.WrapByCreator)
		if err != nil {
			return nil, err
		}
		it := EpochItem{WrapID: id, ConversationID: proto.FormatUUID(conv), Epoch: e.epoch,
			CreatorDeviceID: proto.FormatUUID(e.creator), KeyCommitment: proto.B64Encode(e.commit),
			Recipients: recips, Signature: proto.B64Encode(e.sig), WrappedKey: proto.B64Encode(e.wraps[rc])}
		if e.chainN > 0 {
			it.ChainN, it.ChainHash = e.chainN, proto.B64Encode(e.chainHash[:])
		}
		items[rc] = it
	}
	return items, nil
}

func (s *Server) handleCreateEpoch(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, ok := idOK(r.PathValue("id"))
	if !ok {
		s.writeAPIErr(w, errBad("id inválido"))
		return
	}
	var req epochReq
	if e := readBigJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	ep, perr := parseEpoch(&req)
	if perr != nil {
		s.writeAPIErr(w, perr)
		return
	}

	if !s.epochDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}

	ctx := r.Context()
	// 1. Creator is the authenticated device and its user is a member.
	if ep.creator != p.DeviceID {
		s.writeAPIErr(w, errForbidden())
		return
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer tx.Rollback(ctx)
	c, aerr := lockMember(ctx, tx, s, conv, p.UserID)
	if aerr != nil {
		s.writeAPIErr(w, aerr)
		return
	}
	var meta *groupMeta
	if c.kind == "group" {
		if c.closed {
			s.writeAPIErr(w, errGroupClosed())
			return
		}
		if !ep.parseChainRef(&req) {
			s.writeAPIErr(w, errBad("chain_n ou chain_hash inválido"))
			return
		}
		if ep.chainN != c.chainN || string(ep.chainHash[:]) != string(c.chainHash) {
			s.writeAPIErr(w, errChainConflict(c.chainN))
			return
		}
		commit, err := store.CurrentMetaCommit(ctx, tx, conv)
		if err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		if meta, aerr = epochMeta(req.Meta, ep.epoch, commit); aerr != nil {
			s.writeAPIErr(w, aerr)
			return
		}
	}
	if e := s.checkEpoch(ctx, tx, conv, ep, c.latest); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	items, err := insertEpoch(ctx, tx, s, conv, ep)
	if err == nil && meta != nil {
		err = saveMeta(ctx, tx, conv, meta)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	s.hub.epochCreated(conv, items)
	writeJSON(w, 201, map[string]any{"epoch": req.Epoch})
}

type lockedConv struct {
	kind      string
	latest    uint32
	chainN    uint64
	chainHash []byte
	closed    bool
}

// lockMember locks the conversation row and requires the user to be a member.
func lockMember(ctx context.Context, tx pgx.Tx, s *Server, conv, user proto.UUID) (lockedConv, *apiError) {
	var c lockedConv
	err := tx.QueryRow(ctx, `SELECT kind, latest_epoch, chain_n, chain_hash, closed_at IS NOT NULL
		FROM conversations WHERE id = $1 FOR UPDATE`, conv).Scan(&c.kind, &c.latest, &c.chainN, &c.chainHash, &c.closed)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, errNotFound("conversa inexistente")
	}
	if err != nil {
		return c, errInternal(err)
	}
	member, err := s.isMember(ctx, tx, conv, user)
	if err != nil {
		return c, errInternal(err)
	}
	if !member {
		return c, errForbidden()
	}
	return c, nil
}

const itemSelect = `SELECT w.wrap_id, w.conversation_id, w.epoch, e.created_by_device, e.key_commitment, e.recipients,
		e.signature, w.wrapped_key, e.chain_n, e.chain_hash
	FROM epoch_key_wraps w
	JOIN epochs e ON e.conversation_id = w.conversation_id AND e.epoch = w.epoch `

// maxItemBytes keeps one page of group epochs, whose recipient lists are long, around 2 MiB
// (docs/protocolo-grupos.md 5.5).
const maxItemBytes = 2 << 20

// scanItems reads itemSelect rows, stopping after about maxBytes of JSON (0 = no limit).
func scanItems(rows pgx.Rows, maxBytes int) (items []EpochItem, truncated bool, err error) {
	defer rows.Close()
	items = []EpochItem{}
	size := 0
	for rows.Next() {
		var it EpochItem
		var conv, creator proto.UUID
		var commit, recips, sig, wk, chainHash []byte
		var chainN *uint64
		if err := rows.Scan(&it.WrapID, &conv, &it.Epoch, &creator, &commit, &recips, &sig, &wk, &chainN, &chainHash); err != nil {
			return nil, false, err
		}
		it.ConversationID, it.CreatorDeviceID = proto.FormatUUID(conv), proto.FormatUUID(creator)
		it.KeyCommitment, it.Recipients = proto.B64Encode(commit), splitRecipients(recips)
		it.Signature, it.WrappedKey = proto.B64Encode(sig), proto.B64Encode(wk)
		if chainN != nil {
			it.ChainN, it.ChainHash = *chainN, proto.B64Encode(chainHash)
		}
		size += 500 + 39*len(it.Recipients)
		if maxBytes > 0 && size > maxBytes && len(items) > 0 {
			return items, true, nil
		}
		items = append(items, it)
	}
	return items, false, rows.Err()
}

func splitRecipients(b []byte) []string {
	out := make([]string, 0, len(b)/16)
	for i := 0; i+16 <= len(b); i += 16 {
		out = append(out, proto.FormatUUID(proto.UUID(b[i:i+16])))
	}
	return out
}

func (s *Server) handleMyEpochs(w http.ResponseWriter, r *http.Request, p *Principal) {
	after, limit := int64(0), 500
	if v := r.URL.Query().Get("after"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			s.writeAPIErr(w, errBad("after inválido"))
			return
		}
		after = n
	}
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			s.writeAPIErr(w, errBad("limit inválido"))
			return
		}
		limit = min(n, 500)
	}
	rows, err := s.db.Query(r.Context(), itemSelect+`WHERE w.recipient_device_id = $1 AND w.wrap_id > $2
		ORDER BY w.wrap_id LIMIT $3`, p.DeviceID, after, limit+1)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	items, more, err := scanItems(rows, maxItemBytes)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	if len(items) > limit {
		items, more = items[:limit], true
	}
	writeJSON(w, 200, map[string]any{"items": items, "has_more": more})
}

// GET /v1/conversations/{id}/epochs/mine: every item of this device in the conversation, because
// group keys are kept only in memory (docs/protocolo-grupos.md 7.6).
func (s *Server) handleConversationEpochs(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, _, ok := s.memberRoute(w, r, p)
	if !ok {
		return
	}
	rows, err := s.db.Query(r.Context(), itemSelect+`WHERE w.recipient_device_id = $1 AND w.conversation_id = $2
		ORDER BY w.wrap_id`, p.DeviceID, conv)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	items, _, err := scanItems(rows, 0)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 200, map[string]any{"items": items, "has_more": false})
}
