// Package store opens PostgreSQL (pgx) and applies the embedded goose migrations.
package store

import (
	"bytes"
	"context"
	"embed"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrations embed.FS

// URLFromEnv builds the connection string from DIRECT_DB_URL or the DIRECT_DB_* variables
// (password read from DIRECT_DB_PASSWORD_FILE, never from the command line).
func URLFromEnv(getenv func(string) string) (string, error) {
	if u := getenv("DIRECT_DB_URL"); u != "" {
		return u, nil
	}
	host, name, user := getenv("DIRECT_DB_HOST"), getenv("DIRECT_DB_NAME"), getenv("DIRECT_DB_USER")
	if host == "" || name == "" || user == "" {
		return "", errors.New("set DIRECT_DB_URL or DIRECT_DB_HOST, DIRECT_DB_NAME, DIRECT_DB_USER")
	}
	port := getenv("DIRECT_DB_PORT")
	if port == "" {
		port = "5432"
	}
	pw := getenv("DIRECT_DB_PASSWORD")
	if f := getenv("DIRECT_DB_PASSWORD_FILE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			return "", err
		}
		pw = string(bytes.TrimRight(b, "\r\n"))
	}
	ssl := getenv("DIRECT_DB_SSLMODE")
	if ssl == "" {
		ssl = "disable" // internal Docker network
	}
	// Key/value form avoids URL-escaping the password.
	esc := func(s string) string { return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(s) + "'" }
	return fmt.Sprintf("host=%s port=%s dbname=%s user=%s password=%s sslmode=%s",
		esc(host), port, esc(name), esc(user), esc(pw), ssl), nil
}

// Open connects and verifies the connection.
func Open(ctx context.Context, cfg *pgxpool.Config) (*pgxpool.Pool, error) {
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

// Migrate applies all pending migrations.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	goose.SetBaseFS(migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	return goose.UpContext(ctx, db, "migrations")
}

// EnsureServerKey records the server signing public key and refuses to run with a different one.
func EnsureServerKey(ctx context.Context, pool *pgxpool.Pool, pub []byte) error {
	if _, err := pool.Exec(ctx, `INSERT INTO server_keys (server_sign_pub) VALUES ($1) ON CONFLICT DO NOTHING`, pub); err != nil {
		return err
	}
	var have []byte
	if err := pool.QueryRow(ctx, `SELECT server_sign_pub FROM server_keys`).Scan(&have); err != nil {
		return err
	}
	if !bytes.Equal(have, pub) {
		return errors.New("server signing key differs from server_keys.server_sign_pub (wrong key file?)")
	}
	return nil
}
