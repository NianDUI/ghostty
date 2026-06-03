package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// uploadInit runs init and returns the upload_id.
func uploadInit(t *testing.T, ts interface{ url() string }, sessionID, userToken string, payload map[string]any) jsonResp {
	t.Helper()
	return doJSON(t, http.MethodPost, ts.url()+"/api/upload/init", payload, bearer(userToken))
}

// tsWrap adapts httptest.Server to the small interface above.
type tsWrap struct{ u string }

func (w tsWrap) url() string { return w.u }

// ---- 9. upload full chain (init -> PUT -> pull) ----

func TestUploadFullChain(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "up-sess", "Box", "user-tok")
	w := tsWrap{ts.URL}

	content := []byte("hello upload world")
	sum := sha256.Sum256(content)
	wantSHA := hex.EncodeToString(sum[:])

	// init with a name containing a space (for the %20 assertion later).
	initResp := uploadInit(t, w, "up-sess", "user-tok", map[string]any{
		"session_id": "up-sess",
		"name":       "my file.txt",
		"size":       len(content),
		"sha256":     wantSHA,
	})
	if initResp.status != 200 {
		t.Fatalf("init status=%d body=%s", initResp.status, initResp.body)
	}
	var initData map[string]any
	initResp.decode(t, &initData)
	uploadID, _ := initData["upload_id"].(string)
	if uploadID == "" {
		t.Fatalf("missing upload_id: %s", initResp.body)
	}
	for _, k := range []string{"upload_url", "expires_at", "chunk_size", "patch_max_bytes"} {
		if _, ok := initData[k]; !ok {
			t.Errorf("init response missing %s", k)
		}
	}

	// PUT single-shot.
	putResp := doReq(t, http.MethodPut, ts.URL+"/api/upload/"+uploadID, content, map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Length": fmt.Sprintf("%d", len(content)),
	})
	if putResp.status != 200 {
		t.Fatalf("put status=%d body=%s", putResp.status, putResp.body)
	}
	var putData map[string]any
	putResp.decode(t, &putData)
	if rv, _ := putData["received"].(float64); int(rv) != len(content) {
		t.Errorf("received=%v, want %d", putData["received"], len(content))
	}
	if putData["sha256"] != wantSHA {
		t.Errorf("sha256=%v, want %s", putData["sha256"], wantSHA)
	}

	// pull with pull_token. The pull_token is delivered to the agent via the
	// upload_ready frame; for this test we read it from server state.
	_ = reg
	pullToken := lookupPullToken(t, tsWrap{ts.URL}, uploadID)

	q := url.Values{"token": {pullToken}}
	pullResp := doReq(t, http.MethodGet, ts.URL+"/api/upload/"+uploadID+"/pull?"+q.Encode(), nil, nil)
	if pullResp.status != 200 {
		t.Fatalf("pull status=%d body=%s", pullResp.status, pullResp.body)
	}
	if string(pullResp.body) != string(content) {
		t.Errorf("pulled body=%q, want %q", pullResp.body, content)
	}
	// The name "my file.txt" must encode the space as %20, not +.
	gotName := pullResp.headers.Get("X-Ghostty-Upload-Name")
	if gotName != "my%20file.txt" {
		t.Errorf("X-Ghostty-Upload-Name=%q, want my%%20file.txt", gotName)
	}
	if pullResp.headers.Get("X-Ghostty-Upload-SHA256") != wantSHA {
		t.Errorf("X-Ghostty-Upload-SHA256=%q", pullResp.headers.Get("X-Ghostty-Upload-SHA256"))
	}

	// A successful pull removes the upload from state (finally: _remove_upload
	// reason=pulled), so a second pull no longer finds it -> 404 not_found.
	pull2 := doReq(t, http.MethodGet, ts.URL+"/api/upload/"+uploadID+"/pull?"+q.Encode(), nil, nil)
	if pull2.status != 404 {
		t.Fatalf("second pull status=%d body=%s", pull2.status, pull2.body)
	}
	if e := pull2.errorField(t); e != "not_found" {
		t.Errorf("error=%q, want not_found", e)
	}
}

// TestUploadPullDeliveredGone exercises the 410 gone branch directly: when an
// upload is still in the pending map but already marked Delivered (the window
// before _remove_upload runs, or a concurrent double-pull), pull returns 410.
func TestUploadPullDeliveredGone(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "gone-sess", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "gone-sess", "user-tok", 4)

	// Complete the upload but force Delivered=true while leaving it in the map.
	doReq(t, http.MethodPut, ts.URL+"/api/upload/"+id, []byte("data"), map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Length": "4",
	})
	st := stateFor(tsWrap{ts.URL})
	st.mu.Lock()
	var pullToken string
	for _, sess := range st.sessions {
		if u := sess.PendingUploads[id]; u != nil {
			u.Delivered = true
			pullToken = u.PullToken
		}
	}
	st.mu.Unlock()

	q := url.Values{"token": {pullToken}}
	resp := doReq(t, http.MethodGet, ts.URL+"/api/upload/"+id+"/pull?"+q.Encode(), nil, nil)
	if resp.status != 410 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "gone" {
		t.Errorf("error=%q, want gone", e)
	}
}

// lookupPullToken reads the upload's pull_token directly from server state.
// We register through a helper that returns a *httptest.Server, but to reach
// state we re-find the upload. Instead we expose state by re-walking sessions
// via a metric-free path: the test server's handler holds the state, so we
// keep a package-level registry keyed by the running server. Simplest: re-do
// via a dedicated helper that captures state at server creation.
//
// To avoid threading state through every call we store it on a map below.
func lookupPullToken(t *testing.T, ts httpServer, uploadID string) string {
	t.Helper()
	st := stateFor(ts)
	st.mu.Lock()
	defer st.mu.Unlock()
	for _, sess := range st.sessions {
		if u := sess.PendingUploads[uploadID]; u != nil {
			return u.PullToken
		}
	}
	t.Fatalf("upload %s not found in state", uploadID)
	return ""
}

// ---- 10. upload boundaries ----

func TestUploadInitBoundaries(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "ub", "Box", "user-tok")
	w := tsWrap{ts.URL}

	cases := []struct {
		name    string
		payload map[string]any
		status  int
		errStr  string
	}{
		{"zero size", map[string]any{"session_id": "ub", "name": "f", "size": 0}, 400, "invalid_size"},
		{"negative size", map[string]any{"session_id": "ub", "name": "f", "size": -5}, 400, "invalid_size"},
		{"size too large", map[string]any{"session_id": "ub", "name": "f", "size": (100 << 20) + 1}, 413, "size_exceeds_limit"},
		{"bad sha256", map[string]any{"session_id": "ub", "name": "f", "size": 10, "sha256": "xyz"}, 400, "invalid_sha256"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp := uploadInit(t, w, "ub", "user-tok", tc.payload)
			if resp.status != tc.status {
				t.Fatalf("status=%d want %d body=%s", resp.status, tc.status, resp.body)
			}
			if e := resp.errorField(t); e != tc.errStr {
				t.Errorf("error=%q want %q", e, tc.errStr)
			}
		})
	}
}

// freshUpload inits an upload of the given size and returns its id.
func freshUpload(t *testing.T, ts *http.Client, base, session, token string, size int) string {
	t.Helper()
	resp := doJSON(t, http.MethodPost, base+"/api/upload/init", map[string]any{
		"session_id": session, "name": "f.bin", "size": size,
	}, bearer(token))
	if resp.status != 200 {
		t.Fatalf("init status=%d body=%s", resp.status, resp.body)
	}
	var m map[string]any
	resp.decode(t, &m)
	id, _ := m["upload_id"].(string)
	return id
}

func TestUploadPutSizeMismatch(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "sm", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "sm", "user-tok", 10)

	// Declared (Content-Length) != upload.size.
	resp := doReq(t, http.MethodPut, ts.URL+"/api/upload/"+id, []byte("12345"), map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Length": "5",
	})
	if resp.status != 409 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "size_mismatch" {
		t.Errorf("error=%q", e)
	}
}

func TestUploadPutAlreadyUploaded(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "au", "Box", "user-tok")
	content := []byte("0123456789")
	id := freshUpload(t, http.DefaultClient, ts.URL, "au", "user-tok", len(content))

	hdr := map[string]string{"Authorization": "Bearer user-tok", "Content-Length": "10"}
	first := doReq(t, http.MethodPut, ts.URL+"/api/upload/"+id, content, hdr)
	if first.status != 200 {
		t.Fatalf("first put status=%d body=%s", first.status, first.body)
	}
	second := doReq(t, http.MethodPut, ts.URL+"/api/upload/"+id, content, hdr)
	if second.status != 409 {
		t.Fatalf("second put status=%d body=%s", second.status, second.body)
	}
	if e := second.errorField(t); e != "already_uploaded" {
		t.Errorf("error=%q", e)
	}
}

// TestUploadPutMalformedContentLength sends a syntactically invalid
// Content-Length header ("abc") via a raw connection, because net/http's Client
// will not emit a non-numeric CL. The relay's parseContentLength rejects it
// before reaching the upload state machine, returning 400 invalid_content_length.
func TestUploadPutMalformedContentLength(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "mcl", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "mcl", "user-tok", 10)

	status, errStr := rawPutInvalidCL(t, ts.URL, "/api/upload/"+id)
	// Go's net/http server may reject a malformed Content-Length at the
	// protocol layer (400 before our handler). Accept either path but require
	// a 400; if our handler runs we additionally see invalid_content_length.
	if status != 400 {
		t.Fatalf("status=%d, want 400 (errStr=%q)", status, errStr)
	}
	if errStr != "" && errStr != "invalid_content_length" {
		t.Errorf("error=%q, want invalid_content_length or empty (server-layer reject)", errStr)
	}
	t.Logf("malformed CL -> status=%d errStr=%q", status, errStr)
}

// rawPutInvalidCL hand-writes a PUT with Content-Length: abc and returns the
// parsed status and (if JSON) the error field.
func rawPutInvalidCL(t *testing.T, baseURL, path string) (int, string) {
	t.Helper()
	host := strings.TrimPrefix(baseURL, "http://")
	conn, err := net.Dial("tcp", host)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	req := "PUT " + path + " HTTP/1.1\r\n" +
		"Host: " + host + "\r\n" +
		"Authorization: Bearer user-tok\r\n" +
		"Content-Length: abc\r\n" +
		"Connection: close\r\n" +
		"\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		t.Fatalf("write: %v", err)
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	defer resp.Body.Close()
	var sb strings.Builder
	buf := make([]byte, 4096)
	for {
		n, e := resp.Body.Read(buf)
		sb.Write(buf[:n])
		if e != nil {
			break
		}
	}
	errStr := ""
	if strings.Contains(resp.Header.Get("Content-Type"), "json") {
		var m map[string]any
		if jsonUnmarshal(sb.String(), &m) == nil {
			errStr, _ = m["error"].(string)
		}
	}
	return resp.StatusCode, errStr
}

// ---- 10b. PATCH (tus) flow ----

func TestUploadPatchFlow(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "pt", "Box", "user-tok")
	full := []byte("AAAAABBBBBCCCCC") // 15 bytes
	sum := sha256.Sum256(full)
	wantSHA := hex.EncodeToString(sum[:])
	id := freshUpload(t, http.DefaultClient, ts.URL, "pt", "user-tok", len(full))

	patchHdr := func(offset int) map[string]string {
		return map[string]string{
			"Authorization": "Bearer user-tok",
			"Content-Type":  "application/offset+octet-stream",
			"Upload-Offset": fmt.Sprintf("%d", offset),
		}
	}

	// First chunk (offset 0, 10 bytes) -> 204 intermediate + Upload-Offset.
	c1 := doReq(t, http.MethodPatch, ts.URL+"/api/upload/"+id, full[:10], withCL(patchHdr(0), 10))
	if c1.status != 204 {
		t.Fatalf("chunk1 status=%d body=%s", c1.status, c1.body)
	}
	if c1.headers.Get("Upload-Offset") != "10" {
		t.Errorf("chunk1 Upload-Offset=%q", c1.headers.Get("Upload-Offset"))
	}

	// Offset mismatch -> 409 with Upload-Offset header pointing at 10.
	bad := doReq(t, http.MethodPatch, ts.URL+"/api/upload/"+id, full[10:], withCL(patchHdr(3), 5))
	if bad.status != 409 {
		t.Fatalf("offset-mismatch status=%d", bad.status)
	}
	if e := bad.errorField(t); e != "offset_mismatch" {
		t.Errorf("error=%q", e)
	}
	if bad.headers.Get("Upload-Offset") != "10" {
		t.Errorf("offset_mismatch Upload-Offset=%q, want 10", bad.headers.Get("Upload-Offset"))
	}

	// Final chunk (offset 10, 5 bytes) -> 200 complete.
	c2 := doReq(t, http.MethodPatch, ts.URL+"/api/upload/"+id, full[10:], withCL(patchHdr(10), 5))
	if c2.status != 200 {
		t.Fatalf("chunk2 status=%d body=%s", c2.status, c2.body)
	}
	if c2.headers.Get("Upload-Offset") != "15" {
		t.Errorf("chunk2 Upload-Offset=%q", c2.headers.Get("Upload-Offset"))
	}
	var fin map[string]any
	c2.decode(t, &fin)
	if fin["sha256"] != wantSHA {
		t.Errorf("final sha256=%v want %s", fin["sha256"], wantSHA)
	}
}

func TestUploadPatchWrongContentType(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "pct", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "pct", "user-tok", 5)
	resp := doReq(t, http.MethodPatch, ts.URL+"/api/upload/"+id, []byte("hello"), map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Type":   "application/octet-stream",
		"Upload-Offset":  "0",
		"Content-Length": "5",
	})
	if resp.status != 415 {
		t.Fatalf("status=%d", resp.status)
	}
	if e := resp.errorField(t); e != "invalid_content_type" {
		t.Errorf("error=%q", e)
	}
}

func TestUploadHead(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "hd", "Box", "user-tok")
	id := freshUpload(t, http.DefaultClient, ts.URL, "hd", "user-tok", 20)

	// Upload 8 bytes first via PATCH.
	doReq(t, http.MethodPatch, ts.URL+"/api/upload/"+id, []byte("AAAAAAAA"), map[string]string{
		"Authorization":  "Bearer user-tok",
		"Content-Type":   "application/offset+octet-stream",
		"Upload-Offset":  "0",
		"Content-Length": "8",
	})

	resp := doReq(t, http.MethodHead, ts.URL+"/api/upload/"+id, nil, bearer("user-tok"))
	if resp.status != 200 {
		t.Fatalf("status=%d", resp.status)
	}
	if resp.headers.Get("Upload-Offset") != "8" {
		t.Errorf("Upload-Offset=%q, want 8", resp.headers.Get("Upload-Offset"))
	}
	if resp.headers.Get("Upload-Length") != "20" {
		t.Errorf("Upload-Length=%q, want 20", resp.headers.Get("Upload-Length"))
	}
}

func withCL(h map[string]string, n int) map[string]string {
	h["Content-Length"] = fmt.Sprintf("%d", n)
	return h
}
