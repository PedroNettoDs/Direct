-- +goose Up
-- Groups (docs/protocolo-grupos.md 10.2).
ALTER TABLE server_keys ADD COLUMN mod_pub bytea CHECK (length(mod_pub) = 32);

ALTER TABLE conversations
    ADD COLUMN admin_label text,
    ADD COLUMN chain_n     bigint NOT NULL DEFAULT 0,
    ADD COLUMN chain_hash  bytea,
    ADD COLUMN closed_at   timestamptz;

-- One row per membership interval. joined_n = 0 in direct conversations (it is part of the key).
ALTER TABLE conversation_members
    ADD COLUMN role     text NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'admin')),
    ADD COLUMN joined_n bigint NOT NULL DEFAULT 0,
    ADD COLUMN left_n   bigint,
    ADD COLUMN history  boolean NOT NULL DEFAULT false;
ALTER TABLE conversation_members DROP CONSTRAINT conversation_members_pkey;
ALTER TABLE conversation_members ADD PRIMARY KEY (conversation_id, user_id, joined_n);
CREATE UNIQUE INDEX conversation_members_open_uq ON conversation_members(conversation_id, user_id)
    WHERE left_at IS NULL;

CREATE TABLE group_changes (
    conversation_id  uuid NOT NULL REFERENCES conversations(id),
    n                bigint NOT NULL CHECK (n >= 1),
    change_bytes     bytea NOT NULL,
    signature        bytea NOT NULL CHECK (length(signature) = 64),
    record_hash      bytea NOT NULL CHECK (length(record_hash) = 32),
    kind             smallint NOT NULL,
    author_device_id uuid REFERENCES devices(id),   -- NULL = moderator
    author_user_id   uuid REFERENCES users(id),
    received_at      timestamptz NOT NULL,
    PRIMARY KEY (conversation_id, n)
);

ALTER TABLE epochs
    ADD COLUMN chain_n    bigint,                    -- NULL = direct conversation
    ADD COLUMN chain_hash bytea CHECK (length(chain_hash) = 32);

ALTER TABLE epoch_key_wraps
    ADD COLUMN source text NOT NULL DEFAULT 'creator' CHECK (source IN ('creator', 'history', 'escrow'));

CREATE TABLE group_meta (
    conversation_id uuid NOT NULL REFERENCES conversations(id),
    epoch           integer NOT NULL,
    meta_commit     bytea NOT NULL CHECK (length(meta_commit) = 32),
    nonce           bytea NOT NULL CHECK (length(nonce) = 24),
    ciphertext      bytea NOT NULL,
    PRIMARY KEY (conversation_id, epoch)
);

CREATE TABLE user_access_events (
    id      bigserial PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    active  boolean NOT NULL,
    at      timestamptz NOT NULL
);
CREATE INDEX user_access_events_user_idx ON user_access_events(user_id, id);

ALTER TABLE devices
    ADD COLUMN revoked_reason text CHECK (revoked_reason IN ('admin', 'self', 'user_disabled', 'expired')),
    -- created_at of a pre-signed revocation (device clock, audit only).
    ADD COLUMN revoke_signed_at bigint;

ALTER TABLE enrollment_tokens
    ADD COLUMN revoked_at     timestamptz,
    ADD COLUMN reactivated_at timestamptz,
    ADD COLUMN reactivations  integer NOT NULL DEFAULT 0;

-- +goose Down
DROP TABLE user_access_events, group_meta, group_changes;
ALTER TABLE enrollment_tokens DROP COLUMN revoked_at, DROP COLUMN reactivated_at, DROP COLUMN reactivations;
ALTER TABLE devices DROP COLUMN revoked_reason, DROP COLUMN revoke_signed_at;
ALTER TABLE epoch_key_wraps DROP COLUMN source;
ALTER TABLE epochs DROP COLUMN chain_n, DROP COLUMN chain_hash;
DROP INDEX conversation_members_open_uq;
DELETE FROM conversation_members WHERE joined_n <> 0;
ALTER TABLE conversation_members DROP CONSTRAINT conversation_members_pkey;
ALTER TABLE conversation_members ADD PRIMARY KEY (conversation_id, user_id);
ALTER TABLE conversation_members DROP COLUMN role, DROP COLUMN joined_n, DROP COLUMN left_n, DROP COLUMN history;
ALTER TABLE conversations DROP COLUMN admin_label, DROP COLUMN chain_n, DROP COLUMN chain_hash, DROP COLUMN closed_at;
ALTER TABLE server_keys DROP COLUMN mod_pub;
