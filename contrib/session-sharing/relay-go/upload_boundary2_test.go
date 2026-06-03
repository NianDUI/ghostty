package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// TestUploadReadyDeliveredToAgent completes an upload while an agent WS is
// connected and asserts the relay pushes an upload_ready control frame
// (uploadReadyFrame + pushUploadReadyUnlocked).
func TestUploadReadyDeliveredToAgent(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "ur", "Box", "user-tok")
	agent := dialAgent(t, ts, "ur", reg.AgentToken)
	time.Sleep(50 * time.Millisecond)

	content := []byte("payload-bytes")
	initResp := uploadInit(t, tsWrap{ts.URL}, "ur", "user-tok", map[string]any{
		"session_id": "ur", "name": "doc.txt", "size": len(content),
	})
	if initResp.status != 200 {
		t.Fatalf("init status=%d body=%s", initResp.status, initResp.body)
	}
	var m map[string]any
	initResp.decode(t, &m)
	id, _ := m["upload_id"].(string)

	// Complete the upload; the relay must notify the connected agent.
	put := doReq(t, http.MethodPut, ts.URL+"/api/upload/"+id, content, map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Length": itoa(len(content)),
	})
	if put.status != 200 {
		t.Fatalf("put status=%d body=%s", put.status, put.body)
	}

	_ = agent.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		mt, data, err := agent.ReadMessage()
		if err != nil {
			t.Fatalf("agent read: %v", err)
		}
		if mt != websocket.TextMessage {
			continue
		}
		var f map[string]any
		if json.Unmarshal(data, &f) != nil || f["type"] != "upload_ready" {
			continue
		}
		if f["upload_id"] != id {
			t.Errorf("upload_id=%v, want %v", f["upload_id"], id)
		}
		if f["name"] != "doc.txt" {
			t.Errorf("name=%v, want doc.txt", f["name"])
		}
		if pt, _ := f["pull_token"].(string); pt == "" {
			t.Errorf("upload_ready missing pull_token")
		}
		if f["pull_url"] != "/api/upload/"+id+"/pull" {
			t.Errorf("pull_url=%v", f["pull_url"])
		}
		return
	}
}

// ---- init boundaries not covered elsewhere ----

func TestUploadInitExpiredSession(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "exp-up", "Box", "user-tok")
	st.mu.Lock()
	st.sessions["exp-up"].ExpiresAt = nowSec() - 1
	st.mu.Unlock()

	resp := uploadInit(t, tsWrap{ts.URL}, "exp-up", "user-tok", map[string]any{
		"session_id": "exp-up", "name": "f", "size": 10,
	})
	if resp.status != 401 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "expired session" {
		t.Errorf("error=%q", e)
	}
	if metricValue(st, "expired_session_rejected_total") < 1 {
		t.Errorf("expired_session_rejected_total not bumped")
	}
}

func TestUploadInitTooManyPending(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.UploadMaxPending = 1
	ts, _ := newTestServer(t, cfg)
	registerSession(t, ts, "tmp", "Box", "user-tok")
	w := tsWrap{ts.URL}

	first := uploadInit(t, w, "tmp", "user-tok", map[string]any{"session_id": "tmp", "name": "a", "size": 10})
	if first.status != 200 {
		t.Fatalf("first init status=%d", first.status)
	}
	second := uploadInit(t, w, "tmp", "user-tok", map[string]any{"session_id": "tmp", "name": "b", "size": 10})
	if second.status != 429 {
		t.Fatalf("second init status=%d body=%s", second.status, second.body)
	}
	if e := second.errorField(t); e != "too_many_pending" {
		t.Errorf("error=%q", e)
	}
}

func TestUploadInitGlobalPendingFull(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.UploadGlobalMaxPending = 1 // per-session limit (4) stays higher
	ts, _ := newTestServer(t, cfg)
	registerSession(t, ts, "gp1", "Box", "user-tok")
	registerSession(t, ts, "gp2", "Box", "user-tok")
	w := tsWrap{ts.URL}

	first := uploadInit(t, w, "gp1", "user-tok", map[string]any{"session_id": "gp1", "name": "a", "size": 10})
	if first.status != 200 {
		t.Fatalf("first init status=%d", first.status)
	}
	// Different session, so per-session pending is 0, but global is already 1.
	second := uploadInit(t, w, "gp2", "user-tok", map[string]any{"session_id": "gp2", "name": "b", "size": 10})
	if second.status != 429 {
		t.Fatalf("second init status=%d body=%s", second.status, second.body)
	}
	if e := second.errorField(t); e != "global_pending_full" {
		t.Errorf("error=%q", e)
	}
}

func TestUploadInitSessionSizeLimit(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.UploadSessionMaxBytes = 100 // tiny per-session cap
	ts, _ := newTestServer(t, cfg)
	registerSession(t, ts, "ssl", "Box", "user-tok")

	resp := uploadInit(t, tsWrap{ts.URL}, "ssl", "user-tok", map[string]any{
		"session_id": "ssl", "name": "f", "size": 101, // < UploadMaxBytes but > session cap
	})
	if resp.status != 413 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "size_exceeds_session_limit" {
		t.Errorf("error=%q", e)
	}
}

// ---- pull / finalize / patch boundaries ----

func TestUploadPullNotComplete(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "nc", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "nc", "user-tok", 10)

	pullToken := lookupPullToken(t, tsWrap{ts.URL}, id)
	q := url.Values{"token": {pullToken}}
	resp := doReq(t, http.MethodGet, ts.URL+"/api/upload/"+id+"/pull?"+q.Encode(), nil, nil)
	if resp.status != 409 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "not_complete" {
		t.Errorf("error=%q", e)
	}
}

func TestUploadHashMismatch(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "hm", "Box", "user-tok")

	content := []byte("real-content")
	// Declare a sha256 of *different* bytes so finalize detects a mismatch.
	wrong := sha256.Sum256([]byte("something-else"))
	wrongSHA := hex.EncodeToString(wrong[:])

	initResp := uploadInit(t, tsWrap{ts.URL}, "hm", "user-tok", map[string]any{
		"session_id": "hm", "name": "f", "size": len(content), "sha256": wrongSHA,
	})
	if initResp.status != 200 {
		t.Fatalf("init status=%d body=%s", initResp.status, initResp.body)
	}
	var m map[string]any
	initResp.decode(t, &m)
	id, _ := m["upload_id"].(string)

	resp := doReq(t, http.MethodPut, ts.URL+"/api/upload/"+id, content, map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Length": itoa(len(content)),
	})
	if resp.status != 422 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "hash_mismatch" {
		t.Errorf("error=%q", e)
	}
}

func TestUploadPatchOvershoot(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "ov", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "ov", "user-tok", 5)

	// A 10-byte chunk against a 5-byte upload: received(0)+declared(10) > size(5).
	resp := doReq(t, http.MethodPatch, ts.URL+"/api/upload/"+id, []byte("0123456789"), map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Type":   "application/offset+octet-stream",
		"Upload-Offset":  "0",
		"Content-Length": "10",
	})
	if resp.status != 413 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "overshoot" {
		t.Errorf("error=%q", e)
	}
}

func TestUploadPatchAlreadyDelivered(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "ad", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "ad", "user-tok", 10)

	// Force Delivered=true; PATCH must short-circuit to 409 already_delivered.
	st := stateFor(tsWrap{ts.URL})
	st.mu.Lock()
	for _, sess := range st.sessions {
		if u := sess.PendingUploads[id]; u != nil {
			u.Delivered = true
		}
	}
	st.mu.Unlock()

	resp := doReq(t, http.MethodPatch, ts.URL+"/api/upload/"+id, []byte("x"), map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Type":   "application/offset+octet-stream",
		"Upload-Offset":  "0",
		"Content-Length": "1",
	})
	if resp.status != 409 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "already_delivered" {
		t.Errorf("error=%q", e)
	}
}
