package main

import (
	"bytes"
	"net/url"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// waitMetric polls until a counter reaches want (or fails after a deadline).
func waitMetric(t *testing.T, st *RelayState, name string, want int64) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if metricValue(st, name) >= want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s did not reach %d (got %d)", name, want, metricValue(st, name))
}

// readCloseCode drains a WS conn until it errors and returns the close code
// (0 if the error was not a CloseError).
func readCloseCode(c *websocket.Conn, within time.Duration) int {
	_ = c.SetReadDeadline(time.Now().Add(within))
	for {
		if _, _, err := c.ReadMessage(); err != nil {
			if ce, ok := err.(*websocket.CloseError); ok {
				return ce.Code
			}
			return 0
		}
	}
}

// ---- binary frame forwarding (writeBinary, both directions) ----

func TestWSForwardBinaryAgentToClient(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "bin1", "Box", "user-tok")
	agent := dialAgent(t, ts, "bin1", reg.AgentToken)
	client := dialClient(t, ts, "bin1", reg.ClientToken)
	time.Sleep(50 * time.Millisecond)

	payload := []byte{0x00, 0x01, 0x02, 0xff, 0xfe}
	if err := agent.WriteMessage(websocket.BinaryMessage, payload); err != nil {
		t.Fatalf("agent write: %v", err)
	}
	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	mt, data, err := client.ReadMessage()
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	if mt != websocket.BinaryMessage {
		t.Errorf("message type=%d, want binary(%d)", mt, websocket.BinaryMessage)
	}
	if !bytes.Equal(data, payload) {
		t.Errorf("client got %v, want %v", data, payload)
	}
}

func TestWSForwardBinaryClientToAgent(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "bin2", "Box", "user-tok")
	agent := dialAgent(t, ts, "bin2", reg.AgentToken)
	client := dialClient(t, ts, "bin2", reg.ClientToken)
	time.Sleep(50 * time.Millisecond)

	payload := []byte{0xde, 0xad, 0xbe, 0xef}
	if err := client.WriteMessage(websocket.BinaryMessage, payload); err != nil {
		t.Fatalf("client write: %v", err)
	}
	// The agent first receives the {"type":"client_connected"} text control
	// frame the relay emits when a viewer joins; skip text frames until the
	// forwarded binary arrives.
	_ = agent.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		mt, data, err := agent.ReadMessage()
		if err != nil {
			t.Fatalf("agent read: %v", err)
		}
		if mt == websocket.TextMessage {
			continue
		}
		if mt != websocket.BinaryMessage || !bytes.Equal(data, payload) {
			t.Errorf("agent got mt=%d %v, want binary %v", mt, data, payload)
		}
		break
	}
}

// ---- 4401 token expiry (watchTokenExpiry) ----

func TestWSTokenExpiryCloses4401(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.TokenTTL = 0.5
	cfg.TokenExpiryCheckSeconds = 0.05
	ts, _ := newTestServer(t, cfg)
	reg := registerSession(t, ts, "exp4401", "Box", "user-tok")
	client := dialClient(t, ts, "exp4401", reg.ClientToken)

	if code := readCloseCode(client, 3*time.Second); code != closeTokenExpired {
		t.Errorf("close code=%d, want %d (4401 token_expired)", code, closeTokenExpired)
	}
}

// ---- 4408 ping timeout (watchHeartbeat) ----

func TestWSHeartbeatTimeoutCloses4408(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.PingIntervalSeconds = 0.05
	cfg.PingTimeoutSeconds = 0.15
	ts, _ := newTestServer(t, cfg)
	reg := registerSession(t, ts, "hb4408", "Box", "user-tok")

	// Dial manually so we can swallow server pings and never pong.
	q := url.Values{"id": {"hb4408"}, "token": {reg.ClientToken}}
	c, _, err := websocket.DefaultDialer.Dial(wsURL(ts, "/ws/client", q), nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	c.SetPingHandler(func(string) error { return nil }) // never reply with a pong

	if code := readCloseCode(c, 3*time.Second); code != closeWSTimeout {
		t.Errorf("close code=%d, want %d (4408 ping_timeout)", code, closeWSTimeout)
	}
}

// ---- LastSeenAt refreshed by pong (installHeartbeatHandlers) ----

func TestWSHeartbeatRefreshesLastSeen(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.PingIntervalSeconds = 0.05
	cfg.PingTimeoutSeconds = 10 // long, so the conn stays up
	ts, st := newTestServer(t, cfg)
	reg := registerSession(t, ts, "lastseen", "Box", "user-tok")
	client := dialClient(t, ts, "lastseen", reg.ClientToken)

	// The client must be reading for gorilla to auto-reply to server pings.
	go func() {
		for {
			if _, _, err := client.ReadMessage(); err != nil {
				return
			}
		}
	}()

	st.mu.Lock()
	before := st.sessions["lastseen"].LastSeenAt
	st.mu.Unlock()

	time.Sleep(300 * time.Millisecond)

	st.mu.Lock()
	after := st.sessions["lastseen"].LastSeenAt
	st.mu.Unlock()

	// No data frames were sent; LastSeenAt can only have advanced via the pong
	// handler, which is exactly the behaviour we added.
	if !(after > before) {
		t.Errorf("LastSeenAt not refreshed by pong: before=%f after=%f", before, after)
	}
}

// ---- server handles a client-initiated ping (pong + ping handler) ----

func TestWSClientPingHandledByServer(t *testing.T) {
	cfg := newTestConfig(t) // server sends no pings of its own (interval 0)
	ts, st := newTestServer(t, cfg)
	reg := registerSession(t, ts, "cping", "Box", "user-tok")
	client := dialClient(t, ts, "cping", reg.ClientToken)

	gotPong := make(chan struct{}, 1)
	client.SetPongHandler(func(string) error {
		select {
		case gotPong <- struct{}{}:
		default:
		}
		return nil
	})
	// Drive the client read loop so gorilla processes the server's pong reply.
	go func() {
		_ = client.SetReadDeadline(time.Now().Add(3 * time.Second))
		for {
			if _, _, err := client.ReadMessage(); err != nil {
				return
			}
		}
	}()

	st.mu.Lock()
	before := st.sessions["cping"].LastSeenAt
	st.mu.Unlock()
	time.Sleep(20 * time.Millisecond)

	// Client sends a ping; the server's ping handler must refresh LastSeenAt
	// and reply with a pong.
	if err := client.WriteControl(websocket.PingMessage, []byte("ping-payload"), time.Now().Add(time.Second)); err != nil {
		t.Fatalf("write ping: %v", err)
	}

	select {
	case <-gotPong:
	case <-time.After(2 * time.Second):
		t.Fatal("server did not reply to client ping with a pong")
	}
	st.mu.Lock()
	after := st.sessions["cping"].LastSeenAt
	st.mu.Unlock()
	if after < before {
		t.Errorf("LastSeenAt went backwards: before=%f after=%f", before, after)
	}
}

// ---- agent disconnect grace lifecycle (expireAgentGrace) ----

func TestAgentGraceExpiredDropsClients(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.AgentDisconnectGraceSeconds = 0.3
	ts, st := newTestServer(t, cfg)
	reg := registerSession(t, ts, "grace-exp", "Box", "user-tok")

	agent := dialAgent(t, ts, "grace-exp", reg.AgentToken)
	client := dialClient(t, ts, "grace-exp", reg.ClientToken)
	time.Sleep(50 * time.Millisecond)

	// Agent drops while a client is attached -> grace starts, client lingers.
	_ = agent.Close()

	// The client must eventually be force-closed once the grace window expires.
	_ = readCloseCode(client, 3*time.Second)

	waitMetric(t, st, "agent_grace_started_total", 1)
	waitMetric(t, st, "agent_grace_expired_total", 1)
}

func TestAgentGraceCanceledOnReconnect(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.AgentDisconnectGraceSeconds = 2 // long enough to reconnect within
	ts, st := newTestServer(t, cfg)
	reg := registerSession(t, ts, "grace-cxl", "Box", "user-tok")

	agent := dialAgent(t, ts, "grace-cxl", reg.AgentToken)
	client := dialClient(t, ts, "grace-cxl", reg.ClientToken)

	closed := make(chan int, 1)
	go func() { closed <- readCloseCode(client, 5*time.Second) }()
	time.Sleep(50 * time.Millisecond)

	// Agent drops -> grace starts.
	_ = agent.Close()
	waitMetric(t, st, "agent_grace_started_total", 1)

	// Reconnect within the grace window -> grace canceled, client kept.
	time.Sleep(100 * time.Millisecond)
	agent2 := dialAgent(t, ts, "grace-cxl", reg.AgentToken)
	_ = agent2
	waitMetric(t, st, "agent_grace_canceled_total", 1)

	select {
	case code := <-closed:
		t.Errorf("client was closed (code %d) despite agent reconnect within grace", code)
	case <-time.After(400 * time.Millisecond):
		// good — client stayed attached
	}
}
