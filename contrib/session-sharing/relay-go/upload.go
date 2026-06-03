package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// sanitizeUploadName mirrors _sanitize_upload_name.
func sanitizeUploadName(raw any) (string, bool) {
	s, ok := raw.(string)
	if !ok {
		return "", false
	}
	trimmed := strings.TrimSpace(s)
	if trimmed == "" || len(trimmed) > uploadNameMaxLength { // len() is byte count
		return "", false
	}
	for _, ch := range trimmed {
		if _, bad := uploadForbiddenNameChars[ch]; bad {
			return "", false
		}
		if ch < 0x20 {
			return "", false
		}
	}
	if trimmed == "." || trimmed == ".." {
		return "", false
	}
	return trimmed, true
}

func stagingPath(st *RelayState, uploadID string) string {
	_ = os.MkdirAll(st.config.UploadDir, 0o755)
	return filepath.Join(st.config.UploadDir, uploadID+".bin")
}

// uploadReadyFrame mirrors _upload_ready_frame.
func uploadReadyFrame(u *PendingUpload) []byte {
	var sha any
	if u.HasSHA256 {
		sha = u.SHA256
	} else {
		sha = nil
	}
	return jsonBytes(map[string]any{
		"type":       "upload_ready",
		"upload_id":  u.UploadID,
		"name":       u.Name,
		"size":       u.Size,
		"sha256":     sha,
		"pull_token": u.PullToken,
		"pull_url":   "/api/upload/" + u.UploadID + "/pull",
	})
}

// queuePendingNotificationLocked mirrors _queue_pending_notification.
func queuePendingNotificationLocked(session *Session, uploadID string) {
	for _, id := range session.PendingReadyNotifications {
		if id == uploadID {
			return
		}
	}
	session.PendingReadyNotifications = append(session.PendingReadyNotifications, uploadID)
}

// pushUploadReadyUnlocked mirrors _push_upload_ready_unlocked. Must be called
// without state.mu held (it does a WS write).
func (s *server) pushUploadReadyUnlocked(session *Session, upload *PendingUpload) bool {
	s.state.mu.Lock()
	writer := session.AgentWriter
	s.state.mu.Unlock()
	if writer == nil {
		s.state.mu.Lock()
		queuePendingNotificationLocked(session, upload.UploadID)
		s.state.mu.Unlock()
		return false
	}
	if err := writer.writeText(uploadReadyFrame(upload)); err != nil {
		s.state.mu.Lock()
		queuePendingNotificationLocked(session, upload.UploadID)
		s.state.mu.Unlock()
		return false
	}
	return true
}

// drainPendingUploadReady mirrors _drain_pending_upload_ready.
func (s *server) drainPendingUploadReady(session *Session) {
	s.state.mu.Lock()
	pendingIDs := session.PendingReadyNotifications
	session.PendingReadyNotifications = nil
	var ready []*PendingUpload
	for _, id := range pendingIDs {
		u := session.PendingUploads[id]
		if u == nil || u.Delivered || u.Received != u.Size {
			continue
		}
		ready = append(ready, u)
	}
	s.state.mu.Unlock()
	for _, u := range ready {
		s.pushUploadReadyUnlocked(session, u)
	}
}

// removeUpload mirrors _remove_upload. Caller holds state.mu.
func removeUpload(session *Session, upload *PendingUpload, reason string) {
	delete(session.PendingUploads, upload.UploadID)
	if err := os.Remove(upload.Path); err != nil && !os.IsNotExist(err) {
		logEvent("upload_cleanup_failed",
			f("session_id", session.SessionID),
			f("upload_id", upload.UploadID),
			f("reason", reason),
			f("error", err.Error()),
		)
	}
}

// finalizeCompletedUpload mirrors _finalize_completed_upload. Returns
// "hash_mismatch" or "".
func (s *server) finalizeCompletedUpload(session *Session, upload *PendingUpload) string {
	digest := hex.EncodeToString(upload.hasher().Sum(nil))
	upload.SHA256Observed = digest

	if upload.HasSHA256 && digest != upload.SHA256 {
		s.state.mu.Lock()
		removeUpload(session, upload, "hash_mismatch")
		s.state.mu.Unlock()
		return "hash_mismatch"
	}

	s.state.mu.Lock()
	session.UploadedBytesTotal += upload.Size
	s.state.addMetric("upload_bytes_total", upload.Size)
	upload.Uploading = false
	s.state.mu.Unlock()

	s.pushUploadReadyUnlocked(session, upload)
	return ""
}

// findUploadLocked scans all sessions for an upload_id. Caller holds mu.
func (st *RelayState) findUploadLocked(uploadID string) (*PendingUpload, *Session) {
	for _, sess := range st.sessions {
		if u := sess.PendingUploads[uploadID]; u != nil {
			return u, sess
		}
	}
	return nil, nil
}

func (s *server) handleUploadInit(w http.ResponseWriter, r *http.Request, method string, body []byte) {
	st := s.state
	if method != http.MethodPost {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	st.incMetric("upload_init_total")

	token := bearerToken(r)
	if token == "" {
		st.incMetric("upload_init_rejected_total")
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("missing bearer token"))
		return
	}

	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var raw any
	if err := dec.Decode(&raw); err != nil {
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid json"))
		return
	}
	m, _ := raw.(map[string]any)

	sessionID, _ := m["session_id"].(string)
	name, nameOK := sanitizeUploadName(m["name"])

	if sessionID == "" || !nameOK {
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid payload"))
		return
	}

	// size must be a JSON integer > 0 (Python isinstance(size,int)).
	var size int64
	if n, ok := m["size"].(json.Number); ok {
		if v, err := n.Int64(); err == nil {
			size = v
		} else {
			st.incMetric("upload_init_rejected_total")
			writeJSON(w, r, 400, jsonError("invalid_size"))
			return
		}
	} else {
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid_size"))
		return
	}
	if size <= 0 {
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid_size"))
		return
	}
	if size > int64(st.config.UploadMaxBytes) {
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 413, jsonError("size_exceeds_limit"))
		return
	}

	var sha256 string
	hasSHA := false
	if shaRaw, present := m["sha256"]; present && shaRaw != nil {
		shaStr, ok := shaRaw.(string)
		if !ok || len(shaStr) != 64 || !isHex(shaStr) {
			st.incMetric("upload_init_rejected_total")
			writeJSON(w, r, 400, jsonError("invalid_sha256"))
			return
		}
		sha256 = strings.ToLower(shaStr)
		hasSHA = true
	}

	now := nowSec()
	var upload *PendingUpload
	st.mu.Lock()
	session := st.sessions[sessionID]
	if session == nil || session.UserToken != token {
		st.mu.Unlock()
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 404, jsonError("session_not_found"))
		return
	}
	if session.ExpiresAt <= now {
		st.mu.Unlock()
		st.incMetric("upload_init_rejected_total")
		st.incMetric("expired_session_rejected_total")
		writeJSON(w, r, 401, jsonError("expired session"))
		return
	}
	activePending := 0
	for _, u := range session.PendingUploads {
		if !u.Delivered {
			activePending++
		}
	}
	if activePending >= st.config.UploadMaxPending {
		st.mu.Unlock()
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 429, jsonError("too_many_pending"))
		return
	}
	globalPending := 0
	for _, sess := range st.sessions {
		for _, u := range sess.PendingUploads {
			if !u.Delivered {
				globalPending++
			}
		}
	}
	if globalPending >= st.config.UploadGlobalMaxPending {
		st.mu.Unlock()
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 429, jsonError("global_pending_full"))
		return
	}
	if session.UploadedBytesTotal+size > int64(st.config.UploadSessionMaxBytes) {
		st.mu.Unlock()
		st.incMetric("upload_init_rejected_total")
		writeJSON(w, r, 413, jsonError("size_exceeds_session_limit"))
		return
	}

	uploadID := tokenURLSafe(16)
	pullToken := tokenURLSafe(24)
	upload = &PendingUpload{
		UploadID:  uploadID,
		SessionID: sessionID,
		Name:      name,
		Size:      size,
		SHA256:    sha256,
		HasSHA256: hasSHA,
		PullToken: pullToken,
		Path:      stagingPath(st, uploadID),
		CreatedAt: now,
		ExpiresAt: now + st.config.UploadTTL,
	}
	session.PendingUploads[uploadID] = upload
	st.mu.Unlock()

	shaLog := ""
	if hasSHA {
		shaLog = sha256
	}
	logEvent("upload_init",
		f("session_id", sessionID), f("upload_id", upload.UploadID),
		f("name", name), f("size", size), f("sha256", shaLog),
	)
	writeJSON(w, r, 200, jsonBytes(map[string]any{
		"upload_id":       upload.UploadID,
		"upload_url":      "/api/upload/" + upload.UploadID,
		"expires_at":      int64(upload.ExpiresAt),
		"chunk_size":      defaultUploadPatchChunkBytes,
		"patch_max_bytes": defaultUploadPatchMaxBytes,
	}))
}

func (s *server) handleUploadPut(w http.ResponseWriter, r *http.Request, uploadID string) {
	st := s.state
	st.incMetric("upload_put_total")

	token := bearerToken(r)
	if token == "" {
		st.incMetric("upload_put_rejected_total")
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("missing bearer token"))
		return
	}
	declared, clOK := parseContentLength(r)
	if !clOK {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid_content_length"))
		return
	}

	st.mu.Lock()
	upload, owning := st.findUploadLocked(uploadID)
	if upload == nil {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 404, jsonError("not_found"))
		return
	}
	if owning.UserToken != token {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}
	if upload.Uploading || upload.Received > 0 || upload.Delivered {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 409, jsonError("already_uploaded"))
		return
	}
	if declared != upload.Size {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 409, jsonError("size_mismatch"))
		return
	}
	if upload.Size > int64(st.config.UploadMaxBytes) {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 413, jsonError("size_exceeds_limit"))
		return
	}
	upload.Uploading = true
	st.mu.Unlock()

	hasher := upload.hasher()
	n, err := streamToFile(upload.Path, false, r.Body, declared, hasher)
	st.mu.Lock()
	upload.Received = n
	st.mu.Unlock()
	if err != nil {
		st.incMetric("upload_put_rejected_total")
		st.mu.Lock()
		removeUpload(owning, upload, "put_aborted")
		st.mu.Unlock()
		logEvent("upload_put_aborted", f("session_id", owning.SessionID), f("upload_id", uploadID), f("error", err.Error()))
		writeJSON(w, r, 400, jsonError("incomplete_body"))
		return
	}

	if failure := s.finalizeCompletedUpload(owning, upload); failure == "hash_mismatch" {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 422, jsonError("hash_mismatch"))
		return
	}

	logEvent("upload_put", f("session_id", owning.SessionID), f("upload_id", uploadID), f("size", upload.Size), f("sha256", upload.SHA256Observed))
	writeJSON(w, r, 200, jsonBytes(map[string]any{
		"upload_id": uploadID,
		"received":  upload.Received,
		"sha256":    upload.SHA256Observed,
	}))
}

func (s *server) handleUploadHead(w http.ResponseWriter, r *http.Request, uploadID string) {
	st := s.state
	token := bearerToken(r)
	if token == "" {
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("missing bearer token"))
		return
	}
	st.mu.Lock()
	upload, owning := st.findUploadLocked(uploadID)
	if upload == nil {
		st.mu.Unlock()
		writeJSON(w, r, 404, jsonError("not_found"))
		return
	}
	if owning.UserToken != token {
		st.mu.Unlock()
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}
	offset := upload.Received
	total := upload.Size
	st.mu.Unlock()

	writeResponse(w, r, 200, []byte{}, "application/octet-stream", map[string]string{
		"Upload-Offset": i64toa(offset),
		"Upload-Length": i64toa(total),
		"Cache-Control": "no-store",
	})
}

func (s *server) handleUploadPatch(w http.ResponseWriter, r *http.Request, uploadID string) {
	st := s.state
	st.incMetric("upload_put_total") // shares the PUT counter family

	token := bearerToken(r)
	if token == "" {
		st.incMetric("upload_put_rejected_total")
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("missing bearer token"))
		return
	}

	contentType := strings.TrimSpace(strings.ToLower(strings.SplitN(r.Header.Get("Content-Type"), ";", 2)[0]))
	if contentType != "application/offset+octet-stream" {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 415, jsonError("invalid_content_type"))
		return
	}

	declared, clOK := parseContentLength(r)
	if !clOK {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid_content_length"))
		return
	}
	if declared <= 0 {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 400, jsonError("empty_chunk"))
		return
	}
	if declared > int64(defaultUploadPatchMaxBytes) {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 413, jsonError("chunk_too_large"))
		return
	}

	offsetStr := r.Header.Get("Upload-Offset")
	clientOffset, err := strconv.ParseInt(offsetStr, 10, 64)
	if err != nil {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid_upload_offset"))
		return
	}

	st.mu.Lock()
	upload, owning := st.findUploadLocked(uploadID)
	if upload == nil {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 404, jsonError("not_found"))
		return
	}
	if owning.UserToken != token {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}
	if upload.Delivered {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 409, jsonError("already_delivered"))
		return
	}
	if upload.Uploading {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 409, jsonError("concurrent_patch"))
		return
	}
	if clientOffset != upload.Received {
		received := upload.Received
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSONExtra(w, r, 409, jsonError("offset_mismatch"), map[string]string{"Upload-Offset": i64toa(received)})
		return
	}
	if upload.Received+declared > upload.Size {
		st.mu.Unlock()
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 413, jsonError("overshoot"))
		return
	}
	upload.Uploading = true
	appendMode := upload.Received != 0
	st.mu.Unlock()

	hasher := upload.hasher()
	n, err := streamToFile(upload.Path, appendMode, r.Body, declared, hasher)
	st.mu.Lock()
	upload.Received += n
	st.mu.Unlock()
	if err != nil {
		st.incMetric("upload_put_rejected_total")
		st.mu.Lock()
		upload.Uploading = false
		st.mu.Unlock()
		logEvent("upload_patch_aborted", f("session_id", owning.SessionID), f("upload_id", uploadID), f("offset", upload.Received), f("error", err.Error()))
		writeJSON(w, r, 400, jsonError("incomplete_chunk"))
		return
	}

	newOffset := upload.Received
	if newOffset < upload.Size {
		st.mu.Lock()
		upload.Uploading = false
		st.mu.Unlock()
		writeResponse(w, r, 204, []byte{}, "application/octet-stream", map[string]string{
			"Upload-Offset": i64toa(newOffset),
			"Cache-Control": "no-store",
		})
		return
	}

	if failure := s.finalizeCompletedUpload(owning, upload); failure == "hash_mismatch" {
		st.incMetric("upload_put_rejected_total")
		writeJSON(w, r, 422, jsonError("hash_mismatch"))
		return
	}

	logEvent("upload_patch_complete", f("session_id", owning.SessionID), f("upload_id", uploadID), f("size", upload.Size), f("sha256", upload.SHA256Observed))
	writeJSONExtra(w, r, 200, jsonBytes(map[string]any{
		"upload_id": uploadID,
		"received":  upload.Received,
		"sha256":    upload.SHA256Observed,
	}), map[string]string{"Upload-Offset": i64toa(newOffset)})
}

func (s *server) handleUploadPull(w http.ResponseWriter, r *http.Request, method string, query url.Values, uploadID string) {
	st := s.state
	if method != http.MethodGet {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	st.incMetric("upload_pull_total")

	pullToken := firstQuery(query, "token")
	if pullToken == "" {
		pullToken = bearerToken(r)
	}
	if pullToken == "" {
		st.incMetric("upload_pull_rejected_total")
		writeJSON(w, r, 403, jsonError("invalid_token"))
		return
	}

	st.mu.Lock()
	upload, owning := st.findUploadLocked(uploadID)
	if upload == nil {
		st.mu.Unlock()
		st.incMetric("upload_pull_rejected_total")
		writeJSON(w, r, 404, jsonError("not_found"))
		return
	}
	if upload.Delivered {
		st.mu.Unlock()
		st.incMetric("upload_pull_rejected_total")
		writeJSON(w, r, 410, jsonError("gone"))
		return
	}
	if subtle.ConstantTimeCompare([]byte(pullToken), []byte(upload.PullToken)) != 1 {
		st.mu.Unlock()
		st.incMetric("upload_pull_rejected_total")
		writeJSON(w, r, 403, jsonError("invalid_token"))
		return
	}
	if upload.Received != upload.Size {
		st.mu.Unlock()
		st.incMetric("upload_pull_rejected_total")
		writeJSON(w, r, 409, jsonError("not_complete"))
		return
	}
	upload.Delivered = true
	st.mu.Unlock()

	data, err := os.ReadFile(upload.Path)
	if err != nil {
		st.incMetric("upload_pull_rejected_total")
		logEvent("upload_pull_failed", f("session_id", owning.SessionID), f("upload_id", uploadID), f("error", err.Error()))
		st.mu.Lock()
		removeUpload(owning, upload, "read_failed")
		st.mu.Unlock()
		writeJSON(w, r, 500, jsonError("read_failed"))
		return
	}

	writeResponse(w, r, 200, data, "application/octet-stream", map[string]string{
		"X-Ghostty-Upload-Name":   quoteAll(upload.Name),
		"X-Ghostty-Upload-SHA256": upload.SHA256Observed,
	})
	// finally: always remove the staging file.
	st.mu.Lock()
	removeUpload(owning, upload, "pulled")
	st.mu.Unlock()

	logEvent("upload_pull", f("session_id", owning.SessionID), f("upload_id", uploadID), f("size", upload.Size))
}

// streamToFile copies exactly `declared` bytes from src to the file (create or
// append), feeding the hasher. Returns bytes written.
func streamToFile(path string, appendMode bool, src io.Reader, declared int64, hasher io.Writer) (int64, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 0, err
	}
	flag := os.O_WRONLY | os.O_CREATE | os.O_TRUNC
	if appendMode {
		flag = os.O_WRONLY | os.O_CREATE | os.O_APPEND
	}
	fp, err := os.OpenFile(path, flag, 0o644)
	if err != nil {
		return 0, err
	}
	defer fp.Close()
	mw := io.MultiWriter(fp, hasher)
	n, err := io.CopyN(mw, src, declared)
	if err != nil {
		return n, err
	}
	return n, nil
}

func isHex(s string) bool {
	for _, ch := range strings.ToLower(s) {
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) {
			return false
		}
	}
	return true
}

// parseContentLength mirrors Python's int(headers.get("content-length", "0")):
// a missing header is 0, a syntactically invalid one is rejected. We parse the
// raw header instead of r.ContentLength so the invalid case stays observable
// (net/http coerces a malformed value to -1, masking it).
func parseContentLength(r *http.Request) (int64, bool) {
	raw := strings.TrimSpace(r.Header.Get("Content-Length"))
	if raw == "" {
		return 0, true
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}

// quoteAll mirrors urllib.parse.quote(value, safe=""): every byte outside the
// RFC3986 unreserved set is percent-encoded with uppercase hex. Unlike
// url.QueryEscape it encodes a space as %20 (not '+'), which matters because
// the agent decodes X-Ghostty-Upload-Name with percent-decoding.
func quoteAll(s string) string {
	const upperhex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(upperhex[c>>4])
		b.WriteByte(upperhex[c&0x0F])
	}
	return b.String()
}
