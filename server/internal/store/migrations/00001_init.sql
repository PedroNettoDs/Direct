-- +goose Up
CREATE TABLE users (
    id           uuid PRIMARY KEY,
    admin_label  text NOT NULL,
    display_name text NOT NULL DEFAULT '',
    status       text NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    disabled_at  timestamptz
);

CREATE TABLE devices (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users(id),
    platform     text NOT NULL,
    model        text NOT NULL DEFAULT '',
    os_version   text NOT NULL DEFAULT '',
    app_version  text NOT NULL DEFAULT '',
    sign_pub     bytea NOT NULL UNIQUE CHECK (length(sign_pub) = 32),
    kex_pub      bytea NOT NULL CHECK (length(kex_pub) = 32),
    cert_sig     bytea NOT NULL CHECK (length(cert_sig) = 64),
    enrolled_at  timestamptz NOT NULL,
    last_seen_at timestamptz,
    expires_at   timestamptz NOT NULL,
    revoked_at   timestamptz
);
CREATE INDEX devices_user_idx ON devices(user_id);

-- invite_pub replaces token_hash (protocolo.md 4.1): the QR carries an Ed25519 seed.
CREATE TABLE enrollment_tokens (
    id             uuid PRIMARY KEY,
    invite_pub     bytea NOT NULL UNIQUE CHECK (length(invite_pub) = 32),
    user_id        uuid REFERENCES users(id),      -- NULL = new user
    admin_label    text NOT NULL,
    expires_at     timestamptz NOT NULL,
    device_ttl     interval NOT NULL,
    used_at        timestamptz,
    used_by_device uuid REFERENCES devices(id)
);

CREATE TABLE auth_challenges (
    device_id  uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    challenge  bytea NOT NULL CHECK (length(challenge) = 32),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (device_id, challenge)
);

CREATE TABLE access_tokens (
    token_hash bytea PRIMARY KEY CHECK (length(token_hash) = 32),
    device_id  uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL
);
CREATE INDEX access_tokens_device_idx ON access_tokens(device_id, created_at);

CREATE TABLE server_keys (
    id              boolean PRIMARY KEY DEFAULT true CHECK (id),
    server_sign_pub bytea NOT NULL CHECK (length(server_sign_pub) = 32),
    escrow_pub      bytea CHECK (length(escrow_pub) = 32)
);

CREATE TABLE conversations (
    id           uuid PRIMARY KEY,
    kind         text NOT NULL CHECK (kind IN ('direct', 'group')),
    direct_key   text UNIQUE,                       -- "<low user id>:<high user id>" for direct
    created_at   timestamptz NOT NULL,
    latest_epoch integer NOT NULL DEFAULT 0,
    last_seq     bigint NOT NULL DEFAULT 0
);

CREATE TABLE conversation_members (
    conversation_id uuid NOT NULL REFERENCES conversations(id),
    user_id         uuid NOT NULL REFERENCES users(id),
    joined_at       timestamptz NOT NULL,
    left_at         timestamptz,
    PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX conversation_members_user_idx ON conversation_members(user_id);

CREATE TABLE epochs (
    conversation_id uuid NOT NULL REFERENCES conversations(id),
    epoch           integer NOT NULL CHECK (epoch >= 1),
    created_by_device uuid NOT NULL REFERENCES devices(id),
    created_at      timestamptz NOT NULL,
    key_commitment  bytea NOT NULL CHECK (length(key_commitment) = 32),
    recipients      bytea NOT NULL,                 -- concatenated 16-byte device ids, ascending
    signature       bytea NOT NULL CHECK (length(signature) = 64),
    PRIMARY KEY (conversation_id, epoch)
);

CREATE TABLE epoch_key_wraps (
    wrap_id             bigserial PRIMARY KEY,
    conversation_id     uuid NOT NULL,
    epoch               integer NOT NULL,
    recipient_device_id uuid REFERENCES devices(id),  -- NULL = escrow
    wrapped_key         bytea NOT NULL CHECK (length(wrapped_key) = 80),
    FOREIGN KEY (conversation_id, epoch) REFERENCES epochs(conversation_id, epoch)
);
CREATE UNIQUE INDEX epoch_wraps_device_uq ON epoch_key_wraps(conversation_id, epoch, recipient_device_id)
    WHERE recipient_device_id IS NOT NULL;
CREATE UNIQUE INDEX epoch_wraps_escrow_uq ON epoch_key_wraps(conversation_id, epoch)
    WHERE recipient_device_id IS NULL;
CREATE INDEX epoch_wraps_recipient_idx ON epoch_key_wraps(recipient_device_id, wrap_id);

CREATE TABLE messages (
    conversation_id  uuid NOT NULL REFERENCES conversations(id),
    seq              bigint NOT NULL,
    message_id       uuid NOT NULL,
    epoch            integer NOT NULL,
    sender_device_id uuid NOT NULL REFERENCES devices(id),
    sent_at          bigint NOT NULL,
    nonce            bytea NOT NULL CHECK (length(nonce) = 24),
    ciphertext       bytea NOT NULL,
    signature        bytea NOT NULL CHECK (length(signature) = 64),
    created_at       timestamptz NOT NULL,
    PRIMARY KEY (conversation_id, seq),
    UNIQUE (conversation_id, message_id)
);

-- +goose Down
DROP TABLE messages, epoch_key_wraps, epochs, conversation_members, conversations,
    server_keys, access_tokens, auth_challenges, enrollment_tokens, devices, users;
