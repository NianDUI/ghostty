package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"unicode/utf8"
)

// toStr mirrors Python's str() coercion of a JSON value.
func toStr(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

func (s *server) handleRegister(w http.ResponseWriter, r *http.Request, method string, body []byte) {
	st := s.state
	if method != http.MethodPost {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	st.incMetric("register_requests_total")

	var raw any
	if err := json.Unmarshal(body, &raw); err != nil {
		writeJSON(w, r, 400, jsonError("invalid json"))
		return
	}
	m, ok := raw.(map[string]any)
	if !ok {
		writeJSON(w, r, 400, jsonError("invalid json"))
		return
	}
	sidV, ok1 := m["session_id"]
	nameV, ok2 := m["name"]
	tokenV, ok3 := m["token"]
	if !ok1 || !ok2 || !ok3 {
		writeJSON(w, r, 400, jsonError("invalid json"))
		return
	}
	sessionID := toStr(sidV)
	name := toStr(nameV)
	token := toStr(tokenV)

	if sessionID == "" || utf8.RuneCountInString(sessionID) > 128 ||
		utf8.RuneCountInString(name) > 256 ||
		token == "" || utf8.RuneCountInString(token) > 1024 {
		st.incMetric("register_rejected_total")
		writeJSON(w, r, 400, jsonError("invalid payload"))
		return
	}
	if !st.isValidUserToken(token) {
		st.incMetric("register_rejected_total")
		st.incMetric("auth_rejected_total")
		logEvent("register_rejected", f("reason", "invalid_user_token"), f("session_id", sessionID))
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}

	now := nowSec()
	var (
		respSID, respAgent, respClient string
		respExpires                    float64
		reused                         bool
	)
	st.mu.Lock()
	existing := st.sessions[sessionID]
	if existing == nil && len(st.sessions) >= st.config.MaxSessions {
		st.mu.Unlock()
		st.incMetric("register_rejected_total")
		writeJSON(w, r, 503, jsonError("session capacity reached"))
		return
	}
	var sess *Session
	if existing != nil {
		// Re-register / reconnect: rotate tokens, refresh TTL, but preserve
		// name (unless a non-empty override) and the accumulated backlog.
		existing.UserToken = token
		existing.AgentToken = tokenURLSafe(24)
		existing.ClientToken = tokenURLSafe(24)
		existing.ExpiresAt = now + st.config.TokenTTL
		existing.LastSeenAt = now
		existing.Online = false
		if name != "" {
			existing.Name = name
		}
		sess = existing
		reused = true
	} else {
		sess = newSession()
		sess.SessionID = sessionID
		sess.Name = name
		sess.UserToken = token
		sess.AgentToken = tokenURLSafe(24)
		sess.ClientToken = tokenURLSafe(24)
		sess.ExpiresAt = now + st.config.TokenTTL
		sess.Online = false
		sess.LastSeenAt = now
		st.sessions[sessionID] = sess
	}
	respSID = sess.SessionID
	respAgent = sess.AgentToken
	respClient = sess.ClientToken
	respExpires = sess.ExpiresAt
	st.mu.Unlock()

	if reused {
		st.incMetric("register_reused_total")
	}
	logEvent("register",
		f("session_id", sessionID),
		f("name_length", utf8.RuneCountInString(name)),
		f("online", false),
		f("reused", reused),
	)

	writeJSON(w, r, 200, jsonBytes(map[string]any{
		"session_id":   respSID,
		"agent_token":  respAgent,
		"client_token": respClient,
		"expires_at":   utcStamp(respExpires),
	}))
}

func (s *server) handleSessions(w http.ResponseWriter, r *http.Request, method string) {
	st := s.state
	if method != http.MethodGet {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	token := bearerToken(r)
	if token == "" {
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("missing bearer token"))
		return
	}
	if !st.isValidUserToken(token) {
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}

	now := nowSec()
	out := []map[string]any{}
	st.mu.Lock()
	for _, sess := range st.sessions {
		if sess.UserToken == token && sess.ExpiresAt > now {
			out = append(out, map[string]any{
				"id":           sess.SessionID,
				"name":         sess.Name,
				"online":       sess.Online,
				"last_seen_at": utcStamp(sess.LastSeenAt),
				"client_token": sess.ClientToken,
			})
		}
	}
	st.mu.Unlock()

	writeJSON(w, r, 200, jsonBytes(out))
}
