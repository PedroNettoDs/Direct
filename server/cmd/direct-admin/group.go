package main

// Group commands (docs/protocolo-grupos.md 3.5 and 10.4). Whatever changes a group is a record
// signed with the moderator key, read from the pendrive and cleared right after signing.

import (
	"context"
	"crypto/ed25519"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

// modKeys returns the server keys, requiring the moderator key to be registered.
func (a *app) modKeys(ctx context.Context) (store.Keys, error) {
	k, err := store.GetKeys(ctx, a.pool)
	if errors.Is(err, store.ErrNotFound) {
		return k, errors.New("banco sem chave do servidor: suba o directd uma vez antes")
	}
	if err == nil && k.ModPub == nil {
		err = errors.New("chave do moderador não registrada: rode \"direct-admin moderator register\" antes")
	}
	return k, err
}

// openModKey reads the key file, asks for the password and checks the key against the registered
// one. The caller must clear the returned private key.
func (a *app) openModKey(path string, modPub []byte) (ed25519.PrivateKey, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	file, err := io.ReadAll(io.LimitReader(f, proto.EscrowFileLen+1))
	f.Close()
	if err != nil {
		return nil, err
	}
	pw, err := a.password("Senha da chave do moderador: ")
	if err != nil {
		return nil, err
	}
	defer clear(pw)
	seed, err := proto.OpenModKey(file, pw)
	if err != nil {
		return nil, err
	}
	defer clear(seed)
	priv := ed25519.NewKeyFromSeed(seed)
	if !priv.Public().(ed25519.PublicKey).Equal(ed25519.PublicKey(modPub)) {
		clear(priv)
		return nil, errors.New("esta chave não é a do moderador deste servidor")
	}
	return priv, nil
}

var chainWhy = map[string]string{
	proto.ChainTarget: "o usuário não é membro do grupo",
	proto.ChainClosed: "o grupo já está encerrado",
	proto.ChainLimit:  "o grupo passaria de 100 membros",
	proto.ChainRole:   "o grupo precisa de ao menos um admin",
}

func chainError(err error) error {
	if why := chainWhy[proto.CodeOf(err)]; why != "" {
		return errors.New(why)
	}
	return err
}

func notifyGroup(ctx context.Context, q store.DB, conv proto.UUID, n uint64) error {
	_, err := q.Exec(ctx, `SELECT pg_notify('group_change', $1)`, proto.FormatUUID(conv)+" "+strconv.FormatUint(n, 10))
	return err
}

type idList []proto.UUID

func (l *idList) add(s string) error {
	id, err := parseID(s)
	*l = append(*l, id)
	return err
}

func (a *app) groupCreate(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("group create", flag.ContinueOnError)
	label := fs.String("label", "", "")
	keyPath := fs.String("mod-key", "", "")
	var admins, others idList
	fs.Func("admin", "", admins.add)
	fs.Func("member", "", others.add)
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if *keyPath == "" || len(admins) == 0 {
		return fmt.Errorf("%w: faltam --admin e --mod-key", errUsage)
	}
	if !proto.ValidAdminLabel(*label) {
		return errors.New("rótulo inválido: 1 a 100 bytes, sem caracteres de controle")
	}
	var members []proto.GroupMember
	var users []proto.UUID
	for i, u := range slices.Concat(admins, others) {
		if slices.Contains(users, u) {
			return fmt.Errorf("usuário repetido: %s", proto.FormatUUID(u))
		}
		role := proto.RoleMember
		if i < len(admins) {
			role = proto.RoleAdmin
		}
		users = append(users, u)
		members = append(members, proto.GroupMember{User: u, Role: role})
	}
	if len(members) > proto.GroupMaxMembers {
		return errors.New("um grupo tem no máximo 100 membros")
	}
	slices.SortFunc(members, func(x, y proto.GroupMember) int { return slices.Compare(x.User[:], y.User[:]) })
	for _, u := range users {
		got, err := a.user(ctx, u)
		if err != nil {
			return fmt.Errorf("%s: %w", proto.FormatUUID(u), err)
		}
		if got.DisabledAt != nil {
			return fmt.Errorf("%s: usuário desativado", proto.FormatUUID(u))
		}
	}
	keys, err := a.modKeys(ctx)
	if err != nil {
		return err
	}
	priv, err := a.openModKey(*keyPath, keys.ModPub)
	if err != nil {
		return err
	}
	conv, err := newUUID()
	if err != nil {
		clear(priv)
		return err
	}
	rec := proto.SignChange(proto.GroupChange{Conv: conv, N: 1, Kind: proto.KindCreate, AuthorType: proto.AuthorModerator,
		CreatedAt: uint64(a.now().UnixMilli()), Body: proto.CreateBody(*label, [32]byte{}, members)}, priv)
	clear(priv)

	err = a.inTx(ctx, func(q store.DB) error {
		now := a.now()
		free, err := store.InsertGroup(ctx, q, conv, now)
		if err != nil || !free {
			return errors.Join(err, errors.New("não foi possível criar o grupo"))
		}
		ok, err := store.UsersEnabled(ctx, q, users)
		if err != nil || !ok {
			return errors.Join(err, errors.New("algum usuário foi desativado agora; nada foi gravado"))
		}
		chainKeys, err := store.ChainKeys(ctx, q, nil)
		if err != nil {
			return err
		}
		st := proto.NewGroupState(conv)
		if err := st.Apply(rec, chainKeys); err != nil {
			return chainError(err)
		}
		if err := store.AppendChange(ctx, q, rec, st, now); err != nil {
			return err
		}
		return notifyGroup(ctx, q, conv, 1)
	})
	if err != nil {
		return err
	}
	a.note = "group=" + proto.FormatUUID(conv)
	fmt.Fprintf(a.out, "Grupo criado: %s\nRótulo: %s\nMembros: %d (%d admin)\n"+
		"A primeira chave é criada pelo primeiro membro que enviar mensagem.\n",
		proto.FormatUUID(conv), clean(*label), len(members), len(admins))
	return nil
}

func (a *app) groupRemoveMember(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("group remove-member", flag.ContinueOnError)
	keyPath := fs.String("mod-key", "", "")
	pos, err := parse(fs, args, 2)
	if err != nil {
		return err
	}
	conv, err := parseID(pos[0])
	if err != nil {
		return err
	}
	user, err := parseID(pos[1])
	if err != nil {
		return err
	}
	st, err := a.moderatorChange(ctx, conv, *keyPath, proto.KindRemove, proto.UsersBody([]proto.UUID{user}))
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Membro removido; restam %d. O próximo envio no grupo cria uma chave nova sem ele.\n", len(st.Members))
	hasAdmin := false
	for _, role := range st.Members {
		hasAdmin = hasAdmin || role == proto.RoleAdmin
	}
	switch {
	case st.ClosedAt != 0:
		fmt.Fprintln(a.out, "O grupo ficou sem membros e está encerrado.")
	case !hasAdmin:
		fmt.Fprintln(a.out, "AVISO: o grupo ficou sem admin. Ninguém mais pode adicionar membros; encerre e crie outro.")
	}
	return nil
}

func (a *app) groupClose(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("group close", flag.ContinueOnError)
	keyPath := fs.String("mod-key", "", "")
	pos, err := parse(fs, args, 1)
	if err != nil {
		return err
	}
	conv, err := parseID(pos[0])
	if err != nil {
		return err
	}
	if _, err := a.moderatorChange(ctx, conv, *keyPath, proto.KindClose, nil); err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Grupo encerrado.")
	return nil
}

// moderatorChange signs and stores one record on top of the verified chain of the group.
func (a *app) moderatorChange(ctx context.Context, conv proto.UUID, keyPath string, kind uint32, body []byte) (*proto.GroupState, error) {
	if keyPath == "" {
		return nil, fmt.Errorf("%w: falta --mod-key", errUsage)
	}
	keys, err := a.modKeys(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.isGroup(ctx, conv); err != nil {
		return nil, err
	}
	// Open the key before locking the group: the password is typed at human speed.
	priv, err := a.openModKey(keyPath, keys.ModPub)
	if err != nil {
		return nil, err
	}
	defer clear(priv)
	var st *proto.GroupState
	err = a.inTx(ctx, func(q store.DB) error {
		if _, err := q.Exec(ctx, `SELECT 1 FROM conversations WHERE id = $1 FOR UPDATE`, conv); err != nil {
			return err
		}
		chain, err := store.LoadChain(ctx, q, conv)
		if err != nil {
			return fmt.Errorf("não assino: %w", err)
		}
		st = chain.State
		rec := proto.SignChange(proto.GroupChange{Conv: conv, N: st.N + 1, Prev: st.Head, Kind: kind,
			AuthorType: proto.AuthorModerator, CreatedAt: uint64(a.now().UnixMilli()), Body: body}, priv)
		if err := st.Apply(rec, chain.Keys); err != nil {
			return chainError(err)
		}
		if err := store.AppendChange(ctx, q, rec, st, a.now()); err != nil {
			return err
		}
		return notifyGroup(ctx, q, conv, st.N)
	})
	if err != nil {
		return nil, err
	}
	a.note = fmt.Sprintf("group=%s n=%d", proto.FormatUUID(conv), st.N)
	return st, nil
}

func (a *app) isGroup(ctx context.Context, conv proto.UUID) error {
	var ok bool
	if err := a.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM conversations WHERE id = $1 AND kind = 'group')`, conv).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return errors.New("grupo inexistente")
	}
	return nil
}

func (a *app) groupList(ctx context.Context, args []string) error {
	if _, err := parse(flag.NewFlagSet("group list", flag.ContinueOnError), args, 0); err != nil {
		return err
	}
	rows, err := a.pool.Query(ctx, `SELECT c.id, COALESCE(c.admin_label, '-'), c.created_at, c.closed_at, c.chain_n,
			count(m.user_id), COALESCE(string_agg(u.admin_label, ', ' ORDER BY u.admin_label) FILTER (WHERE m.role = 'admin'), '-')
		FROM conversations c
		LEFT JOIN conversation_members m ON m.conversation_id = c.id AND m.left_at IS NULL
		LEFT JOIN users u ON u.id = m.user_id
		WHERE c.kind = 'group' GROUP BY c.id ORDER BY c.created_at, c.id`)
	if err != nil {
		return err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) ([]string, error) {
		var id proto.UUID
		var label, admins string
		var created time.Time
		var closed *time.Time
		var n, members int
		if err := r.Scan(&id, &label, &created, &closed, &n, &members, &admins); err != nil {
			return nil, err
		}
		return []string{proto.FormatUUID(id), label, strconv.Itoa(members), admins, stamp(created), stampOpt(closed), strconv.Itoa(n)}, nil
	})
	if err != nil {
		return err
	}
	return a.table("ID|RÓTULO|MEMBROS|ADMINS|CRIADO EM|ENCERRADO EM|REGISTROS", out)
}

// labels maps user ids to their administrative labels, ready for the terminal.
type labels map[proto.UUID]string

func (a *app) userLabels(ctx context.Context) (labels, error) {
	users, err := store.ListUsers(ctx, a.pool, a.now())
	if err != nil {
		return nil, err
	}
	out := labels{}
	for _, u := range users {
		out[u.ID] = clean(u.AdminLabel)
	}
	return out, nil
}

func (l labels) name(u proto.UUID) string {
	if s := l[u]; s != "" {
		return s
	}
	return proto.FormatUUID(u)
}

func (l labels) author(c proto.GroupChange) string {
	if c.AuthorType == proto.AuthorModerator {
		return "pelo moderador"
	}
	return fmt.Sprintf("por %s (aparelho %s)", l.name(c.AuthorUser), proto.FormatUUID(c.AuthorDevice))
}

// describe is one verified record as text.
func (l labels) describe(c proto.GroupChange) string {
	b, err := proto.ParseBody(c.Kind, c.Body)
	if err != nil {
		return "registro ilegível"
	}
	names := make([]string, len(b.Users))
	for i, u := range b.Users {
		names[i] = l.name(u)
	}
	targets := strings.Join(names, ", ")
	var what string
	switch c.Kind {
	case proto.KindCreate:
		ms := make([]string, len(b.Members))
		for i, m := range b.Members {
			ms[i] = l.name(m.User)
			if m.Role == proto.RoleAdmin {
				ms[i] += " (admin)"
			}
		}
		what = "criar · " + strings.Join(ms, ", ")
	case proto.KindAdd:
		what = "adicionar · " + targets
		if b.History {
			what += " com acesso ao histórico"
		}
	case proto.KindRemove:
		what = "remover · " + targets
	case proto.KindPromote:
		what = "promover · " + targets
	case proto.KindLeave:
		what = "sair · " + l.name(c.AuthorUser)
	case proto.KindRename:
		what = "renomear"
	case proto.KindClose:
		what = "encerrar"
	}
	return what + " " + l.author(c)
}

func (a *app) groupShow(ctx context.Context, args []string) error {
	conv, err := oneID("group show", args)
	if err != nil {
		return err
	}
	if err := a.isGroup(ctx, conv); err != nil {
		return err
	}
	var closed *time.Time
	var headN uint64
	var head []byte
	if err := a.pool.QueryRow(ctx, `SELECT closed_at, chain_n, chain_hash FROM conversations WHERE id = $1`, conv).
		Scan(&closed, &headN, &head); err != nil {
		return err
	}
	names, err := a.userLabels(ctx)
	if err != nil {
		return err
	}
	recs, err := store.ListChanges(ctx, a.pool, conv, 0, 0)
	if err != nil {
		return err
	}
	signed := make([]proto.SignedChange, len(recs))
	for i, r := range recs {
		signed[i] = r.SignedChange
	}
	keys, err := store.ChainKeys(ctx, a.pool, signed)
	if err != nil {
		return err
	}

	fmt.Fprintf(a.out, "ID: %s\nEncerrado em: %s\n\nCadeia:\n", proto.FormatUUID(conv), stampOpt(closed))
	st := proto.NewGroupState(conv)
	var bad error
	for _, r := range recs {
		if bad = st.Apply(r.SignedChange, keys); bad != nil {
			break
		}
		c, err := proto.DecodeChange(r.Bytes)
		if err != nil {
			return err
		}
		fmt.Fprintf(a.out, "  %d · %s · %s\n", r.N, names.describe(c), stamp(r.ReceivedAt))
	}
	switch {
	case bad != nil:
		fmt.Fprintf(a.out, "\nATENÇÃO: a cadeia NÃO confere a partir daqui: %v\n", bad)
	case st.N != headN || string(st.Head[:]) != string(head):
		fmt.Fprintf(a.out, "\nATENÇÃO: a cadeia NÃO confere: o topo registrado é o %d e a cadeia vai até o %d.\n", headN, st.N)
	}

	// Label and members come from the records that verified, not from the tables.
	label := "(sem rótulo: grupo criado por um usuário)"
	if st.AdminLabel != "" {
		label = clean(st.AdminLabel)
	}
	fmt.Fprintf(a.out, "\nRótulo: %s\nMembros segundo a cadeia verificada:\n", label)
	var rows [][]string
	for _, m := range st.SortedMembers() {
		role := "membro"
		if m.Role == proto.RoleAdmin {
			role = "admin"
		}
		rows = append(rows, []string{proto.FormatUUID(m.User), names.name(m.User), role})
	}
	return a.table("USUÁRIO|RÓTULO|PAPEL", rows)
}
