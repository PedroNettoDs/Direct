// Command directd is the Direct messaging server (HTTP API + WebSocket).
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nettotech/direct/server/internal/server"
	"github.com/nettotech/direct/server/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	if err := run(log); err != nil {
		log.Error("directd terminou", "err", err.Error())
		os.Exit(1)
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// loadSignKey reads the 32-byte server signing seed; creates it (mode 0600) on first run.
func loadSignKey(path string) (ed25519.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		seed := make([]byte, ed25519.SeedSize)
		if _, err := rand.Read(seed); err != nil {
			return nil, err
		}
		if err := os.WriteFile(path, seed, 0o600); err != nil {
			return nil, err
		}
		b = seed
	} else if err != nil {
		return nil, err
	}
	if len(b) != ed25519.SeedSize {
		return nil, fmt.Errorf("%s: esperado %d bytes, tem %d", path, ed25519.SeedSize, len(b))
	}
	return ed25519.NewKeyFromSeed(b), nil
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	dbURL, err := store.URLFromEnv(os.Getenv)
	if err != nil {
		return err
	}
	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		return err
	}
	pool, err := store.Open(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := store.Migrate(ctx, pool); err != nil {
		return fmt.Errorf("migrações: %w", err)
	}
	key, err := loadSignKey(env("DIRECT_SERVER_SIGN_KEY_FILE", "/data/server_sign.key"))
	if err != nil {
		return err
	}
	ipHdr, proxy := os.Getenv("DIRECT_TRUSTED_IP_HEADER"), os.Getenv("DIRECT_TRUSTED_PROXY")
	if ipHdr != "" && proxy == "" {
		log.Warn("DIRECT_TRUSTED_IP_HEADER ignorado: defina DIRECT_TRUSTED_PROXY")
	}
	srv, err := server.New(ctx, server.Config{
		Pool: pool, SignKey: key, Log: log,
		TrustedIPHeader: ipHdr, TrustedProxy: proxy,
	})
	if err != nil {
		return err
	}
	srv.Run(ctx)

	hs := &http.Server{
		Addr:              env("DIRECT_LISTEN", ":8080"),
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second, // hijacked WebSocket connections are not affected
		IdleTimeout:       120 * time.Second,
	}
	errc := make(chan error, 1)
	go func() { errc <- hs.ListenAndServe() }()
	log.Info("directd ouvindo", "addr", hs.Addr)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	srv.CloseAll()
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return hs.Shutdown(sctx)
}
