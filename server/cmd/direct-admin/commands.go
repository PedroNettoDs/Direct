package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

// ---- formatting ----

// clean keeps client-supplied text (model, display name...) from driving the moderator's terminal.
func clean(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return '?'
		}
		return r
	}, s)
}

func stamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

func stampOpt(t *time.Time) string {
	if t == nil {
		return "-"
	}
	return stamp(*t)
}

func (a *app) table(header string, rows [][]string) error {
	w := tabwriter.NewWriter(a.out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, strings.ReplaceAll(header, "|", "\t"))
	for _, r := range rows {
		for i := range r {
			r[i] = clean(r[i])
		}
		fmt.Fprintln(w, strings.Join(r, "\t"))
	}
	return w.Flush()
}

// parseDuration accepts Go durations plus whole days ("180d").
func parseDuration(s string) (time.Duration, error) {
	var d time.Duration
	var err error
	if days, ok := strings.CutSuffix(s, "d"); ok {
		var n int
		n, err = strconv.Atoi(days)
		if n > 36500 {
			n = 0
		}
		d = time.Duration(n) * 24 * time.Hour
	} else {
		d, err = time.ParseDuration(s)
	}
	if err != nil || d < time.Second {
		return 0, fmt.Errorf("prazo inválido: %q (exemplos: 30m, 24h, 180d)", s)
	}
	return d, nil
}

func newUUID() (proto.UUID, error) {
	var u proto.UUID
	_, err := rand.Read(u[:])
	u[6], u[8] = u[6]&0x0f|0x40, u[8]&0x3f|0x80
	return u, err
}

// keys returns the server keys, requiring the escrow key to be registered.
func (a *app) keys(ctx context.Context) (store.Keys, error) {
	k, err := store.GetKeys(ctx, a.pool)
	if errors.Is(err, store.ErrNotFound) {
		return k, errors.New("banco sem chave do servidor: suba o directd uma vez antes")
	}
	if err == nil && k.EscrowPub == nil {
		err = errors.New("escrow não configurado: rode \"direct-admin escrow init\" antes")
	}
	return k, err
}

func (a *app) user(ctx context.Context, id proto.UUID) (store.User, error) {
	u, err := store.GetUser(ctx, a.pool, id, a.now())
	if errors.Is(err, store.ErrNotFound) {
		return u, errors.New("usuário inexistente")
	}
	return u, err
}

// ---- tokens ----

// maxInviteTTL limits how long a leaked QR stays usable.
const maxInviteTTL = 7 * 24 * time.Hour

func (a *app) tokenCreate(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("token create", flag.ContinueOnError)
	newUser := fs.String("new-user", "", "")
	userID := fs.String("user", "", "")
	ttlArg := fs.String("ttl", "24h", "")
	devArg := fs.String("device-ttl", "180d", "")
	host := fs.String("host", a.host, "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if (*newUser == "") == (*userID == "") {
		return fmt.Errorf("%w: use --new-user ou --user (um dos dois)", errUsage)
	}
	ttl, err := parseDuration(*ttlArg)
	if err != nil {
		return err
	}
	if ttl > maxInviteTTL {
		return fmt.Errorf("prazo do convite acima de 7 dias: %q", *ttlArg)
	}
	devTTL, err := parseDuration(*devArg)
	if err != nil {
		return err
	}
	if !proto.ValidHost(*host) {
		return fmt.Errorf("domínio público inválido %q: use --host ou DIRECT_PUBLIC_HOST (minúsculas, sem porta)", *host)
	}
	keys, err := a.keys(ctx)
	if err != nil {
		return err
	}
	t := &store.Token{AdminLabel: *newUser, ExpiresAt: a.now().Add(ttl), DeviceTTL: devTTL}
	if *userID != "" {
		id, err := parseID(*userID)
		if err != nil {
			return err
		}
		u, err := a.user(ctx, id)
		if err != nil {
			return err
		}
		if u.DisabledAt != nil {
			return errors.New("usuário desativado")
		}
		t.UserID, t.AdminLabel = &id, u.AdminLabel
	} else if !proto.ValidAdminLabel(t.AdminLabel) {
		return errors.New("rótulo inválido: 1 a 100 bytes, sem caracteres de controle")
	}
	if t.ID, err = newUUID(); err != nil {
		return err
	}
	seed := make([]byte, ed25519.SeedSize) // goes only to the QR, never to the database
	if _, err := rand.Read(seed); err != nil {
		return err
	}
	defer clear(seed)
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	// With the moderator key registered the QR is v=2 and the typed code covers it (protocolo-grupos 3).
	uri := proto.InviteURI(*host, seed, keys.ServerSignPub, keys.EscrowPub)
	code := proto.ServerCode(keys.ServerSignPub, keys.EscrowPub)
	if keys.ModPub != nil {
		uri = proto.InviteURIMod(*host, seed, keys.ServerSignPub, keys.EscrowPub, keys.ModPub)
		code = proto.ServerCodeMod(keys.ServerSignPub, keys.EscrowPub, keys.ModPub)
	}
	qrText, err := renderQR(uri)
	if err != nil {
		return err
	}
	if err := store.InsertToken(ctx, a.pool, t, pub); err != nil {
		return err
	}
	a.note = "token=" + proto.FormatUUID(t.ID)

	fmt.Fprintf(a.out, `Convite %s
Usuário: %s
Vale até: %s (uso único)
Aparelho vale por: %s

%s
%s

Entrada manual:
  domínio: %s
  token:   %s
  código:  %s
`, proto.FormatUUID(t.ID), clean(t.AdminLabel), stamp(t.ExpiresAt), *devArg, qrText, uri,
		*host, proto.B64Encode(seed), code)
	return nil
}

func (a *app) tokenList(ctx context.Context, args []string) error {
	if _, err := parse(flag.NewFlagSet("token list", flag.ContinueOnError), args, 0); err != nil {
		return err
	}
	toks, err := store.ListTokens(ctx, a.pool)
	if err != nil {
		return err
	}
	var rows [][]string
	for _, t := range toks {
		state, user, dev := "pendente", "(novo)", "-"
		if t.RevokedAt != nil {
			state = "revogado"
		} else if t.UsedAt != nil {
			state = "usado"
		} else if !t.ExpiresAt.After(a.now()) {
			state = "vencido"
		}
		if t.UserID != nil {
			user = proto.FormatUUID(*t.UserID)
		}
		if t.UsedByDevice != nil {
			dev = proto.FormatUUID(*t.UsedByDevice)
		}
		rows = append(rows, []string{proto.FormatUUID(t.ID), state, stamp(t.ExpiresAt), user, t.AdminLabel, dev})
	}
	return a.table("ID|ESTADO|VALE ATÉ|USUÁRIO|RÓTULO|APARELHO", rows)
}

func (a *app) tokenRevoke(ctx context.Context, args []string) error {
	id, err := oneID("token revoke", args)
	if err != nil {
		return err
	}
	ok, err := store.RevokeUnusedToken(ctx, a.pool, id, a.now())
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("convite inexistente ou já usado (neste caso, revogue o aparelho)")
	}
	fmt.Fprintln(a.out, "Convite revogado.")
	return nil
}

// tokenReactivate reopens the same invite for a new enrollment of the same user (protocolo-grupos 9).
// The server never had the invite seed, so only the original QR works.
func (a *app) tokenReactivate(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("token reactivate", flag.ContinueOnError)
	ttlArg := fs.String("ttl", "", "")
	pos, err := parse(fs, args, 1)
	if err != nil {
		return err
	}
	id, err := parseID(pos[0])
	if err != nil {
		return err
	}
	if *ttlArg == "" {
		return fmt.Errorf("%w: falta --ttl", errUsage)
	}
	ttl, err := parseDuration(*ttlArg)
	if err != nil {
		return err
	}
	if ttl < time.Minute || ttl > maxInviteTTL {
		return fmt.Errorf("prazo fora de 1 minuto a 7 dias: %q", *ttlArg)
	}
	now := a.now()
	expires := now.Add(ttl)
	var u store.User
	err = a.inTx(ctx, func(q store.DB) error {
		var user, device *proto.UUID
		var used, revoked *time.Time
		var exp time.Time
		err := q.QueryRow(ctx, `SELECT user_id, used_by_device, used_at, revoked_at, expires_at
			FROM enrollment_tokens WHERE id = $1 FOR UPDATE`, id).Scan(&user, &device, &used, &revoked, &exp)
		if errors.Is(err, pgx.ErrNoRows) {
			return errors.New("convite inexistente")
		}
		if err != nil {
			return err
		}
		switch {
		case revoked != nil:
			return errors.New("convite revogado; crie outro")
		case used == nil && exp.After(now):
			return errors.New("convite ainda não usado nem vencido")
		}
		// A "new user" invite now points to the user it created: reactivating never creates one.
		if user == nil && device != nil {
			if err := q.QueryRow(ctx, `SELECT user_id FROM devices WHERE id = $1`, *device).Scan(&user); err != nil {
				return err
			}
		}
		if user == nil {
			return errors.New("convite de usuário novo que nunca foi usado; crie outro com token create")
		}
		if u, err = store.GetUser(ctx, q, *user, now); err != nil {
			return err
		}
		if u.DisabledAt != nil {
			return errors.New("usuário desativado")
		}
		_, err = q.Exec(ctx, `UPDATE enrollment_tokens SET used_at = NULL, used_by_device = NULL, user_id = $2,
			expires_at = $3, reactivated_at = $4, reactivations = reactivations + 1 WHERE id = $1`, id, *user, expires, now)
		return err
	})
	if err != nil {
		return err
	}
	a.note = fmt.Sprintf("token=%s user=%s ttl=%s", proto.FormatUUID(id), proto.FormatUUID(u.ID), ttl)
	fmt.Fprintf(a.out, `Convite %s reaberto para %s
Vale até: %s (uso único)

O servidor não guarda o segredo do convite: não há como reimprimir o QR. Só funciona se a pessoa
ainda tem o QR original. Se ele se perdeu ou pode ter sido visto por outra pessoa, use
"token create --user %s" no lugar.
`, proto.FormatUUID(id), clean(u.AdminLabel), stamp(expires), proto.FormatUUID(u.ID))
	return nil
}

// ---- users ----

func userState(u store.User) string {
	if u.DisabledAt != nil {
		return "desativado"
	}
	return "ativo"
}

func (a *app) userList(ctx context.Context, args []string) error {
	if _, err := parse(flag.NewFlagSet("user list", flag.ContinueOnError), args, 0); err != nil {
		return err
	}
	users, err := store.ListUsers(ctx, a.pool, a.now())
	if err != nil {
		return err
	}
	var rows [][]string
	for _, u := range users {
		rows = append(rows, []string{proto.FormatUUID(u.ID), u.AdminLabel, u.DisplayName, userState(u), strconv.Itoa(u.ActiveDevices)})
	}
	return a.table("ID|RÓTULO|NOME|ESTADO|APARELHOS ATIVOS", rows)
}

func (a *app) userShow(ctx context.Context, args []string) error {
	id, err := oneID("user show", args)
	if err != nil {
		return err
	}
	u, err := a.user(ctx, id)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "ID: %s\nRótulo: %s\nNome: %s\nStatus: %s\nCriado em: %s\nDesativado em: %s\nAparelhos ativos: %d\n\n",
		proto.FormatUUID(u.ID), clean(u.AdminLabel), clean(u.DisplayName), clean(u.Status), stamp(u.CreatedAt),
		stampOpt(u.DisabledAt), u.ActiveDevices)
	return a.devices(ctx, &id)
}

func (a *app) userDisable(ctx context.Context, args []string) error {
	id, err := oneID("user disable", args)
	if err != nil {
		return err
	}
	var n int
	err = a.inTx(ctx, func(q store.DB) (err error) {
		n, err = store.DisableUser(ctx, q, id, a.now())
		return err
	})
	if errors.Is(err, store.ErrNotFound) {
		return errors.New("usuário inexistente")
	}
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Usuário desativado; %d aparelho(s) revogado(s).\n", n)
	return nil
}

// ---- devices ----

func (a *app) devices(ctx context.Context, user *proto.UUID) error {
	devs, err := store.ListDevices(ctx, a.pool, user)
	if err != nil {
		return err
	}
	var rows [][]string
	for _, d := range devs {
		state := "ativo"
		switch {
		case d.RevokedAt != nil:
			state = "revogado"
		case d.UserDisabled:
			state = "usuário desativado"
		case !d.Active(a.now()):
			state = "vencido"
		}
		rows = append(rows, []string{proto.FormatUUID(d.ID), d.AdminLabel, proto.FormatUUID(d.UserID), d.Platform, d.Model,
			d.OSVersion, d.AppVersion, state, stamp(d.EnrolledAt), stampOpt(d.LastSeenAt), stamp(d.ExpiresAt)})
	}
	return a.table("ID|RÓTULO|USUÁRIO|PLATAFORMA|MODELO|SO|APP|ESTADO|CADASTRO|ÚLTIMO ACESSO|VENCE", rows)
}

func (a *app) deviceList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("device list", flag.ContinueOnError)
	userArg := fs.String("user", "", "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if *userArg == "" {
		return a.devices(ctx, nil)
	}
	id, err := parseID(*userArg)
	if err != nil {
		return err
	}
	if _, err := a.user(ctx, id); err != nil {
		return err
	}
	return a.devices(ctx, &id)
}

func (a *app) deviceRevoke(ctx context.Context, args []string) error {
	id, err := oneID("device revoke", args)
	if err != nil {
		return err
	}
	err = a.inTx(ctx, func(q store.DB) error { return store.RevokeDevice(ctx, q, id, store.RevokedByAdmin, a.now()) })
	if errors.Is(err, store.ErrNotFound) {
		return errors.New("aparelho inexistente")
	}
	if err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Aparelho revogado.")
	return nil
}

// ---- saved media ----

func (a *app) mediaSaves(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("media saves", flag.ContinueOnError)
	userArg := fs.String("user", "", "")
	limit := fs.Int("limit", 100, "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	f := store.SaveFilter{Limit: *limit}
	if *userArg != "" {
		id, err := parseID(*userArg)
		if err != nil {
			return err
		}
		f.UserID = &id
	}
	saves, err := store.ListMediaSaves(ctx, a.pool, f)
	if err != nil {
		return err
	}
	var rows [][]string
	for _, s := range saves {
		rows = append(rows, []string{proto.FormatUUID(s.SaveID), stamp(s.SavedAt), s.AdminLabel, proto.FormatUUID(s.UserID),
			proto.FormatUUID(s.DeviceID), s.SenderLabel, proto.FormatUUID(s.ConversationID), strconv.FormatUint(s.Seq, 10)})
	}
	return a.table("SAVE_ID|SALVO EM|QUEM SALVOU|USUÁRIO|APARELHO|REMETENTE|CONVERSA|SEQ", rows)
}

func (a *app) mediaLookup(ctx context.Context, args []string) error {
	id, err := oneID("media lookup", args)
	if err != nil {
		return err
	}
	s, err := store.GetMediaSave(ctx, a.pool, id)
	if errors.Is(err, store.ErrNotFound) {
		return errors.New("save_id não registrado neste servidor")
	}
	if err != nil {
		return err
	}
	d, err := store.GetDevice(ctx, a.pool, s.DeviceID)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, `save_id:  %s
Salvo em: %s
Quem salvou: %s (usuário %s)
Aparelho: %s (%s %s)
Mensagem: conversa %s, seq %d, message_id %s
Enviada por: %s (usuário %s, aparelho %s) em %s (relógio do remetente)
`, proto.FormatUUID(s.SaveID), stamp(s.SavedAt), clean(s.AdminLabel), proto.FormatUUID(s.UserID),
		proto.FormatUUID(s.DeviceID), d.Platform, clean(d.Model),
		proto.FormatUUID(s.ConversationID), s.Seq, proto.FormatUUID(s.MessageID),
		clean(s.SenderLabel), proto.FormatUUID(s.SenderUserID), proto.FormatUUID(s.SenderDeviceID),
		stamp(time.UnixMilli(int64(s.SentAt))))
	return nil
}

// mediaPrune deletes uploads that no message can refer to (store.PruneOrphanBlobs).
func (a *app) mediaPrune(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("media prune", flag.ContinueOnError)
	older := fs.String("older", "30d", "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	age, err := parseDuration(*older)
	if err != nil {
		return err
	}
	if age < 24*time.Hour {
		return errors.New("--older mínimo é 24h: o envio pode estar em andamento")
	}
	n, size, err := store.PruneOrphanBlobs(ctx, a.pool, a.now().Add(-age))
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Anexos órfãos apagados: %d (%d bytes)\n", n, size)
	a.note = fmt.Sprintf("pruned=%d bytes=%d", n, size)
	return nil
}
