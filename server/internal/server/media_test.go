package server_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/nettotech/direct/server/internal/proto"
	"github.com/nettotech/direct/server/internal/store"
	"github.com/nettotech/direct/server/internal/testvec"
)

// raw performs a request with a binary body and returns status, headers and body.
func (e *env) raw(method, path, token string, body []byte) (int, http.Header, []byte) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, _ := http.NewRequest(method, e.ts.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/octet-stream")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, out
}

func jsonOf(t *testing.T, b []byte) map[string]any {
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("bad json %q", b)
	}
	return m
}

func (e *env) userOf(deviceID string) proto.UUID {
	var u proto.UUID
	if err := e.pool.QueryRow(context.Background(), `SELECT user_id FROM devices WHERE id = $1`, uid(e.t, deviceID)).Scan(&u); err != nil {
		e.t.Fatal(err)
	}
	return u
}

func TestBlobsAndSaves(t *testing.T) {
	e := newEnv(t)
	tokA := e.enrollNew("A", 24*time.Hour)
	tokB := e.enrollNew("B", 24*time.Hour)
	tokC := e.enrollNew("C", 24*time.Hour) // a third user, not in the conversation
	userA, userB := e.userOf(e.device("A").DeviceID), e.userOf(e.device("B").DeviceID)

	st, conv := e.call("POST", "/v1/conversations", tokA, map[string]any{"kind": "direct", "peer_user_id": proto.FormatUUID(userB)})
	if st != 200 {
		t.Fatalf("conversation: %d %v", st, conv)
	}
	convID := conv["conversation_id"].(string)
	up := "/v1/blobs?conversation_id=" + convID

	// The blob is opaque to the server: use the vector blob.
	var an struct {
		Blob       string `json:"blob"`
		BlobSHA256 string `json:"blob_sha256"`
	}
	testvec.Load(t, "anexo", &an)
	blob, wantSum := testvec.Hex(t, an.Blob), testvec.Hex(t, an.BlobSHA256)

	// Upload by a member.
	st, _, body := e.raw("POST", up, tokA, blob)
	if st != 201 {
		t.Fatalf("upload: %d %s", st, body)
	}
	up1 := jsonOf(t, body)
	if up1["size"] != float64(len(blob)) || up1["sha256"] != proto.B64Encode(wantSum) {
		t.Fatalf("upload answer: %v", up1)
	}
	blobID := up1["blob_id"].(string)

	// Download by the other member returns the exact bytes, never cached.
	st, h, got := e.raw("GET", "/v1/blobs/"+blobID, tokB, nil)
	if st != 200 || !bytes.Equal(got, blob) || h.Get("Cache-Control") != "no-store" || h.Get("Content-Type") != "application/octet-stream" {
		t.Fatalf("download: %d %v len=%d", st, h, len(got))
	}
	if s := sha256.Sum256(got); !bytes.Equal(s[:], wantSum) {
		t.Fatal("hash differs")
	}

	// Authorization.
	if st, _, b := e.raw("POST", up, tokC, blob); st != 403 || errCode(jsonOf(t, b)) != "forbidden" {
		t.Fatalf("outsider upload: %d %s", st, b)
	}
	if st, _, b := e.raw("GET", "/v1/blobs/"+blobID, tokC, nil); st != 403 {
		t.Fatalf("outsider download: %d %s", st, b)
	}
	if st, _, _ := e.raw("GET", "/v1/blobs/"+blobID, "", nil); st != 401 {
		t.Fatalf("no token: %d", st)
	}
	if st, _, b := e.raw("GET", "/v1/blobs/"+e.randUUIDString(), tokA, nil); st != 404 {
		t.Fatalf("unknown blob: %d %s", st, b)
	}
	if st, _, _ := e.raw("GET", "/v1/blobs/not-a-uuid", tokA, nil); st != 400 {
		t.Fatalf("bad id: %d", st)
	}
	if st, _, _ := e.raw("POST", "/v1/blobs", tokA, blob); st != 400 {
		t.Fatalf("missing conversation_id: %d", st)
	}
	if st, _, _ := e.raw("POST", "/v1/blobs?conversation_id="+e.randUUIDString(), tokA, blob); st != 404 {
		t.Fatalf("unknown conversation: %d", st)
	}

	// Size limits: 40 bytes is too short, 10 MiB is the maximum, one more byte is refused.
	if st, _, b := e.raw("POST", up, tokA, make([]byte, store.MinBlob-1)); st != 400 {
		t.Fatalf("short blob: %d %s", st, b)
	}
	e.adv(time.Minute)
	if st, _, b := e.raw("POST", up, tokA, make([]byte, store.MaxBlob)); st != 201 {
		t.Fatalf("max blob: %d %s", st, b)
	}
	if st, _, b := e.raw("POST", up, tokA, make([]byte, store.MaxBlob+1)); st != 413 || errCode(jsonOf(t, b)) != "too_large" {
		t.Fatalf("oversize blob: %d %s", st, b)
	}

	// Saves need an existing message.
	if st, o := e.call("POST", "/v1/media/saves", tokB, map[string]any{"conversation_id": convID, "seq": 1}); st != 404 {
		t.Fatalf("save without message: %d %v", st, o)
	}
	sender := e.device("A").DeviceID
	for seq := 1; seq <= 2; seq++ {
		_, err := e.pool.Exec(context.Background(), `INSERT INTO messages (conversation_id, seq, message_id, epoch, sender_device_id, sent_at, nonce, ciphertext, signature, created_at)
			VALUES ($1,$2,$3,1,$4,1795600000123,$5,$6,$7,$8)`, uid(t, convID), seq, e.randUUID(), uid(t, sender),
			make([]byte, 24), make([]byte, 272), make([]byte, 64), e.now())
		if err != nil {
			t.Fatal(err)
		}
	}
	e.adv(time.Minute)
	st, sv := e.call("POST", "/v1/media/saves", tokB, map[string]any{"conversation_id": convID, "seq": 2})
	if st != 201 || sv["user_id"] != proto.FormatUUID(userB) || sv["device_id"] != e.device("B").DeviceID || sv["saved_at"] != float64(e.now().UnixMilli()) {
		t.Fatalf("save: %d %v", st, sv)
	}
	saveID := sv["save_id"].(string)
	if st, o := e.call("POST", "/v1/media/saves", tokC, map[string]any{"conversation_id": convID, "seq": 2}); st != 403 {
		t.Fatalf("outsider save: %d %v", st, o)
	}
	if st, o := e.call("POST", "/v1/media/saves", tokB, map[string]any{"conversation_id": convID, "seq": 3}); st != 404 {
		t.Fatalf("save of future seq: %d %v", st, o)
	}
	if st, o := e.call("POST", "/v1/media/saves", tokB, map[string]any{"conversation_id": convID, "seq": 0}); st != 400 {
		t.Fatalf("seq 0: %d %v", st, o)
	}
	// A second save of the same message is a separate record.
	e.adv(time.Minute)
	st, sv2 := e.call("POST", "/v1/media/saves", tokA, map[string]any{"conversation_id": convID, "seq": 2})
	if st != 201 || sv2["save_id"] == saveID {
		t.Fatalf("second save: %d %v", st, sv2)
	}

	// store: lookup by save_id and listing (used by direct-admin media).
	ctx := context.Background()
	rec, err := store.GetMediaSave(ctx, e.pool, uid(t, saveID))
	if err != nil {
		t.Fatal(err)
	}
	if rec.UserID != userB || rec.DeviceID != uid(t, e.device("B").DeviceID) || rec.Seq != 2 || rec.ConversationID != uid(t, convID) ||
		rec.AdminLabel != e.device("B").AdminLabel || rec.SenderDeviceID != uid(t, sender) || rec.SenderUserID != userA ||
		rec.SenderLabel != e.device("A").AdminLabel || rec.SentAt != 1795600000123 {
		t.Fatalf("GetMediaSave: %+v", rec)
	}
	if _, err := store.GetMediaSave(ctx, e.pool, e.randUUID()); err != store.ErrNotFound {
		t.Fatalf("unknown save_id: %v", err)
	}
	all, err := store.ListMediaSaves(ctx, e.pool, store.SaveFilter{})
	if err != nil || len(all) != 2 || all[0].UserID != userA { // newest first
		t.Fatalf("list all: %v %+v", err, all)
	}
	byB, _ := store.ListMediaSaves(ctx, e.pool, store.SaveFilter{UserID: &userB})
	if len(byB) != 1 || byB[0].SaveID != rec.SaveID {
		t.Fatalf("list by user: %+v", byB)
	}
	cid := uid(t, convID)
	if l, _ := store.ListMediaSaves(ctx, e.pool, store.SaveFilter{ConversationID: &cid, Since: e.now(), Limit: 1}); len(l) != 1 || l[0].UserID != userA {
		t.Fatalf("list since: %+v", l)
	}
	if l, _ := store.ListMediaSaves(ctx, e.pool, store.SaveFilter{Until: rec.SavedAt}); len(l) != 0 {
		t.Fatalf("list until: %+v", l)
	}

	// A member who left loses access to blobs.
	if _, err := e.pool.Exec(ctx, `UPDATE conversation_members SET left_at = now() WHERE conversation_id = $1 AND user_id = $2`, cid, userB); err != nil {
		t.Fatal(err)
	}
	if st, _, _ := e.raw("GET", "/v1/blobs/"+blobID, tokB, nil); st != 403 {
		t.Fatalf("left member download: %d", st)
	}
	if st, _ := e.call("POST", "/v1/media/saves", tokB, map[string]any{"conversation_id": convID, "seq": 1}); st != 403 {
		t.Fatalf("left member save: %d", st)
	}
}

func TestMediaRateLimits(t *testing.T) {
	e := newEnv(t)
	tokA := e.enrollNew("A", 24*time.Hour)
	tokB := e.enrollNew("B", 24*time.Hour)
	_, conv := e.call("POST", "/v1/conversations", tokA, map[string]any{"kind": "direct", "peer_user_id": proto.FormatUUID(e.userOf(e.device("B").DeviceID))})
	convID := conv["conversation_id"].(string)
	blob := make([]byte, 64)
	n201 := 0
	for i := 0; i < 25; i++ {
		if st, _, _ := e.raw("POST", "/v1/blobs?conversation_id="+convID, tokB, blob); st == 201 {
			n201++
		} else if st != 429 {
			t.Fatalf("unexpected %d", st)
		}
	}
	if n201 != 20 {
		t.Fatalf("burst of 20 expected, got %d", n201)
	}
}
