// Command direct-admin is the moderator CLI (docs/PLANO.md section 10). It talks to the database
// directly; every command is recorded in an append-only log outside the database.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
	"golang.org/x/term"
)

const usage = `uso:
  direct-admin token create --new-user "<rótulo>" [--ttl 24h] [--device-ttl 180d] [--host <domínio>]
  direct-admin token create --user <id> [--ttl 24h] [--device-ttl 180d] [--host <domínio>]
  direct-admin token list
  direct-admin token revoke <id>
  direct-admin token reactivate <id> --ttl 24h
  direct-admin user list
  direct-admin user show <id>
  direct-admin user disable <id>
  direct-admin device list [--user <id>]
  direct-admin device revoke <id>
  direct-admin escrow init --out <arquivo>
  direct-admin escrow rewrap --device <id> --key <arquivo>
  direct-admin moderator init --out <arquivo>
  direct-admin moderator register --pub <b64u>
  direct-admin moderator qr [--host <domínio>]
  direct-admin group list
  direct-admin group show <id>
  direct-admin group create --label "<rótulo>" --admin <user_id>... [--member <user_id>...] --mod-key <arquivo>
  direct-admin group remove-member <id> <user_id> --mod-key <arquivo>
  direct-admin group close <id> --mod-key <arquivo>
  direct-admin media saves [--user <id>] [--limit 100]
  direct-admin media lookup <save_id>
  direct-admin media prune [--older 30d]
`

var errUsage = errors.New("comando ou argumentos inválidos")

type app struct {
	pool *pgxpool.Pool
	out  io.Writer
	now  func() time.Time
	host string // public hostname for the QR (DIRECT_PUBLIC_HOST)
	// password reads a secret without echo; the caller clears the returned slice.
	password func(prompt string) ([]byte, error)
	// ask reads a visible answer (confirmations).
	ask  func(prompt string) (string, error)
	note string // target created by the command, for the audit log
}

var commands = map[string]func(*app, context.Context, []string) error{
	"token create":        (*app).tokenCreate,
	"token list":          (*app).tokenList,
	"token revoke":        (*app).tokenRevoke,
	"token reactivate":    (*app).tokenReactivate,
	"user list":           (*app).userList,
	"user show":           (*app).userShow,
	"user disable":        (*app).userDisable,
	"device list":         (*app).deviceList,
	"device revoke":       (*app).deviceRevoke,
	"escrow init":         (*app).escrowInit,
	"escrow rewrap":       (*app).escrowRewrap,
	"moderator init":      (*app).moderatorInit,
	"moderator register":  (*app).moderatorRegister,
	"moderator qr":        (*app).moderatorQR,
	"group list":          (*app).groupList,
	"group show":          (*app).groupShow,
	"group create":        (*app).groupCreate,
	"group remove-member": (*app).groupRemoveMember,
	"group close":         (*app).groupClose,
	"media saves":         (*app).mediaSaves,
	"media lookup":        (*app).mediaLookup,
	"media prune":         (*app).mediaPrune,
}

func (a *app) run(ctx context.Context, args []string) error {
	if len(args) < 2 {
		return errUsage
	}
	cmd, ok := commands[args[0]+" "+args[1]]
	if !ok {
		return errUsage
	}
	return cmd(a, ctx, args[2:])
}

// parse reads the flags and requires exactly n positional arguments (before or after the flags).
func parse(fs *flag.FlagSet, args []string, n int) ([]string, error) {
	fs.SetOutput(io.Discard)
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, fmt.Errorf("%w: %v", errUsage, err)
		}
		if fs.NArg() == 0 {
			break
		}
		pos, args = append(pos, fs.Arg(0)), fs.Args()[1:]
	}
	if len(pos) != n {
		return nil, errUsage
	}
	return pos, nil
}

func parseID(s string) (proto.UUID, error) {
	u, err := proto.ParseUUID(s)
	if err != nil {
		return u, fmt.Errorf("id inválido: %q", s)
	}
	return u, nil
}

// oneID is for the commands whose only argument is an id.
func oneID(name string, args []string) (proto.UUID, error) {
	pos, err := parse(flag.NewFlagSet(name, flag.ContinueOnError), args, 1)
	if err != nil {
		return proto.UUID{}, err
	}
	return parseID(pos[0])
}

// inTx runs f in a transaction and commits if it succeeds.
func (a *app) inTx(ctx context.Context, f func(store.DB) error) error {
	tx, err := a.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := f(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// audited records who ran what, before and after. Without a log line the command does not run.
// Arguments never carry secrets: passwords come from the terminal and invite seeds are not logged.
func audited(log io.Writer, operator string, a *app, args []string, f func() error) error {
	line := func(state string) error {
		_, err := fmt.Fprintf(log, "%s operator=%q args=%q %s\n", a.now().UTC().Format(time.RFC3339), operator, args, state)
		return err
	}
	if err := line("start"); err != nil {
		return fmt.Errorf("registro de comandos: %w", err)
	}
	err := f()
	state := "ok"
	if err != nil {
		state = fmt.Sprintf("error=%q", err.Error())
	}
	if a.note != "" {
		state += " " + a.note
	}
	if werr := line(state); werr != nil && err == nil {
		err = fmt.Errorf("comando executado, mas o registro falhou: %w", werr)
	}
	return err
}

func operatorName() string {
	for _, k := range []string{"DIRECT_ADMIN_OPERATOR", "SUDO_USER"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return fmt.Sprintf("uid %d", os.Getuid())
}

// readSecret reads without echo from a terminal, or one line from a pipe.
func readSecret(prompt string) ([]byte, error) {
	fmt.Fprint(os.Stderr, prompt)
	if fd := int(os.Stdin.Fd()); term.IsTerminal(fd) {
		defer fmt.Fprintln(os.Stderr)
		return term.ReadPassword(fd)
	}
	return readLine(os.Stdin)
}

// readAnswer reads a visible line from the standard input.
func readAnswer(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	line, err := readLine(os.Stdin)
	return string(line), err
}

// readLine reads byte by byte: no buffer keeps a copy or swallows the next line.
func readLine(r io.Reader) ([]byte, error) {
	line := make([]byte, 0, 256)
	var b [1]byte
	for {
		n, err := r.Read(b[:])
		if n == 1 && b[0] != '\n' {
			line = append(line, b[0])
			continue
		}
		if n == 1 || (errors.Is(err, io.EOF) && len(line) > 0) {
			return []byte(strings.TrimRight(string(line), "\r")), nil
		}
		if err != nil {
			return nil, fmt.Errorf("leitura da entrada: %w", err)
		}
	}
}

func cli(args []string) error {
	if len(args) < 2 || commands[args[0]+" "+args[1]] == nil {
		return errUsage
	}
	ctx := context.Background()
	a := &app{out: os.Stdout, now: time.Now, host: os.Getenv("DIRECT_PUBLIC_HOST"), password: readSecret, ask: readAnswer}

	path := os.Getenv("DIRECT_ADMIN_LOG")
	if path == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("defina DIRECT_ADMIN_LOG: %w", err)
		}
		path = filepath.Join(home, ".direct-admin.log")
	}
	log, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("registro de comandos: %w", err)
	}
	defer log.Close()

	return audited(log, operatorName(), a, args, func() error {
		// "moderator init" runs offline: it uses the database only when one is configured.
		if args[0]+" "+args[1] == "moderator init" && os.Getenv("DIRECT_DB_URL") == "" && os.Getenv("DIRECT_DB_HOST") == "" {
			return a.run(ctx, args)
		}
		url, err := store.URLFromEnv(os.Getenv)
		if err != nil {
			return err
		}
		cfg, err := pgxpool.ParseConfig(url)
		if err != nil {
			return err
		}
		// No migrations here: the schema belongs to the running directd.
		if a.pool, err = store.Open(ctx, cfg); err != nil {
			return err
		}
		defer a.pool.Close()
		return a.run(ctx, args)
	})
}

func main() {
	if err := cli(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "erro:", err)
		if errors.Is(err, errUsage) {
			fmt.Fprint(os.Stderr, usage)
			os.Exit(2)
		}
		os.Exit(1)
	}
}
