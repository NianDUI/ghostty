package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// ---- 11. WS agent+client forwarding & backlog ----

func TestWSForwardAgentToClient(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "ws1", "Box", "user-tok")

	agent := dialAgent(t, ts, "ws1", reg.AgentToken)
	client := dialClient(t, ts, "ws1", reg.ClientToken)

	// Give the client sender goroutine a moment to attach.
	time.Sleep(50 * time.Millisecond)

	if err := agent.WriteMessage(websocket.TextMessage, []byte("hello-frame")); err != nil {
		t.Fatalf("agent write: %v", err)
	}
	_, data := readText(t, client, 2*time.Second)
	if string(data) != "hello-frame" {
		t.Errorf("client got %q, want hello-frame", data)
	}
}

func TestWSBacklogReplay(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "ws2", "Box", "user-tok")

	agent := dialAgent(t, ts, "ws2", reg.AgentToken)
	// Agent emits frames before any client connects.
	_ = agent.WriteMessage(websocket.TextMessage, []byte(`{"type":"hello","cols":80}`))
	_ = agent.WriteMessage(websocket.TextMessage, []byte("plain-output"))
	time.Sleep(50 * time.Millisecond)

	// New client should replay both backlog frames.
	client := dialClient(t, ts, "ws2", reg.ClientToken)
	got := map[string]bool{}
	for i := 0; i < 2; i++ {
		_, data := readText(t, client, 2*time.Second)
		got[string(data)] = true
	}
	if !got[`{"type":"hello","cols":80}`] || !got["plain-output"] {
		t.Errorf("backlog replay incomplete: %v", got)
	}
}

func TestWSBacklogScreenKeepsHello(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "ws3", "Box", "user-tok")

	agent := dialAgent(t, ts, "ws3", reg.AgentToken)
	// hello (essential) then a screen snapshot. The snapshot trims earlier
	// frames but must preserve essential metadata (hello).
	_ = agent.WriteMessage(websocket.TextMessage, []byte(`{"type":"hello","cols":80}`))
	_ = agent.WriteMessage(websocket.TextMessage, []byte(`{"type":"screen","data":"x"}`))
	time.Sleep(50 * time.Millisecond)

	client := dialClient(t, ts, "ws3", reg.ClientToken)
	sawHello := false
	sawScreen := false
	for i := 0; i < 2; i++ {
		_, data := readText(t, client, 2*time.Second)
		var m map[string]any
		_ = json.Unmarshal(data, &m)
		switch m["type"] {
		case "hello":
			sawHello = true
		case "screen":
			sawScreen = true
		}
	}
	if !sawHello {
		t.Errorf("hello not preserved across screen snapshot")
	}
	if !sawScreen {
		t.Errorf("screen snapshot not replayed")
	}
}

func TestWSAgentAuthFailure(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "wsa", "Box", "user-tok")

	q := url.Values{"id": {"wsa"}}
	hdr := http.Header{"Authorization": {"Bearer wrong-token"}}
	_, resp, err := websocket.DefaultDialer.Dial(wsURL(ts, "/ws/agent", q), hdr)
	if err == nil {
		t.Fatal("expected dial failure")
	}
	if resp == nil || resp.StatusCode != 401 {
		t.Fatalf("status=%v, want 401", resp)
	}
	_ = reg
}

func TestWSClientWrongToken(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "wsc", "Box", "user-tok")

	q := url.Values{"id": {"wsc"}, "token": {"bad-client-token"}}
	_, resp, err := websocket.DefaultDialer.Dial(wsURL(ts, "/ws/client", q), nil)
	if err == nil {
		t.Fatal("expected dial failure")
	}
	if resp == nil || resp.StatusCode != 401 {
		t.Fatalf("status=%v, want 401", resp)
	}
}

func TestWSClientSessionNotFound(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	q := url.Values{"id": {"ghost"}, "token": {"whatever"}}
	_, resp, err := websocket.DefaultDialer.Dial(wsURL(ts, "/ws/client", q), nil)
	if err == nil {
		t.Fatal("expected dial failure")
	}
	if resp == nil || resp.StatusCode != 404 {
		t.Fatalf("status=%v, want 404", resp)
	}
}

// ---- 12. name_update ----

func TestWSNameUpdate(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	reg := registerSession(t, ts, "nu", "OldName", "user-tok")

	agent := dialAgent(t, ts, "nu", reg.AgentToken)
	client := dialClient(t, ts, "nu", reg.ClientToken)
	time.Sleep(50 * time.Millisecond)

	// name_update must NOT be forwarded; send a normal frame after it so we can
	// confirm the client receives the normal one but not the name_update.
	_ = agent.WriteMessage(websocket.TextMessage, []byte(`{"type":"name_update","name":"NewName"}`))
	_ = agent.WriteMessage(websocket.TextMessage, []byte("after"))

	_, data := readText(t, client, 2*time.Second)
	if string(data) != "after" {
		t.Errorf("client received %q; name_update should have been swallowed", data)
	}

	// /api/sessions reflects the new name.
	deadline := time.Now().Add(2 * time.Second)
	var name string
	for time.Now().Before(deadline) {
		st.mu.Lock()
		name = st.sessions["nu"].Name
		st.mu.Unlock()
		if name == "NewName" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if name != "NewName" {
		t.Errorf("session name=%q, want NewName", name)
	}
	if got := metricValue(st, "name_update_total"); got != 1 {
		t.Errorf("name_update_total=%d", got)
	}
}

// ---- 13. slow consumer (unbounded queue + byte cap) ----

func TestWSSlowConsumerClosed(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.ClientSendBufferBytes = 64 // tiny cap to trigger the slow-consumer path
	ts, st := newTestServer(t, cfg)
	reg := registerSession(t, ts, "slow", "Box", "user-tok")

	agent := dialAgent(t, ts, "slow", reg.AgentToken)
	client := dialClient(t, ts, "slow", reg.ClientToken)
	time.Sleep(50 * time.Millisecond)

	// The client never reads. Flood frames past the byte cap.
	big := make([]byte, 200)
	for i := range big {
		big[i] = 'x'
	}
	for i := 0; i < 50; i++ {
		if err := agent.WriteMessage(websocket.TextMessage, big); err != nil {
			break
		}
	}

	// The client must eventually be closed with 4408 slow_consumer.
	_ = client.SetReadDeadline(time.Now().Add(3 * time.Second))
	var closeCode int
	for {
		_, _, err := client.ReadMessage()
		if err != nil {
			if ce, ok := err.(*websocket.CloseError); ok {
				closeCode = ce.Code
			}
			break
		}
	}
	if closeCode != closeWSTimeout {
		t.Errorf("close code=%d, want %d (4408 slow_consumer)", closeCode, closeWSTimeout)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if metricValue(st, "slow_consumer_drop_total") >= 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if got := metricValue(st, "slow_consumer_drop_total"); got < 1 {
		t.Errorf("slow_consumer_drop_total=%d", got)
	}
}
