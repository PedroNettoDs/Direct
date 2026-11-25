package main

// Group part of "escrow rewrap" (docs/protocolo-grupos.md 5.4): only what the signed chain
// permits. The 1:1 rule (a conversation as a whole) does not apply to groups.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

type epochRef struct {
	conv  proto.UUID
	epoch uint32
}

type groupPlan struct {
	conv   proto.UUID
	title  string
	why    []string // the records that authorize it, with the epochs each one covers
	epochs []store.EscrowEpoch
}

type groupsPlan struct {
	groups        []groupPlan
	have, outside int
	failed        []string
}

// planGroups finds the group epochs that may be wrapped for the device of user.
func planGroups(ctx context.Context, q store.DB, user, device proto.UUID, escrowPub []byte, names labels) (groupsPlan, error) {
	var p groupsPlan
	convs, err := store.GroupsOfUser(ctx, q, user)
	if err != nil {
		return p, err
	}
	for _, conv := range convs {
		reject := func(why string) {
			p.failed = append(p.failed, fmt.Sprintf("grupo %s: %s; nada dele é reembrulhado", proto.FormatUUID(conv), why))
		}
		chain, err := store.LoadChain(ctx, q, conv)
		if errors.Is(err, store.ErrBadChain) {
			reject(err.Error())
			continue
		}
		if err != nil {
			return p, err
		}
		st := chain.State
		epochs, err := store.ListGroupEpochs(ctx, q, conv, device)
		if err != nil {
			return p, err
		}
		// A chain cut short (to hide a removal) no longer holds the position of later epochs.
		cut := false
		for _, e := range epochs {
			h, ok := st.HashAt(e.ChainN)
			cut = cut || !ok || h != e.ChainHash
		}
		if cut {
			reject("há época que aponta para um registro que não está na cadeia")
			continue
		}
		if !st.IsMember(user) {
			for _, e := range epochs {
				if e.Done {
					p.have++
				} else {
					p.outside++
				}
			}
			continue
		}

		var devices []proto.UUID
		for _, e := range epochs {
			devices = append(devices, e.CreatorDevice)
			devices = append(devices, splitIDs(e.Recipients)...)
		}
		certs, err := store.LoadCerts(ctx, q, devices)
		if err != nil {
			return p, err
		}
		cert := func(d proto.UUID) (proto.Cert, bool) {
			sc, ok := certs[d]
			return sc.Cert, ok && proto.Verify(chain.Keys.ServerPub, proto.CertBytes(sc.Cert), sc.Sig)
		}

		g := groupPlan{conv: conv, title: "sem rótulo"}
		if st.AdminLabel != "" {
			g.title = clean(st.AdminLabel)
		}
		byRecord := map[uint64][]uint32{} // authorizing record -> epochs
		var order []uint64
		released := map[uint64]bool{} // authorized by the history release of that record
		var lastN uint64
		for _, e := range epochs {
			if e.Done {
				p.have++
				lastN = max(lastN, e.ChainN)
				continue
			}
			fail := func(why string) {
				p.failed = append(p.failed, fmt.Sprintf("grupo %s época %d: %s", proto.FormatUUID(conv), e.Epoch, why))
			}
			creator, ok := cert(e.CreatorDevice)
			if !ok {
				fail("certificado do criador não confere")
				continue
			}
			e.CreatorSignPub = creator.SignPub
			if !epochSigned(e.EscrowEpoch, escrowPub) {
				fail("assinatura do criador não confere")
				continue
			}
			var owners []proto.UUID
			for _, d := range splitIDs(e.Recipients) {
				c, ok := cert(d)
				if !ok {
					break
				}
				owners = append(owners, c.UserID)
			}
			if len(owners) != len(e.Recipients)/16 {
				fail("destinatário sem certificado válido")
				continue
			}
			if err := st.CheckGroupEpoch(e.ChainN, e.ChainHash, creator.UserID, owners); err != nil {
				fail("a época não confere com a cadeia: " + proto.CodeOf(err))
				continue
			}
			if e.ChainN < lastN {
				fail("a posição na cadeia diminuiu em relação à época anterior")
				continue
			}
			lastN = e.ChainN
			if !st.MayRewrap(user, e.ChainN) {
				p.outside++
				continue
			}
			from, history := authorizing(st, user, e.ChainN)
			key := 2 * from // member epochs and released epochs of one record are listed apart
			if history {
				key++
				released[key] = true
			}
			if byRecord[key] == nil {
				order = append(order, key)
			}
			byRecord[key] = append(byRecord[key], e.Epoch)
			g.epochs = append(g.epochs, e.EscrowEpoch)
		}
		slices.Sort(order)
		for _, key := range order {
			row := chain.Rows[key/2-1]
			c, err := proto.DecodeChange(row.Bytes)
			if err != nil {
				return p, err
			}
			day := row.ReceivedAt.Local().Format("02/01/2006")
			var line string
			if c.Kind == proto.KindCreate {
				line = fmt.Sprintf("membro desde a criação em %s, %s", day, names.author(c))
			} else {
				body, err := proto.ParseBody(c.Kind, c.Body)
				if err != nil {
					return p, err
				}
				history := "sem histórico"
				if body.History {
					history = "com histórico"
				}
				line = fmt.Sprintf("entrou em %s, adicionado %s, %s", day, names.author(c), history)
			}
			if released[key] {
				line += " (anteriores à entrada, liberadas)"
			}
			g.why = append(g.why, fmt.Sprintf("registro %d: %s: épocas %s", row.N, line, ranges(byRecord[key])))
		}
		if len(g.epochs) > 0 {
			p.groups = append(p.groups, g)
		}
	}
	return p, nil
}

// authorizing returns the record that lets user receive an epoch of chain position n, and whether
// it does so by releasing the history. Only valid when MayRewrap(user, n).
func authorizing(st *proto.GroupState, user proto.UUID, n uint64) (record uint64, history bool) {
	for _, iv := range st.Intervals[user] {
		if iv.From <= n && (iv.To == 0 || n < iv.To) {
			return iv.From, false
		}
	}
	for _, iv := range st.Intervals[user] {
		if iv.History && n < iv.From {
			return iv.From, true
		}
	}
	return 0, false
}

// ranges turns ascending epoch numbers into "1, 3 a 5".
func ranges(ns []uint32) string {
	var out []string
	for i := 0; i < len(ns); {
		j := i
		for j+1 < len(ns) && ns[j+1] == ns[j]+1 {
			j++
		}
		s := strconv.FormatUint(uint64(ns[i]), 10)
		if j > i {
			s += " a " + strconv.FormatUint(uint64(ns[j]), 10)
		}
		out = append(out, s)
		i = j + 1
	}
	return strings.Join(out, ", ")
}

func splitIDs(b []byte) []proto.UUID {
	out := make([]proto.UUID, 0, len(b)/16)
	for i := 0; i+16 <= len(b); i += 16 {
		out = append(out, proto.UUID(b[i:i+16]))
	}
	return out
}
