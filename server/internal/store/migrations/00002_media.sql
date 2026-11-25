-- +goose Up
-- Encrypted attachments (docs/protocolo.md, seção 18). data = nonce || XChaCha20-Poly1305 ciphertext;
-- the server never holds the key. bytea: lives on the encrypted database volume, in pg_dump and in
-- the age backup, and goes away with the conversation.
CREATE TABLE blobs (
    id                 uuid PRIMARY KEY,
    conversation_id    uuid NOT NULL REFERENCES conversations(id),
    uploader_device_id uuid NOT NULL REFERENCES devices(id),
    size               integer NOT NULL CHECK (size BETWEEN 41 AND 10485760),
    sha256             bytea NOT NULL CHECK (length(sha256) = 32),
    data               bytea NOT NULL,
    created_at         timestamptz NOT NULL
);
CREATE INDEX blobs_conversation_idx ON blobs(conversation_id);

-- One row per "Salvar na galeria". The server learns that a message was saved, never its content.
CREATE TABLE media_saves (
    save_id         uuid PRIMARY KEY,
    conversation_id uuid NOT NULL,
    seq             bigint NOT NULL,
    user_id         uuid NOT NULL REFERENCES users(id),
    device_id       uuid NOT NULL REFERENCES devices(id),
    saved_at        timestamptz NOT NULL,
    FOREIGN KEY (conversation_id, seq) REFERENCES messages(conversation_id, seq)
);
CREATE INDEX media_saves_user_idx ON media_saves(user_id, saved_at DESC);
CREATE INDEX media_saves_message_idx ON media_saves(conversation_id, seq);

-- +goose Down
DROP TABLE media_saves, blobs;
