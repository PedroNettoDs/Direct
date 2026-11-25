package server

// Group routes (docs/protocolo-grupos.md 10). The signed chain decides who is a member; the
// server verifies it as an extra defense and mirrors it in conversation_members.

import (
	"context"
	"errors"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

func errChain(err error) *apiError {
	return &apiError{Status: 400, Code: "chain_invalid", Message: "registro do grupo inválido",
		Detail: map[string]any{"reason": proto.CodeOf(err)}}
}

func errChainConflict(top uint64) *apiError {
	return &apiError{Status: 409, Code: "chain_conflict", Message: "a cadeia do grupo mudou",
		Detail: map[string]any{"chain_n": top}}
}

func errGroupClosed() *apiError {
	return &apiError{Status: 409, Code: "group_closed", Message: "grupo encerrado"}
}

// ---- wire forms ----

type changeReq struct {
	ChangeBytes string `json:"change_bytes"`
	Signature   string `json:"signature"`
}

// ChangeJSON is a chain record as delivered (docs/protocolo-grupos.md 2.8).
type ChangeJSON struct {
	N           uint64 `json:"n"`
	ChangeBytes string `json:"change_bytes"`
	Signature   string `json:"signature"`
	ReceivedAt  uint64 `json:"received_at"`
}

func changeJSON(c store.ChangeRow) ChangeJSON {
	return ChangeJSON{N: c.N, ChangeBytes: proto.B64Encode(c.Bytes), Signature: proto.B64Encode(c.Sig), ReceivedAt: ms(c.ReceivedAt)}
}

// GroupMetaJSON is the encrypted name, photo and description (docs/protocolo-grupos.md 6.3).
type GroupMetaJSON struct {
	Epoch      uint32 `json:"epoch"`
	MetaCommit string `json:"meta_commit"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
}

type groupMeta struct {
	epoch             uint32
	commit, nonce, ct []byte
	wire              GroupMetaJSON
}

// parseMeta requires m to be the meta of exactly that epoch and commit.
func parseMeta(m *GroupMetaJSON, epoch uint32, commit [32]byte) (*groupMeta, *apiError) {
	if m == nil {
		return nil, errBad("falta meta")
	}
	c, e1 := proto.B64Fixed(m.MetaCommit, 32)
	n, e2 := proto.B64Fixed(m.Nonce, 24)
	ct, e3 := proto.B64Decode(m.Ciphertext)
	if size := len(ct) - 16; e1 != nil || e2 != nil || e3 != nil || size < 256 || size > proto.MaxPadded || size%256 != 0 {
		return nil, errBad("meta inválido")
	}
	if m.Epoch != epoch || string(c) != string(commit[:]) {
		return nil, errBad("meta de outra época ou de outro compromisso")
	}
	return &groupMeta{epoch: epoch, commit: c, nonce: n, ct: ct, wire: *m}, nil
}

// epochMeta is the rule of G 6.4: a new epoch of a group with a name carries it, re-encrypted.
func epochMeta(m *GroupMetaJSON, epoch uint32, commit [32]byte) (*groupMeta, *apiError) {
	if commit == ([32]byte{}) {
		if m != nil {
			return nil, errBad("o grupo ainda não tem meta")
		}
		return nil, nil
	}
	return parseMeta(m, epoch, commit)
}

func saveMeta(ctx context.Context, tx pgx.Tx, conv proto.UUID, m *groupMeta) error {
	_, err := tx.Exec(ctx, `INSERT INTO group_meta (conversation_id, epoch, meta_commit, nonce, ciphertext) VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (conversation_id, epoch) DO UPDATE SET meta_commit = $3, nonce = $4, ciphertext = $5`,
		conv, m.epoch, m.commit, m.nonce, m.ct)
	return err
}

// parseChange decodes the wire record and requires the authenticated device as its author:
// moderator records never come over HTTP.
func parseChange(req *changeReq, p *Principal) (proto.SignedChange, proto.GroupChange, *apiError) {
	var rec proto.SignedChange
	var c proto.GroupChange
	if req == nil {
		return rec, c, errBad("falta change")
	}
	var e1, e2 error
	rec.Bytes, e1 = proto.B64Decode(req.ChangeBytes)
	rec.Sig, e2 = proto.B64Fixed(req.Signature, 64)
	if e1 != nil || e2 != nil {
		return rec, c, errBad("change inválido")
	}
	c, err := proto.DecodeChange(rec.Bytes)
	if err != nil {
		return rec, c, errChain(&proto.ChainError{Code: proto.ChainFormat})
	}
	if c.AuthorType != proto.AuthorDevice || c.AuthorDevice != p.DeviceID {
		return rec, c, errForbidden()
	}
	return rec, c, nil
}

// requestEpoch parses the epoch that travels with a record: it must point at that record.
func requestEpoch(req *epochReq, p *Principal, n uint64, head [32]byte) (*epochData, *apiError) {
	ep, e := parseEpoch(req)
	if e != nil {
		return nil, e
	}
	if ep.creator != p.DeviceID {
		return nil, errForbidden()
	}
	if !ep.parseChainRef(req) || ep.chainN != n || ep.chainHash != head || req.Meta != nil {
		return nil, errBad("época não aponta para este registro")
	}
	return ep, nil
}

// ---- POST /v1/groups ----

func (s *Server) handleCreateGroup(w http.ResponseWriter, r *http.Request, p *Principal) {
	var req struct {
		Change *changeReq     `json:"change"`
		Epoch  *epochReq      `json:"epoch"`
		Meta   *GroupMetaJSON `json:"meta"`
	}
	if e := readBigJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	if !s.epochDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}
	rec, c, aerr := parseChange(req.Change, p)
	if aerr != nil {
		s.writeAPIErr(w, aerr)
		return
	}
	if req.Epoch == nil {
		s.writeAPIErr(w, errBad("falta epoch"))
		return
	}
	conv, items, out, members, aerr := s.createGroup(r.Context(), p, rec, c, req.Epoch, req.Meta)
	if aerr != nil {
		s.writeAPIErr(w, aerr)
		return
	}
	ev := *out
	s.hub.conversationCreated(&ev, members)
	s.hub.epochCreated(conv, items)
	writeJSON(w, 201, out)
}

func (s *Server) createGroup(ctx context.Context, p *Principal, rec proto.SignedChange, c proto.GroupChange,
	epReq *epochReq, metaReq *GroupMetaJSON) (conv proto.UUID, items map[proto.UUID]EpochItem, out *ConversationJSON, members []proto.UUID, aerr *apiError) {
	conv = c.Conv
	fail := func(e *apiError) (proto.UUID, map[proto.UUID]EpochItem, *ConversationJSON, []proto.UUID, *apiError) {
		return conv, nil, nil, nil, e
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return fail(errInternal(err))
	}
	defer tx.Rollback(ctx)
	free, err := store.InsertGroup(ctx, tx, conv, s.nowMs())
	if err != nil {
		return fail(errInternal(err))
	}
	if !free {
		return fail(&apiError{Status: 409, Code: "group_exists", Message: "id de grupo já usado"})
	}
	if body, err := proto.ParseBody(c.Kind, c.Body); err == nil && c.Kind == proto.KindCreate {
		users := make([]proto.UUID, len(body.Members))
		for i, m := range body.Members {
			users[i] = m.User
		}
		ok, err := store.UsersEnabled(ctx, tx, users)
		if err != nil {
			return fail(errInternal(err))
		}
		if !ok {
			return fail(errBad("usuário inexistente ou desativado"))
		}
	}
	keys, err := store.ChainKeys(ctx, tx, []proto.SignedChange{rec})
	if err != nil {
		return fail(errInternal(err))
	}
	st := proto.NewGroupState(conv)
	if err := st.Apply(rec, keys); err != nil {
		return fail(errChain(err))
	}
	ep, e := requestEpoch(epReq, p, st.N, st.Head)
	if e != nil {
		return fail(e)
	}
	meta, e := parseMeta(metaReq, 1, st.MetaCommit)
	if e != nil {
		return fail(e)
	}
	if err := store.AppendChange(ctx, tx, rec, st, s.nowMs()); err != nil {
		return fail(errInternal(err))
	}
	if e := s.checkEpoch(ctx, tx, conv, ep, 0); e != nil {
		return fail(e)
	}
	if items, err = insertEpoch(ctx, tx, s, conv, ep); err == nil {
		err = saveMeta(ctx, tx, conv, meta)
	}
	if err == nil {
		out, members, err = s.loadConversation(ctx, tx, conv)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		return fail(errInternal(err))
	}
	return conv, items, out, members, nil
}

// ---- POST /v1/groups/{id}/changes ----

type appendReq struct {
	Change *changeReq     `json:"change"`
	Epoch  *epochReq      `json:"epoch"`
	Meta   *GroupMetaJSON `json:"meta"`
}

func (s *Server) handleAppendChange(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, ok := idOK(r.PathValue("id"))
	if !ok {
		s.writeAPIErr(w, errBad("id inválido"))
		return
	}
	var req appendReq
	if e := readBigJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	if !s.epochDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}
	n, items, meta, aerr := s.appendChange(r.Context(), p, conv, &req)
	if aerr != nil {
		s.writeAPIErr(w, aerr)
		return
	}
	s.announceChange(context.WithoutCancel(r.Context()), conv, n, meta)
	s.hub.epochCreated(conv, items)
	writeJSON(w, 201, map[string]any{"n": n})
}

func (s *Server) appendChange(ctx context.Context, p *Principal, conv proto.UUID, req *appendReq) (
	n uint64, items map[proto.UUID]EpochItem, wire *GroupMetaJSON, aerr *apiError) {
	fail := func(e *apiError) (uint64, map[proto.UUID]EpochItem, *GroupMetaJSON, *apiError) { return 0, nil, nil, e }
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return fail(errInternal(err))
	}
	defer tx.Rollback(ctx)
	// 1. Member, and the author is the authenticated device.
	cv, e := lockMember(ctx, tx, s, conv, p.UserID)
	if e != nil {
		return fail(e)
	}
	if cv.kind != "group" {
		return fail(errBad("a conversa não é um grupo"))
	}
	rec, c, e := parseChange(req.Change, p)
	if e != nil {
		return fail(e)
	}
	// 2. Position.
	if c.N != cv.chainN+1 {
		return fail(errChainConflict(cv.chainN))
	}
	if cv.closed {
		return fail(errGroupClosed())
	}
	// 3. The record, on top of the verified chain.
	chain, err := store.LoadChain(ctx, tx, conv, rec)
	if err != nil {
		return fail(errInternal(err))
	}
	st := chain.State
	if err := st.Apply(rec, chain.Keys); err != nil {
		return fail(errChain(err))
	}
	body, err := proto.ParseBody(c.Kind, c.Body)
	if err != nil {
		return fail(errInternal(err))
	}
	if c.Kind == proto.KindAdd {
		ok, err := store.UsersEnabled(ctx, tx, body.Users)
		if err != nil {
			return fail(errInternal(err))
		}
		if !ok {
			return fail(errBad("usuário inexistente ou desativado"))
		}
	}
	// 4. What must travel with the record.
	var ep *epochData
	var meta *groupMeta
	switch c.Kind {
	case proto.KindAdd, proto.KindRemove:
		if req.Epoch == nil {
			return fail(errBad("falta epoch"))
		}
		if ep, e = requestEpoch(req.Epoch, p, st.N, st.Head); e != nil {
			return fail(e)
		}
		if meta, e = epochMeta(req.Meta, ep.epoch, st.MetaCommit); e != nil {
			return fail(e)
		}
	case proto.KindRename:
		if req.Epoch != nil || cv.latest == 0 {
			return fail(errBad("renomear usa a época atual"))
		}
		if meta, e = parseMeta(req.Meta, cv.latest, st.MetaCommit); e != nil {
			return fail(e)
		}
	default:
		if req.Epoch != nil || req.Meta != nil {
			return fail(errBad("este registro não leva epoch nem meta"))
		}
	}
	// 5. Store.
	if err := store.AppendChange(ctx, tx, rec, st, s.nowMs()); err != nil {
		return fail(errInternal(err))
	}
	if ep != nil {
		if e := s.checkEpoch(ctx, tx, conv, ep, cv.latest); e != nil {
			return fail(e)
		}
		if items, err = insertEpoch(ctx, tx, s, conv, ep); err != nil {
			return fail(errInternal(err))
		}
	}
	if meta != nil {
		if err := saveMeta(ctx, tx, conv, meta); err != nil {
			return fail(errInternal(err))
		}
		wire = &meta.wire
	}
	if err := tx.Commit(ctx); err != nil {
		return fail(errInternal(err))
	}
	return st.N, items, wire, nil
}

// announceChange sends group_change to who was a member before or after record n, and the
// conversation to who entered with it. Also used for the records the CLI writes (NOTIFY).
func (s *Server) announceChange(ctx context.Context, conv proto.UUID, n uint64, meta *GroupMetaJSON) {
	recs, err := store.ListChanges(ctx, s.db, conv, n-1, 1)
	if err != nil || len(recs) != 1 || recs[0].N != n {
		if err != nil {
			s.log.Error("group_change", "err", err.Error())
		}
		return
	}
	rows, err := s.db.Query(ctx, `SELECT user_id, joined_n = $2 FROM conversation_members
		WHERE conversation_id = $1 AND joined_n <= $2 AND (left_n IS NULL OR left_n >= $2)`, conv, int64(n))
	if err != nil {
		s.log.Error("group_change", "err", err.Error())
		return
	}
	var all, added []proto.UUID
	for rows.Next() {
		var u proto.UUID
		var entered bool
		if err := rows.Scan(&u, &entered); err != nil {
			break
		}
		all = append(all, u)
		if entered {
			added = append(added, u)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		s.log.Error("group_change", "err", err.Error())
		return
	}
	if len(added) > 0 {
		c, _, err := s.loadConversation(ctx, s.db, conv)
		if err != nil {
			s.log.Error("group_change", "err", err.Error())
			return
		}
		s.hub.conversationCreated(c, added)
	}
	s.hub.groupChanged(conv, changeJSON(recs[0]), meta, all)
}

// ---- reads ----

// memberRoute parses {id} and requires the user to be a member; it returns the conversation kind.
func (s *Server) memberRoute(w http.ResponseWriter, r *http.Request, p *Principal) (conv proto.UUID, kind string, ok bool) {
	conv, ok = idOK(r.PathValue("id"))
	if !ok {
		s.writeAPIErr(w, errBad("id inválido"))
		return conv, "", false
	}
	ctx := r.Context()
	err := s.db.QueryRow(ctx, `SELECT kind FROM conversations WHERE id = $1`, conv).Scan(&kind)
	if errors.Is(err, pgx.ErrNoRows) {
		s.writeAPIErr(w, errNotFound("conversa inexistente"))
		return conv, "", false
	}
	var member bool
	if err == nil {
		member, err = s.isMember(ctx, s.db, conv, p.UserID)
	}
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return conv, "", false
	}
	if !member {
		s.writeAPIErr(w, errForbidden())
		return conv, "", false
	}
	return conv, kind, true
}

func (s *Server) groupRoute(w http.ResponseWriter, r *http.Request, p *Principal) (proto.UUID, bool) {
	conv, kind, ok := s.memberRoute(w, r, p)
	if ok && kind != "group" {
		s.writeAPIErr(w, errBad("a conversa não é um grupo"))
		return conv, false
	}
	return conv, ok
}

// queryAfter reads the optional ?after= cursor.
func queryAfter(r *http.Request) (uint64, bool) {
	v := r.URL.Query().Get("after")
	if v == "" {
		return 0, true
	}
	n, err := strconv.ParseUint(v, 10, 63)
	return n, err == nil
}

// GET /v1/groups/{id}/changes?after=&limit=
func (s *Server) handleListChanges(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, ok := s.groupRoute(w, r, p)
	if !ok {
		return
	}
	after, ok := queryAfter(r)
	limit := 500
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		ok = ok && err == nil && n >= 1
		limit = min(n, 500)
	}
	if !ok {
		s.writeAPIErr(w, errBad("after ou limit inválido"))
		return
	}
	rows, err := store.ListChanges(r.Context(), s.db, conv, after, limit+1)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	more := len(rows) > limit
	if more {
		rows = rows[:limit]
	}
	out := make([]ChangeJSON, len(rows))
	for i, c := range rows {
		out[i] = changeJSON(c)
	}
	writeJSON(w, 200, map[string]any{"changes": out, "has_more": more})
}

// GET /v1/groups/{id}/meta: the stored ciphertexts of the current meta_commit, newest epoch first.
func (s *Server) handleGroupMeta(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, ok := s.groupRoute(w, r, p)
	if !ok {
		return
	}
	ctx := r.Context()
	commit, err := store.CurrentMetaCommit(ctx, s.db, conv)
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	rows, err := s.db.Query(ctx, `SELECT epoch, nonce, ciphertext FROM group_meta
		WHERE conversation_id = $1 AND meta_commit = $2 ORDER BY epoch DESC LIMIT 20`, conv, commit[:])
	if err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	defer rows.Close()
	items := []GroupMetaJSON{}
	for rows.Next() {
		m := GroupMetaJSON{MetaCommit: proto.B64Encode(commit[:])}
		var nonce, ct []byte
		if err := rows.Scan(&m.Epoch, &nonce, &ct); err != nil {
			s.writeAPIErr(w, errInternal(err))
			return
		}
		m.Nonce, m.Ciphertext = proto.B64Encode(nonce), proto.B64Encode(ct)
		items = append(items, m)
	}
	if err := rows.Err(); err != nil {
		s.writeAPIErr(w, errInternal(err))
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

// ---- POST /v1/groups/{id}/history-wraps (G 5.4) ----

type historyItem struct {
	Epoch      uint32 `json:"epoch"`
	DeviceID   string `json:"device_id"`
	WrappedKey string `json:"wrapped_key"`
}

type historyReq struct {
	AddN  uint64        `json:"add_n"`
	Items []historyItem `json:"items"`
}

func (s *Server) handleHistoryWraps(w http.ResponseWriter, r *http.Request, p *Principal) {
	conv, ok := idOK(r.PathValue("id"))
	if !ok {
		s.writeAPIErr(w, errBad("id inválido"))
		return
	}
	var req historyReq
	if e := readBigJSON(w, r, &req); e != nil {
		s.writeAPIErr(w, e)
		return
	}
	if req.AddN < 1 || len(req.Items) == 0 || len(req.Items) > 2000 {
		s.writeAPIErr(w, errBad("campos inválidos"))
		return
	}
	if !s.epochDev.Allow(proto.FormatUUID(p.DeviceID)) {
		s.writeAPIErr(w, errRate())
		return
	}
	items, aerr := s.historyWraps(r.Context(), p, conv, &req)
	if aerr != nil {
		s.writeAPIErr(w, aerr)
		return
	}
	// A connection holds 64 frames: send only the last items of each device. Whoever gets one of an
	// old epoch fetches the rest with /v1/conversations/{id}/epochs/mine.
	sent := map[proto.UUID]int{}
	for i := len(items) - 1; i >= 0; i-- {
		it := items[i]
		if sent[it.device]++; sent[it.device] <= maxReleaseEvents {
			s.hub.epochCreated(conv, map[proto.UUID]EpochItem{it.device: it.item})
		}
	}
	writeJSON(w, 201, map[string]any{"accepted": len(items)})
}

const maxReleaseEvents = 16

type releasedWrap struct {
	device proto.UUID
	item   EpochItem
}

// historyWraps accepts only what the signed chain permits; one forbidden item rejects the request.
// Items already stored are skipped, so a retry is harmless.
func (s *Server) historyWraps(ctx context.Context, p *Principal, conv proto.UUID, req *historyReq) ([]releasedWrap, *apiError) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, errInternal(err)
	}
	defer tx.Rollback(ctx)
	cv, e := lockMember(ctx, tx, s, conv, p.UserID)
	if e != nil {
		return nil, e
	}
	if cv.kind != "group" {
		return nil, errBad("a conversa não é um grupo")
	}
	if cv.closed {
		return nil, errGroupClosed()
	}
	chain, err := store.LoadChain(ctx, tx, conv)
	if err != nil {
		return nil, errInternal(err)
	}
	st := chain.State
	if !st.IsAdmin(p.UserID) {
		return nil, errForbidden()
	}
	denied := errBad("a cadeia não permite este reembrulho")
	if req.AddN > uint64(len(chain.Rows)) {
		return nil, denied
	}
	add, err := proto.DecodeChange(chain.Rows[req.AddN-1].Bytes)
	if err != nil {
		return nil, errInternal(err)
	}
	body, err := proto.ParseBody(add.Kind, add.Body)
	if err != nil {
		return nil, errInternal(err)
	}
	if add.Kind != proto.KindAdd || !body.History {
		return nil, denied
	}
	target := map[proto.UUID]bool{}
	for _, u := range body.Users {
		target[u] = true
	}
	if err := store.LockWraps(ctx, tx); err != nil {
		return nil, errInternal(err)
	}
	var out []releasedWrap
	seen := map[string]bool{}
	for _, it := range req.Items {
		dev, ok := idOK(it.DeviceID)
		wk, err := proto.B64Fixed(it.WrappedKey, 80)
		key := it.DeviceID + "/" + strconv.FormatUint(uint64(it.Epoch), 10)
		if !ok || err != nil || it.Epoch < 1 || seen[key] {
			return nil, errBad("items inválido")
		}
		seen[key] = true
		var owner proto.UUID
		err = tx.QueryRow(ctx, `SELECT d.user_id FROM devices d JOIN users u ON u.id = d.user_id
			WHERE d.id = $1 AND d.revoked_at IS NULL AND d.expires_at > $2 AND u.disabled_at IS NULL`, dev, s.now()).Scan(&owner)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, denied
		}
		if err != nil {
			return nil, errInternal(err)
		}
		rows, err := tx.Query(ctx, itemSelectEpoch, conv, it.Epoch, dev)
		if err != nil {
			return nil, errInternal(err)
		}
		var ei EpochItem
		var creator proto.UUID
		var commit, recips, sig, chainHash []byte
		var chainN uint64
		var have, found bool
		for rows.Next() {
			if err := rows.Scan(&creator, &commit, &recips, &sig, &chainN, &chainHash, &have); err != nil {
				rows.Close()
				return nil, errInternal(err)
			}
			found = true
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, errInternal(err)
		}
		if !found || !target[owner] || chainN >= req.AddN || !st.MayRewrap(owner, chainN) {
			return nil, denied
		}
		if have {
			continue
		}
		id, err := store.InsertWrap(ctx, tx, conv, it.Epoch, dev, wk, store.WrapByHistory)
		if err != nil {
			return nil, errInternal(err)
		}
		ei = EpochItem{WrapID: id, ConversationID: proto.FormatUUID(conv), Epoch: it.Epoch,
			CreatorDeviceID: proto.FormatUUID(creator), KeyCommitment: proto.B64Encode(commit),
			Recipients: splitRecipients(recips), Signature: proto.B64Encode(sig), WrappedKey: it.WrappedKey,
			ChainN: chainN, ChainHash: proto.B64Encode(chainHash)}
		out = append(out, releasedWrap{device: dev, item: ei})
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, errInternal(err)
	}
	return out, nil
}

// itemSelectEpoch is one group epoch, and whether device $3 already has a wrap of it.
const itemSelectEpoch = `SELECT e.created_by_device, e.key_commitment, e.recipients, e.signature, e.chain_n, e.chain_hash,
		EXISTS (SELECT 1 FROM epoch_key_wraps w WHERE w.conversation_id = e.conversation_id AND w.epoch = e.epoch
			AND w.recipient_device_id = $3)
	FROM epochs e WHERE e.conversation_id = $1 AND e.epoch = $2 AND e.chain_n IS NOT NULL`
