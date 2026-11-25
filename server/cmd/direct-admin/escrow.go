package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

// The escrow secret key and its password live only in memory while a command runs, and are
// cleared before it returns (best effort in Go). The database only ever gets the public key.

const minPassword = 16

// escrowInit writes the key file first and registers the public key only after it is on disk.
func (a *app) escrowInit(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("escrow init", flag.ContinueOnError)
	out := fs.String("out", "", "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if *out == "" {
		return fmt.Errorf("%w: falta --out", errUsage)
	}
	keys, err := store.GetKeys(ctx, a.pool)
	if errors.Is(err, store.ErrNotFound) {
		return errors.New("banco sem chave do servidor: suba o directd uma vez antes")
	}
	if err != nil {
		return err
	}
	if keys.EscrowPub != nil {
		return errors.New("escrow já configurado; a v1 não troca a chave")
	}

	pw, err := a.newPassword("Senha da chave escrow")
	if err != nil {
		return err
	}
	defer clear(pw)

	sk := make([]byte, 32)
	defer clear(sk)
	if _, err := rand.Read(sk); err != nil {
		return err
	}
	pub, err := curve25519.X25519(sk, curve25519.Basepoint)
	if err != nil {
		return err
	}
	file, err := proto.SealEscrow(sk, pw)
	if err != nil {
		return err
	}
	if err := writeNew(*out, file); err != nil {
		return err
	}
	ok, err := store.SetEscrowPub(ctx, a.pool, pub)
	if err != nil {
		// The commit may have happened: deleting the only copy of the key would be unrecoverable.
		return fmt.Errorf("falha ao registrar a chave pública (NÃO apague %s sem conferir server_keys): %w", *out, err)
	}
	if !ok {
		os.Remove(*out)
		return errors.New("escrow já configurado por outro comando; arquivo novo removido")
	}
	fmt.Fprintf(a.out, "Chave gravada em %s (faça uma segunda cópia offline).\nescrow_pub: %s\nCódigo de verificação: %s\n",
		*out, proto.B64Encode(pub), proto.ServerCode(keys.ServerSignPub, pub))
	return nil
}

// newPassword asks twice for the password of a new key file. The caller must clear it.
func (a *app) newPassword(what string) ([]byte, error) {
	pw, err := a.password(fmt.Sprintf("%s (mínimo %d caracteres): ", what, minPassword))
	if err != nil {
		return nil, err
	}
	if utf8.RuneCount(pw) < minPassword {
		clear(pw)
		return nil, fmt.Errorf("senha curta: use pelo menos %d caracteres", minPassword)
	}
	again, err := a.password("Repita a senha: ")
	if err != nil {
		clear(pw)
		return nil, err
	}
	defer clear(again)
	if !bytes.Equal(pw, again) {
		clear(pw)
		return nil, errors.New("as senhas não conferem")
	}
	return pw, nil
}

// writeNew creates the file (never overwrites), mode 0600, and flushes it to the device.
func writeNew(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(path)
		return err
	}
	if d, derr := os.Open(filepath.Dir(path)); derr == nil {
		_ = d.Sync() // not every filesystem on a USB stick supports it
		d.Close()
	}
	return nil
}

// openEscrow reads the key file, asks for the password and checks the key against the server's.
func (a *app) openEscrow(path string, escrowPub []byte) (*[32]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	file, err := io.ReadAll(io.LimitReader(f, proto.EscrowFileLen+1))
	f.Close()
	if err != nil {
		return nil, err
	}
	pw, err := a.password("Senha da chave escrow: ")
	if err != nil {
		return nil, err
	}
	defer clear(pw)
	sk, err := proto.OpenEscrow(file, pw)
	if err != nil {
		return nil, err
	}
	defer clear(sk)
	pub, err := curve25519.X25519(sk, curve25519.Basepoint)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(pub, escrowPub) {
		return nil, errors.New("esta chave não é a escrow deste servidor")
	}
	out := new([32]byte)
	copy(out[:], sk)
	return out, nil
}

// escrowRewrap gives an active device the epoch keys of its user's conversations (protocolo 13.3).
// The device's public keys and the memberships come from the database, which whoever controls the
// server can edit: the moderator confirms the device fingerprint out of band, only conversations with
// a signed epoch listing the user are eligible, and they are listed before anything is wrapped.
func (a *app) escrowRewrap(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("escrow rewrap", flag.ContinueOnError)
	devArg := fs.String("device", "", "")
	keyPath := fs.String("key", "", "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if *devArg == "" || *keyPath == "" {
		return fmt.Errorf("%w: faltam --device e --key", errUsage)
	}
	devID, err := parseID(*devArg)
	if err != nil {
		return err
	}
	keys, err := a.keys(ctx)
	if err != nil {
		return err
	}
	activeDevice := func(q store.DB) (store.Device, error) {
		d, err := store.GetDevice(ctx, q, devID)
		if errors.Is(err, store.ErrNotFound) {
			return d, errors.New("aparelho inexistente")
		}
		if err == nil && !d.Active(a.now()) {
			err = errors.New("aparelho revogado, vencido ou de usuário desativado")
		}
		return d, err
	}
	d, err := activeDevice(a.pool) // fail before asking for anything
	if err != nil {
		return err
	}
	code := proto.DeviceCode(d.SignPub, d.KexPub)
	fmt.Fprintf(a.out, "Aparelho de %s: %s, cadastrado em %s\nCódigo do aparelho: %s\n"+
		"Compare com o código em Ajustes no aparelho novo, pessoalmente ou por telefone.\n",
		clean(d.AdminLabel), clean(d.Model), stamp(d.EnrolledAt), code)
	if err := a.mustConfirm("O código é o mesmo? (sim/não): "); err != nil {
		return err
	}
	sk, err := a.openEscrow(*keyPath, keys.EscrowPub)
	if err != nil {
		return err
	}
	defer clear(sk[:])
	var escrowPub, kex [32]byte
	copy(escrowPub[:], keys.EscrowPub)
	copy(kex[:], d.KexPub) // the key the moderator confirmed

	signed := func(e store.EscrowEpoch) bool { return epochSigned(e, escrowPub[:]) }
	names, err := a.userLabels(ctx)
	if err != nil {
		return err
	}

	// Outside the transaction: LockWraps would stop every new epoch while the moderator reads.
	plan, err := store.PendingEscrowEpochs(ctx, a.pool, d.UserID, d.ID, signed)
	if err != nil {
		return err
	}
	groups, err := planGroups(ctx, a.pool, d.UserID, d.ID, escrowPub[:], names)
	if err != nil {
		return err
	}
	count := map[proto.UUID]int{}
	var convs []proto.UUID
	for _, e := range plan.Epochs {
		if count[e.ConversationID] == 0 {
			convs = append(convs, e.ConversationID)
		}
		count[e.ConversationID]++
	}
	fmt.Fprintf(a.out, "Épocas fora (conversa sem época assinada que inclua o usuário): %d\n", plan.Outside)
	if len(convs) > 0 {
		rows := make([][]string, 0, len(convs))
		for _, c := range convs {
			labels, err := store.OtherMemberLabels(ctx, a.pool, c, d.UserID)
			if err != nil {
				return err
			}
			rows = append(rows, []string{proto.FormatUUID(c), strings.Join(labels, ", "), strconv.Itoa(count[c])})
		}
		fmt.Fprintln(a.out, "Conversas a reembrulhar:")
		if err := a.table("CONVERSA|COM|ÉPOCAS", rows); err != nil {
			return err
		}
	}
	approved := map[epochRef]bool{}
	if len(groups.groups) > 0 {
		fmt.Fprintln(a.out, "Grupos a reembrulhar, com o registro assinado que autoriza:")
		for _, g := range groups.groups {
			fmt.Fprintf(a.out, "Grupo %s (%s)\n", proto.FormatUUID(g.conv), g.title)
			for _, why := range g.why {
				fmt.Fprintln(a.out, "  ", why)
			}
			for _, e := range g.epochs {
				approved[epochRef{g.conv, e.Epoch}] = true
			}
		}
	}
	if groups.outside > 0 {
		fmt.Fprintf(a.out, "Épocas de grupo fora (a cadeia não permite): %d\n", groups.outside)
	}
	for _, f := range groups.failed {
		fmt.Fprintln(a.out, "ATENÇÃO:", f)
	}
	if len(convs) > 0 || len(approved) > 0 {
		if err := a.mustConfirm("Reembrulhar? (sim/não): "); err != nil {
			return err
		}
	}

	var done, skipped int
	var failed []string
	err = a.inTx(ctx, func(q store.DB) error {
		if err := store.LockWraps(ctx, q); err != nil {
			return err
		}
		cur, err := activeDevice(q)
		if err != nil {
			return err
		}
		if !bytes.Equal(cur.SignPub, d.SignPub) || !bytes.Equal(cur.KexPub, d.KexPub) || cur.UserID != d.UserID {
			return errors.New("o aparelho mudou no banco depois da confirmação; nada foi gravado")
		}
		p, err := store.PendingEscrowEpochs(ctx, q, d.UserID, d.ID, signed)
		if err != nil {
			return err
		}
		skipped = p.Have
		for _, e := range p.Rejected {
			failed = append(failed, fmt.Sprintf("conversa %s época %d: assinatura do criador não confere", proto.FormatUUID(e.ConversationID), e.Epoch))
		}
		for _, e := range p.Epochs {
			if count[e.ConversationID] == 0 {
				continue // not in the list the moderator approved
			}
			wrapped, why := rewrapEpoch(e, &escrowPub, sk, &kex)
			if why != nil {
				failed = append(failed, fmt.Sprintf("conversa %s época %d: %v", proto.FormatUUID(e.ConversationID), e.Epoch, why))
				continue
			}
			if _, err := store.InsertWrap(ctx, q, e.ConversationID, e.Epoch, d.ID, wrapped, store.WrapByEscrow); err != nil {
				return err
			}
			done++
		}
		g, err := planGroups(ctx, q, d.UserID, d.ID, escrowPub[:], names)
		if err != nil {
			return err
		}
		skipped += g.have
		failed = append(failed, g.failed...)
		for _, gp := range g.groups {
			for _, e := range gp.epochs {
				if !approved[epochRef{gp.conv, e.Epoch}] {
					continue
				}
				wrapped, why := rewrapEpoch(e, &escrowPub, sk, &kex)
				if why != nil {
					failed = append(failed, fmt.Sprintf("grupo %s época %d: %v", proto.FormatUUID(gp.conv), e.Epoch, why))
					continue
				}
				if _, err := store.InsertWrap(ctx, q, gp.conv, e.Epoch, d.ID, wrapped, store.WrapByEscrow); err != nil {
					return err
				}
				done++
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Épocas reembrulhadas: %d\nPuladas (o aparelho já tinha): %d\nCom falha: %d\n", done, skipped, len(failed))
	for _, f := range failed {
		fmt.Fprintln(a.out, " ", f)
	}
	a.note = fmt.Sprintf("device_code=%q rewrapped=%d skipped=%d outside=%d failed=%d", code, done, skipped,
		plan.Outside+groups.outside, len(failed))
	if done > 0 {
		fmt.Fprintln(a.out, "O app recebe as chaves ao abrir ou reconectar.")
	}
	return nil
}

// mustConfirm aborts unless the moderator types "sim".
func (a *app) mustConfirm(prompt string) error {
	ans, err := a.ask(prompt)
	if err != nil {
		return err
	}
	if !strings.EqualFold(strings.TrimSpace(ans), "sim") {
		return errors.New("não confirmado; nada foi gravado")
	}
	return nil
}

// rewrapEpoch opens the escrow wrap, checks it against the creator's signed statement and seals
// the epoch key for the device.
func rewrapEpoch(e store.EscrowEpoch, escrowPub, sk, kex *[32]byte) ([]byte, error) {
	k, ok := box.OpenAnonymous(nil, e.EscrowWrap, escrowPub, sk)
	defer clear(k)
	if !ok || len(k) != 32 {
		return nil, errors.New("embrulho de escrow não abre")
	}
	commit := proto.EpochKeyCommitment(e.ConversationID, e.Epoch, k)
	if subtle.ConstantTimeCompare(commit[:], e.Commitment) != 1 {
		return nil, errors.New("compromisso da chave não confere")
	}
	if !epochSigned(e, escrowPub[:]) {
		return nil, errors.New("assinatura do criador não confere")
	}
	return box.SealAnonymous(nil, k, kex, rand.Reader)
}

// epochSigned checks the creator's signature over the epoch statement, recipients included.
func epochSigned(e store.EscrowEpoch, escrowPub []byte) bool {
	recips := splitIDs(e.Recipients)
	signed := proto.EpochBytes(e.ConversationID, e.Epoch, e.CreatorDevice, e.Commitment, escrowPub, recips)
	if e.ChainN > 0 {
		signed = proto.GroupEpochBytes(e.ConversationID, e.Epoch, e.CreatorDevice, e.Commitment, escrowPub, e.ChainN, e.ChainHash, recips)
	}
	return proto.Verify(e.CreatorSignPub, signed, e.Signature)
}
