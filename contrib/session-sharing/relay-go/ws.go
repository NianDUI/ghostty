package main

import (
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// Application WebSocket close codes (PORT-SPEC §7).
const (
	closeTokenExpired = 4401
	closeWSTimeout    = 4408 // ping_timeout and slow_consumer both use this
)

// upgrader does not validate Origin (server.py's handshake ignores it).
var upgrader = websocket.Upgrader{
	CheckOrigin: func(*http.Request) bool { return true },
}

// wsConn wraps a gorilla connection with a write mutex so multiple goroutines
// (forwarder, heartbeat ping, upload_ready, control notifications) never write
// concurrently — gorilla forbids concurrent writers (PORT-SPEC §25.6).
type wsConn struct {
	conn *websocket.Conn
	wmu  sync.Mutex
}

func newWSConn(c *websocket.Conn) *wsConn { return &wsConn{conn: c} }

const wsWriteDeadline = 10 * time.Second

func (c *wsConn) writeText(b []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return c.conn.WriteMessage(websocket.TextMessage, b)
}

func (c *wsConn) writeBinary(b []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return c.conn.WriteMessage(websocket.BinaryMessage, b)
}

func (c *wsConn) writeFrame(opcode int, payload []byte) error {
	if opcode == opcodeText {
		return c.writeText(payload)
	}
	return c.writeBinary(payload)
}

func (c *wsConn) ping() error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return c.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(wsWriteDeadline))
}

func (c *wsConn) pong(payload []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return c.conn.WriteControl(websocket.PongMessage, payload, time.Now().Add(wsWriteDeadline))
}

// installHeartbeatHandlers wires gorilla's ping/pong handlers so that the pong
// tracker is refreshed on every pong and session.LastSeenAt is refreshed on
// every ping/pong. server.py updates last_seen on *every* frame including
// control frames, but gorilla's ReadMessage hides ping/pong from the read loop,
// so we hook the handlers here. The ping handler also replies with a pong,
// preserving gorilla's default behaviour (and its error handling).
func (c *wsConn) installHeartbeatHandlers(st *RelayState, session *Session, pong *pongTracker) {
	c.conn.SetPongHandler(func(string) error {
		pong.mark()
		st.mu.Lock()
		session.LastSeenAt = nowSec()
		st.mu.Unlock()
		return nil
	})
	c.conn.SetPingHandler(func(message string) error {
		st.mu.Lock()
		session.LastSeenAt = nowSec()
		st.mu.Unlock()
		err := c.pong([]byte(message))
		if err == websocket.ErrCloseSent {
			return nil
		}
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return nil
		}
		return err
	})
}

// close mirrors ws_close: send an empty close frame, then close the socket.
func (c *wsConn) close() {
	c.wmu.Lock()
	_ = c.conn.WriteControl(websocket.CloseMessage, []byte{}, time.Now().Add(wsWriteDeadline))
	c.wmu.Unlock()
	_ = c.conn.Close()
}

// closeWithCode mirrors ws_close_with_code: send a close frame carrying a
// 2-byte code + reason, then close the socket. Failures are swallowed.
func (c *wsConn) closeWithCode(code int, reason string) {
	c.wmu.Lock()
	_ = c.conn.WriteControl(
		websocket.CloseMessage,
		websocket.FormatCloseMessage(code, reason),
		time.Now().Add(wsWriteDeadline),
	)
	c.wmu.Unlock()
	_ = c.conn.Close()
}

// pongTracker holds the last-pong timestamp, updated by the PongHandler.
type pongTracker struct{ ns atomic.Int64 }

func newPongTracker() *pongTracker {
	p := &pongTracker{}
	p.mark()
	return p
}
func (p *pongTracker) mark()            { p.ns.Store(time.Now().UnixNano()) }
func (p *pongTracker) lastSec() float64 { return float64(p.ns.Load()) / 1e9 }

func secDuration(sec float64) time.Duration {
	return time.Duration(sec * float64(time.Second))
}

// watchTokenExpiry mirrors watch_token_expiry: close 4401 once the session's
// token expires. Stops when stop is closed.
func watchTokenExpiry(state *RelayState, session *Session, conn *wsConn, interval float64, stop <-chan struct{}) {
	if interval <= 0 {
		return
	}
	ticker := time.NewTicker(secDuration(interval))
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
		}
		state.mu.Lock()
		exp := session.ExpiresAt
		state.mu.Unlock()
		if exp <= nowSec() {
			conn.closeWithCode(closeTokenExpired, "token_expired")
			return
		}
	}
}

// watchHeartbeat mirrors watch_heartbeat: every interval, close 4408 if no
// pong within timeout, else send a ping.
func watchHeartbeat(conn *wsConn, pong *pongTracker, interval, timeout float64, stop <-chan struct{}) {
	if interval <= 0 || timeout <= 0 {
		return
	}
	ticker := time.NewTicker(secDuration(interval))
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
		}
		if nowSec()-pong.lastSec() > timeout {
			conn.closeWithCode(closeWSTimeout, "ping_timeout")
			return
		}
		if err := conn.ping(); err != nil {
			return
		}
	}
}
