package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// newTestConfig returns the canonical test config from the task brief. Heartbeat
// and token-expiry watch intervals are 0 so no background WS goroutines fire,
// keeping tests deterministic. AllowedUserTokens empty = accept-any-token mode.
func newTestConfig(t *testing.T) *RelayConfig {
	t.Helper()
	return &RelayConfig{
		Host:                        "127.0.0.1",
		TokenTTL:                    300,
		OfflineTTL:                  300,
		MaxBodyBytes:                64 * 1024,
		MaxSessions:                 4096,
		MaxClientsPerSession:        8,
		MaxFrameBytes:               256 * 1024,
		RateLimitRequests:           120,
		RateLimitWindowSeconds:      60,
		ClientSendBufferBytes:       1 << 20,
		TokenExpiryCheckSeconds:     0,
		PingIntervalSeconds:         0,
		PingTimeoutSeconds:          0,
		AgentDisconnectGraceSeconds: 8,
		UploadMaxBytes:              100 << 20,
		UploadSessionMaxBytes:       2 << 30,
		UploadMaxPending:            4,
		UploadGlobalMaxPending:      128,
		UploadTTL:                   600,
		UploadDir:                   t.TempDir(),
		StaticRoot:                  t.TempDir(),
		AllowedUserTokens:           map[string]struct{}{},
	}
}

// stateRegistry maps a running test server's URL to its RelayState so helpers
// (e.g. lookupPullToken) can reach internal state without threading it through
// every call. Guarded by stateRegistryMu.
var (
	stateRegistryMu sync.Mutex
	stateRegistry   = map[string]*RelayState{}
)

// httpServer is the minimal surface lookupPullToken needs.
type httpServer interface{ url() string }

func stateFor(ts httpServer) *RelayState {
	stateRegistryMu.Lock()
	defer stateRegistryMu.Unlock()
	return stateRegistry[ts.url()]
}

// jsonUnmarshal is a thin wrapper so non-*testing helpers can decode JSON.
func jsonUnmarshal(s string, dst any) error { return json.Unmarshal([]byte(s), dst) }

// newTestServer spins up an httptest server backed by a fresh RelayState.
func newTestServer(t *testing.T, cfg *RelayConfig) (*httptest.Server, *RelayState) {
	t.Helper()
	st := newRelayState(cfg)
	ts := httptest.NewServer(&server{state: st, config: cfg})
	stateRegistryMu.Lock()
	stateRegistry[ts.URL] = st
	stateRegistryMu.Unlock()
	t.Cleanup(func() {
		ts.Close()
		stateRegistryMu.Lock()
		delete(stateRegistry, ts.URL)
		stateRegistryMu.Unlock()
	})
	return ts, st
}

// metricValue reads a single counter from the live state under lock.
func metricValue(st *RelayState, name string) int64 {
	st.metricsMu.Lock()
	defer st.metricsMu.Unlock()
	return st.metrics[name]
}

type jsonResp struct {
	status  int
	headers http.Header
	body    []byte
	// closeFlag is resp.Close: Go's transport consumes the hop-by-hop
	// "Connection: close" header off resp.Header and reflects it here instead.
	closeFlag bool
}

func (r jsonResp) decode(t *testing.T, dst any) {
	t.Helper()
	if err := json.Unmarshal(r.body, dst); err != nil {
		t.Fatalf("decode body %q: %v", r.body, err)
	}
}

func (r jsonResp) errorField(t *testing.T) string {
	t.Helper()
	var m map[string]any
	r.decode(t, &m)
	s, _ := m["error"].(string)
	return s
}

// doReq issues an arbitrary request and reads the whole response.
func doReq(t *testing.T, method, urlStr string, body []byte, headers map[string]string) jsonResp {
	t.Helper()
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, urlStr, rdr)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, urlStr, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return jsonResp{status: resp.StatusCode, headers: resp.Header, body: data, closeFlag: resp.Close}
}

// rawGet hand-writes a GET over a bare TCP connection so hop-by-hop headers
// (notably Connection: close) are observable verbatim on the wire — Go's
// http.Client transport strips them from resp.Header. Returns the raw header
// block (lowercased keys not applied; caller string-matches).
func rawGet(t *testing.T, baseURL, path string) string {
	t.Helper()
	host := strings.TrimPrefix(baseURL, "http://")
	conn, err := net.Dial("tcp", host)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	req := "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		t.Fatalf("write: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 8192)
	n, _ := conn.Read(buf)
	return string(buf[:n])
}

func doJSON(t *testing.T, method, urlStr string, payload any, headers map[string]string) jsonResp {
	t.Helper()
	var body []byte
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}
		body = b
	}
	return doReq(t, method, urlStr, body, headers)
}

func bearer(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token}
}

// registerSession registers a fresh session and returns its tokens.
type regResult struct {
	SessionID   string `json:"session_id"`
	AgentToken  string `json:"agent_token"`
	ClientToken string `json:"client_token"`
	ExpiresAt   string `json:"expires_at"`
}

func registerSession(t *testing.T, ts *httptest.Server, sessionID, name, userToken string) regResult {
	t.Helper()
	resp := doJSON(t, http.MethodPost, ts.URL+"/api/register", map[string]any{
		"session_id": sessionID,
		"name":       name,
		"token":      userToken,
	}, nil)
	if resp.status != 200 {
		t.Fatalf("register status=%d body=%s", resp.status, resp.body)
	}
	var out regResult
	resp.decode(t, &out)
	return out
}

// wsURL converts the httptest http URL to a ws URL with path and query.
func wsURL(ts *httptest.Server, path string, q url.Values) string {
	u := strings.Replace(ts.URL, "http://", "ws://", 1)
	if len(q) > 0 {
		return u + path + "?" + q.Encode()
	}
	return u + path
}

// dialAgent connects an agent WS with the Bearer agent_token.
func dialAgent(t *testing.T, ts *httptest.Server, sessionID, agentToken string) *websocket.Conn {
	t.Helper()
	q := url.Values{"id": {sessionID}}
	hdr := http.Header{"Authorization": {"Bearer " + agentToken}}
	c, resp, err := websocket.DefaultDialer.Dial(wsURL(ts, "/ws/agent", q), hdr)
	if err != nil {
		status := -1
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("dial agent (status %d): %v", status, err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// dialClient connects a client WS using ?token=.
func dialClient(t *testing.T, ts *httptest.Server, sessionID, clientToken string) *websocket.Conn {
	t.Helper()
	q := url.Values{"id": {sessionID}, "token": {clientToken}}
	c, resp, err := websocket.DefaultDialer.Dial(wsURL(ts, "/ws/client", q), nil)
	if err != nil {
		status := -1
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("dial client (status %d): %v", status, err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// readText reads a single text frame with a deadline, asserting the type.
func readText(t *testing.T, c *websocket.Conn, deadline time.Duration) (int, []byte) {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(deadline))
	mt, data, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read message: %v", err)
	}
	return mt, data
}
