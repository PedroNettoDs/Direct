package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
)

// moderatorRegister stores only the public key on the server (docs/protocolo-grupos.md 3.1).
func (a *app) moderatorRegister(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("moderator register", flag.ContinueOnError)
	pubArg := fs.String("pub", "", "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	pub, err := proto.B64Fixed(*pubArg, ed25519.PublicKeySize)
	if err != nil {
		return fmt.Errorf("%w: --pub é a linha mod_sign_pub impressa por moderator init (base64url de 32 bytes)", errUsage)
	}
	keys, err := store.GetKeys(ctx, a.pool)
	if errors.Is(err, store.ErrNotFound) {
		return errors.New("banco sem chave do servidor: suba o directd uma vez antes")
	}
	if err != nil {
		return err
	}
	ok, err := store.SetModPub(ctx, a.pool, pub)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("chave do moderador já registrada; a v1 não troca a chave")
	}
	a.note = "mod_pub=" + *pubArg
	fmt.Fprintln(a.out, "Chave do moderador registrada. Os próximos convites saem no formato v=2.")
	if keys.EscrowPub != nil {
		fmt.Fprintf(a.out, "Código de verificação: %s\n", proto.ServerCodeMod(keys.ServerSignPub, keys.EscrowPub, pub))
	}
	return nil
}

// moderatorQR prints the QR that pins the moderator key on devices already enrolled (G 3.4).
func (a *app) moderatorQR(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("moderator qr", flag.ContinueOnError)
	host := fs.String("host", a.host, "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if !proto.ValidHost(*host) {
		return fmt.Errorf("domínio público inválido %q: use --host ou DIRECT_PUBLIC_HOST (minúsculas, sem porta)", *host)
	}
	if _, err := a.modKeys(ctx); err != nil {
		return err
	}
	keys, err := a.keys(ctx)
	if err != nil {
		return err
	}
	uri := proto.PinURI(*host, keys.ServerSignPub, keys.EscrowPub, keys.ModPub)
	qrText, err := renderQR(uri)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Mostre pessoalmente ou imprima.\n\n%s\n%s\n\nCódigo de verificação: %s\n",
		qrText, uri, proto.ServerCodeMod(keys.ServerSignPub, keys.EscrowPub, keys.ModPub))
	return nil
}

// moderatorInit generates the moderator signing key (docs/protocolo-grupos.md 3.1). It needs no
// database, so it can run offline; registering the public key on the server is a separate step.
func (a *app) moderatorInit(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("moderator init", flag.ContinueOnError)
	out := fs.String("out", "", "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if *out == "" {
		return fmt.Errorf("%w: falta --out", errUsage)
	}
	pw, err := a.newPassword("Senha da chave do moderador")
	if err != nil {
		return err
	}
	defer clear(pw)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	defer clear(priv)
	seed := priv.Seed()
	defer clear(seed)
	file, err := proto.SealModKey(seed, pw)
	if err != nil {
		return err
	}
	if err := writeNew(*out, file); err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Chave gravada em %s (faça uma segunda cópia offline).\nmod_sign_pub: %s\n", *out, proto.B64Encode(pub))

	// The verification code (G 3.3) also covers the server and escrow keys, known only to the database.
	if a.pool != nil {
		if keys, err := a.keys(ctx); err == nil {
			fmt.Fprintf(a.out, "Código de verificação: %s\n", proto.ServerCodeMod(keys.ServerSignPub, keys.EscrowPub, pub))
			return nil
		}
	}
	fmt.Fprintln(a.out, "Código de verificação: não calculado (precisa do banco com a chave escrow configurada).")
	return nil
}
