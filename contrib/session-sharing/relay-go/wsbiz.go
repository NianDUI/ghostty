package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"
)

func newGraceTimer() *graceTimer {
	return &graceTimer{cancel: make(chan struct{}), done: make(chan struct{})}
}

// ---- forwarding & backlog replay ----

// forwardToClientsLocked mirrors forward_to_clients. Caller holds state.mu.
func forwardToClientsLocked(session *Session, opcode int, payload []byte) {
	session.appendBacklog(opcode, payload)
	if opcode != opcodeText && opcode != opcodeBinary {
		return
	}
	for _, ch := range session.Clients {
		ch.tryEnqueue(opcode, payload)
	}
}

// replayBacklog mirrors replay_backlog: snapshot under lock, log, then
// enqueue to the fresh channel outside the lock.
func (s *server) replayBacklog(session *Session, channel *clientChannel) {
	s.state.mu.Lock()
	snap := session.snapshotBacklog()
	s.state.mu.Unlock()

	summary := make([]string, 0, len(snap))
	for _, e := range snap {
		kind := "bin"
		if e.opcode == opcodeText {
			kind = "txt"
			var m map[string]any
			if err := json.Unmarshal(e.payload, &m); err == nil {
				if t, ok := m["type"].(string); ok {
					kind = t
				}
			}
		}
		summary = append(summary, fmt.Sprintf("%s:%d", kind, len(e.payload)))
	}
	logEvent("replay_backlog",
		f("session_id", session.SessionID),
		f("entries", len(snap)),
		f("kinds", strings.Join(summary, ",")),
	)

	for _, e := range snap {
		if e.opcode == opcodeText || e.opcode == opcodeBinary {
			channel.tryEnqueue(e.opcode, e.payload)
		}
	}
}

// clientSender mirrors client_sender: drain the queue to the socket; a drop
// sentinel closes the socket with the slow-consumer code.
func (s *server) clientSender(channel *clientChannel, sessionID string) {
	for {
		item, ok := channel.dequeue()
		if !ok {
			return
		}
		if item.drop {
			s.state.incMetric("slow_consumer_drop_total")
			channel.mu.Lock()
			qb := channel.queuedBytes
			channel.mu.Unlock()
			logEvent("slow_consumer_drop",
				f("session_id", sessionID),
				f("queued_bytes", qb),
				f("max_bytes", channel.maxBytes),
			)
			channel.conn.closeWithCode(closeWSTimeout, "slow_consumer")
			return
		}
		var err error
		if item.opcode == opcodeText {
			err = channel.conn.writeText(sanitizeUTF8(item.payload))
		} else if item.opcode == opcodeBinary {
			err = channel.conn.writeBinary(item.payload)
		}
		channel.drainBytes(len(item.payload))
		if err != nil {
			return
		}
	}
}

// ---- name_update control frame ----

// handleNameUpdateLocked mirrors _handle_name_update. Caller holds state.mu.
// Returns true when the frame was consumed (skip forward + backlog).
func handleNameUpdateLocked(st *RelayState, session *Session, payload []byte) bool {
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		return false
	}
	t, _ := m["type"].(string)
	if t != "name_update" {
		return false
	}
	newName, ok := m["name"].(string)
	if !ok || utf8.RuneCountInString(newName) > nameUpdateMaxLength {
		// Malformed: consume but don't touch name.
		return true
	}
	if session.Name != newName {
		session.Name = newName
		st.incMetric("name_update_total")
		logEvent("name_update",
			f("session_id", session.SessionID),
			f("name_length", utf8.RuneCountInString(newName)),
		)
	}
	return true
}

// ---- agent endpoint ----

func (s *server) handleWSAgent(w http.ResponseWriter, r *http.Request, query url.Values) {
	st := s.state
	sessionID := firstQuery(query, "id")
	token := bearerToken(r)
	if sessionID == "" || token == "" {
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("missing agent credentials"))
		return
	}

	st.mu.Lock()
	session := st.sessions[sessionID]
	if session == nil || session.AgentToken != token {
		st.mu.Unlock()
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid agent token"))
		return
	}
	if session.ExpiresAt <= nowSec() {
		st.mu.Unlock()
		st.incMetric("auth_rejected_total")
		st.incMetric("expired_session_rejected_total")
		writeJSON(w, r, 401, jsonError("expired agent token"))
		return
	}
	st.mu.Unlock()

	raw, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return // gorilla already wrote an error response
	}
	conn := newWSConn(raw)

	// Register the agent now that we have a live conn.
	st.mu.Lock()
	session.Online = true
	session.LastSeenAt = nowSec()
	session.AgentWriter = conn
	graceToCancel := session.disconnectGrace
	session.disconnectGrace = nil
	st.mu.Unlock()

	if graceToCancel != nil {
		graceToCancel.Cancel()
		<-graceToCancel.done
		st.incMetric("agent_grace_canceled_total")
		logEvent("agent_grace_canceled", f("session_id", session.SessionID))
	}

	st.incMetric("agent_connect_total")
	logEvent("agent_connected", f("session_id", session.SessionID))

	s.drainPendingUploadReady(session)

	pong := newPongTracker()
	conn.conn.SetReadLimit(int64(s.config.MaxFrameBytes))
	conn.installHeartbeatHandlers(st, session, pong)

	stop := make(chan struct{})
	go watchTokenExpiry(st, session, conn, s.config.TokenExpiryCheckSeconds, stop)
	go watchHeartbeat(conn, pong, s.config.PingIntervalSeconds, s.config.PingTimeoutSeconds, stop)

	s.wsAgentLoop(session, conn)

	close(stop)
	s.agentDisconnected(session, conn)
}

func (s *server) wsAgentLoop(session *Session, conn *wsConn) {
	st := s.state
	for {
		msgType, payload, err := conn.conn.ReadMessage()
		if err != nil {
			return
		}
		st.mu.Lock()
		session.LastSeenAt = nowSec()
		if msgType == opcodeText && handleNameUpdateLocked(st, session, payload) {
			st.mu.Unlock()
			continue
		}
		if msgType == opcodeText || msgType == opcodeBinary {
			forwardToClientsLocked(session, msgType, payload)
		}
		st.mu.Unlock()
	}
}

// agentDisconnected mirrors the finally block of handle_ws_agent's loop
// (PORT-SPEC §21.2).
func (s *server) agentDisconnected(session *Session, conn *wsConn) {
	st := s.state
	st.mu.Lock()
	session.Online = false
	if session.AgentWriter == conn {
		session.AgentWriter = nil
	}
	session.LastSeenAt = nowSec()
	clientCount := len(session.Clients)
	st.mu.Unlock()

	st.incMetric("agent_disconnect_total")
	logEvent("agent_disconnected", f("session_id", session.SessionID), f("client_count", clientCount))

	graceSeconds := s.config.AgentDisconnectGraceSeconds
	if clientCount > 0 && graceSeconds > 0 {
		st.mu.Lock()
		previous := session.disconnectGrace
		gt := newGraceTimer()
		session.disconnectGrace = gt
		st.mu.Unlock()
		go s.expireAgentGrace(session, gt)
		if previous != nil {
			previous.Cancel()
		}
		st.incMetric("agent_grace_started_total")
		logEvent("agent_grace_started",
			f("session_id", session.SessionID),
			f("client_count", clientCount),
			f("seconds", graceSeconds),
		)
	} else {
		st.mu.Lock()
		stale := make([]*wsConn, 0, len(session.Clients))
		for c := range session.Clients {
			stale = append(stale, c)
		}
		session.Clients = map[*wsConn]*clientChannel{}
		st.mu.Unlock()
		for _, c := range stale {
			c.close()
		}
	}
	conn.close()
}

// expireAgentGrace mirrors _expire_agent_grace.
func (s *server) expireAgentGrace(session *Session, gt *graceTimer) {
	st := s.state
	select {
	case <-gt.cancel:
		close(gt.done)
		return
	case <-time.After(secDuration(s.config.AgentDisconnectGraceSeconds)):
	}
	st.mu.Lock()
	if session.AgentWriter != nil {
		// Reconnect already landed; leave clients alone.
		session.disconnectGrace = nil
		st.mu.Unlock()
		close(gt.done)
		return
	}
	clients := make([]*wsConn, 0, len(session.Clients))
	for c := range session.Clients {
		clients = append(clients, c)
	}
	session.Clients = map[*wsConn]*clientChannel{}
	session.disconnectGrace = nil
	st.mu.Unlock()

	st.incMetric("agent_grace_expired_total")
	logEvent("agent_grace_expired", f("session_id", session.SessionID), f("dropped_clients", len(clients)))
	for _, c := range clients {
		c.close()
	}
	close(gt.done)
}

// ---- client endpoint ----

func (s *server) handleWSClient(w http.ResponseWriter, r *http.Request, query url.Values) {
	st := s.state
	sessionID := firstQuery(query, "id")
	queryToken := firstQuery(query, "token")
	token := queryToken
	if token == "" {
		token = bearerToken(r)
	}
	if sessionID == "" || token == "" {
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("missing client credentials"))
		return
	}

	st.mu.Lock()
	session := st.sessions[sessionID]
	if session == nil {
		st.mu.Unlock()
		writeJSON(w, r, 404, jsonError("session not found"))
		return
	}
	if session.ExpiresAt <= nowSec() {
		st.mu.Unlock()
		st.incMetric("auth_rejected_total")
		st.incMetric("expired_session_rejected_total")
		writeJSON(w, r, 401, jsonError("expired client token"))
		return
	}
	usingUserToken := token == session.UserToken
	if usingUserToken && !s.config.AllowUserTokenClientAccess {
		st.mu.Unlock()
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("user token client access disabled"))
		return
	}
	if usingUserToken && !st.isValidUserToken(token) {
		st.mu.Unlock()
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}
	if token != session.ClientToken && token != session.UserToken {
		st.mu.Unlock()
		st.incMetric("auth_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid client token"))
		return
	}
	if len(session.Clients) >= s.config.MaxClientsPerSession {
		st.mu.Unlock()
		writeJSON(w, r, 503, jsonError("client capacity reached"))
		return
	}
	st.mu.Unlock()

	raw, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn := newWSConn(raw)

	channel := newClientChannel(conn, s.config.ClientSendBufferBytes)
	st.mu.Lock()
	session.Clients[conn] = channel
	session.LastSeenAt = nowSec()
	clientCount := len(session.Clients)
	st.mu.Unlock()

	st.incMetric("client_connect_total")
	logEvent("client_connected", f("session_id", session.SessionID), f("client_count", clientCount))

	stop := make(chan struct{})
	go s.clientSender(channel, session.SessionID)

	s.replayBacklog(session, channel)

	// Tell the agent a fresh viewer joined (old agents ignore it).
	st.mu.Lock()
	agentWriter := session.AgentWriter
	st.mu.Unlock()
	if agentWriter != nil {
		_ = agentWriter.writeText(jsonBytes(map[string]any{"type": "client_connected"}))
	}

	pong := newPongTracker()
	conn.conn.SetReadLimit(int64(s.config.MaxFrameBytes))
	conn.installHeartbeatHandlers(st, session, pong)

	go watchTokenExpiry(st, session, conn, s.config.TokenExpiryCheckSeconds, stop)
	go watchHeartbeat(conn, pong, s.config.PingIntervalSeconds, s.config.PingTimeoutSeconds, stop)

	s.wsClientLoop(session, conn)

	close(stop)
	channel.shutdown()
}

func (s *server) wsClientLoop(session *Session, conn *wsConn) {
	st := s.state
	for {
		msgType, payload, err := conn.conn.ReadMessage()
		if err != nil {
			break
		}
		st.mu.Lock()
		session.LastSeenAt = nowSec()
		agentWriter := session.AgentWriter
		st.mu.Unlock()
		if agentWriter == nil {
			continue
		}
		if msgType == opcodeText {
			_ = agentWriter.writeText(sanitizeUTF8(payload))
		} else if msgType == opcodeBinary {
			_ = agentWriter.writeBinary(payload)
		}
	}

	// finally (PORT-SPEC §21.6).
	st.mu.Lock()
	delete(session.Clients, conn)
	remaining := len(session.Clients)
	agentWriter := session.AgentWriter
	st.mu.Unlock()

	st.incMetric("client_disconnect_total")
	logEvent("client_disconnected", f("session_id", session.SessionID), f("remaining_clients", remaining))

	if remaining == 0 && agentWriter != nil {
		_ = agentWriter.writeText(jsonBytes(map[string]any{"type": "client_disconnect"}))
	}
	conn.close()
}
