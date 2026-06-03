package main

import (
	"net/http"
	"strings"
	"testing"
)

// ---- 1. operator endpoints ----

func TestHealthz(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/healthz", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d", resp.status)
	}
	var m map[string]any
	resp.decode(t, &m)
	if m["ok"] != true {
		t.Fatalf("ok=%v body=%s", m["ok"], resp.body)
	}
	// Go's transport hides Connection: close from resp.Header; resp.Close
	// reflects that the server requested connection close.
	if !resp.closeFlag {
		t.Errorf("response not flagged for close (Connection: close missing)")
	}
}

func TestReadyz(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/readyz", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d", resp.status)
	}
	var m map[string]any
	resp.decode(t, &m)
	if m["ok"] != true {
		t.Errorf("ok=%v", m["ok"])
	}
	if _, ok := m["sessions"]; !ok {
		t.Errorf("missing sessions field: %s", resp.body)
	}
	if _, ok := m["uptime_seconds"]; !ok {
		t.Errorf("missing uptime_seconds field: %s", resp.body)
	}
}

func TestMetricsInitial(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/metrics", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d", resp.status)
	}
	ct := resp.headers.Get("Content-Type")
	if ct != "text/plain; version=0.0.4; charset=utf-8" {
		t.Errorf("content-type=%q", ct)
	}
	text := string(resp.body)
	// 6 gauges.
	gauges := []string{
		"ghostty_relay_sessions",
		"ghostty_relay_sessions_online",
		"ghostty_relay_sessions_offline",
		"ghostty_relay_active_agents",
		"ghostty_relay_active_clients",
		"ghostty_relay_uptime_seconds",
	}
	for _, g := range gauges {
		if !strings.Contains(text, "# TYPE "+g+" gauge\n") {
			t.Errorf("missing gauge %s", g)
		}
	}
	// A representative seeded counter.
	if !strings.Contains(text, "ghostty_relay_register_requests_total 0\n") {
		t.Errorf("missing register_requests_total counter:\n%s", text)
	}
	if !strings.Contains(text, "# TYPE ghostty_relay_register_requests_total counter\n") {
		t.Errorf("missing counter TYPE line")
	}
}

// ---- 2. register ----

func TestRegisterNew(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	resp := doJSON(t, http.MethodPost, ts.URL+"/api/register", map[string]any{
		"session_id": "sess-1", "name": "Box", "token": "user-tok",
	}, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	var out regResult
	resp.decode(t, &out)
	if out.AgentToken == "" || out.ClientToken == "" {
		t.Errorf("empty tokens: %+v", out)
	}
	// expires_at must be RFC3339 Z (second precision, trailing Z).
	if !strings.HasSuffix(out.ExpiresAt, "Z") || !strings.Contains(out.ExpiresAt, "T") {
		t.Errorf("expires_at not RFC3339Z: %q", out.ExpiresAt)
	}
	if got := metricValue(st, "register_requests_total"); got != 1 {
		t.Errorf("register_requests_total=%d", got)
	}
}

func TestRegisterMethodNotAllowed(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/register", nil, nil)
	if resp.status != 405 {
		t.Fatalf("status=%d", resp.status)
	}
}

func TestRegisterInvalidJSON(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodPost, ts.URL+"/api/register", []byte("{not json"), nil)
	if resp.status != 400 {
		t.Fatalf("status=%d", resp.status)
	}
	if e := resp.errorField(t); e != "invalid json" {
		t.Errorf("error=%q", e)
	}
}

func TestRegisterInvalidPayload(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	cases := []struct {
		name    string
		payload map[string]any
	}{
		{"empty session_id", map[string]any{"session_id": "", "name": "n", "token": "t"}},
		{"empty token", map[string]any{"session_id": "s", "name": "n", "token": ""}},
		{"long session_id", map[string]any{"session_id": strings.Repeat("x", 129), "name": "n", "token": "t"}},
		{"long name", map[string]any{"session_id": "s", "name": strings.Repeat("x", 257), "token": "t"}},
		{"long token", map[string]any{"session_id": "s", "name": "n", "token": strings.Repeat("x", 1025)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp := doJSON(t, http.MethodPost, ts.URL+"/api/register", tc.payload, nil)
			if resp.status != 400 {
				t.Fatalf("status=%d body=%s", resp.status, resp.body)
			}
			if e := resp.errorField(t); e != "invalid payload" {
				t.Errorf("error=%q", e)
			}
		})
	}
}

func TestRegisterMissingField(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	// Missing "token" key entirely -> invalid json (key presence check).
	resp := doJSON(t, http.MethodPost, ts.URL+"/api/register", map[string]any{
		"session_id": "s", "name": "n",
	}, nil)
	if resp.status != 400 {
		t.Fatalf("status=%d", resp.status)
	}
	if e := resp.errorField(t); e != "invalid json" {
		t.Errorf("error=%q", e)
	}
}

func TestRegisterReuseRotatesTokensKeepsName(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	first := registerSession(t, ts, "sess-r", "OrigName", "user-tok")

	// Re-register with empty name -> name preserved, tokens rotated.
	resp := doJSON(t, http.MethodPost, ts.URL+"/api/register", map[string]any{
		"session_id": "sess-r", "name": "", "token": "user-tok",
	}, nil)
	if resp.status != 200 {
		t.Fatalf("reuse status=%d body=%s", resp.status, resp.body)
	}
	var second regResult
	resp.decode(t, &second)
	if second.AgentToken == first.AgentToken {
		t.Errorf("agent_token not rotated")
	}
	if second.ClientToken == first.ClientToken {
		t.Errorf("client_token not rotated")
	}
	if got := metricValue(st, "register_reused_total"); got != 1 {
		t.Errorf("register_reused_total=%d", got)
	}
	// Name preserved.
	st.mu.Lock()
	gotName := st.sessions["sess-r"].Name
	st.mu.Unlock()
	if gotName != "OrigName" {
		t.Errorf("name=%q, want preserved OrigName", gotName)
	}
}

// ---- 3. sessions ----

func TestSessionsList(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "s1", "A", "user-X")
	registerSession(t, ts, "s2", "B", "user-X")
	registerSession(t, ts, "s3", "C", "user-OTHER")

	resp := doReq(t, http.MethodGet, ts.URL+"/api/sessions", nil, bearer("user-X"))
	if resp.status != 200 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	var arr []map[string]any
	resp.decode(t, &arr)
	if len(arr) != 2 {
		t.Fatalf("expected 2 sessions for user-X, got %d: %s", len(arr), resp.body)
	}
	for _, s := range arr {
		if _, ok := s["client_token"]; !ok {
			t.Errorf("session missing client_token: %v", s)
		}
	}
}

func TestSessionsMissingBearer(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/sessions", nil, nil)
	if resp.status != 401 {
		t.Fatalf("status=%d", resp.status)
	}
	if e := resp.errorField(t); e != "missing bearer token" {
		t.Errorf("error=%q", e)
	}
}

func TestSessionsExcludesExpired(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	registerSession(t, ts, "live", "Live", "user-Z")
	registerSession(t, ts, "dead", "Dead", "user-Z")
	// Force "dead" to be expired.
	st.mu.Lock()
	st.sessions["dead"].ExpiresAt = nowSec() - 10
	st.mu.Unlock()

	resp := doReq(t, http.MethodGet, ts.URL+"/api/sessions", nil, bearer("user-Z"))
	var arr []map[string]any
	resp.decode(t, &arr)
	if len(arr) != 1 || arr[0]["id"] != "live" {
		t.Fatalf("expected only 'live', got %s", resp.body)
	}
}

// ---- 4. CORS / OPTIONS ----

func TestOptionsAllowedOrigin(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodOptions, ts.URL+"/api/register", nil, map[string]string{
		"Origin": "capacitor://localhost",
	})
	if resp.status != 204 {
		t.Fatalf("status=%d", resp.status)
	}
	if resp.headers.Get("Access-Control-Allow-Methods") != "GET, POST, PUT, PATCH, HEAD, OPTIONS" {
		t.Errorf("ACAM=%q", resp.headers.Get("Access-Control-Allow-Methods"))
	}
	if resp.headers.Get("Access-Control-Allow-Headers") != "Authorization, Content-Type" {
		t.Errorf("ACAH=%q", resp.headers.Get("Access-Control-Allow-Headers"))
	}
	if resp.headers.Get("Access-Control-Max-Age") != "86400" {
		t.Errorf("ACMA=%q", resp.headers.Get("Access-Control-Max-Age"))
	}
}

func TestOptionsRequestedHeadersEcho(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodOptions, ts.URL+"/api/register", nil, map[string]string{
		"Origin":                         "capacitor://localhost",
		"Access-Control-Request-Headers": "X-Custom, Authorization",
	})
	if resp.headers.Get("Access-Control-Allow-Headers") != "X-Custom, Authorization" {
		t.Errorf("ACAH=%q", resp.headers.Get("Access-Control-Allow-Headers"))
	}
}

func TestOptionsForbiddenOrigin(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodOptions, ts.URL+"/api/register", nil, map[string]string{
		"Origin": "https://evil.example",
	})
	if resp.status != 403 {
		t.Fatalf("status=%d", resp.status)
	}
}

func TestCORSInjectedOnNormalResponse(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/healthz", nil, map[string]string{
		"Origin": "capacitor://localhost",
	})
	if resp.headers.Get("Access-Control-Allow-Origin") != "capacitor://localhost" {
		t.Errorf("ACAO=%q", resp.headers.Get("Access-Control-Allow-Origin"))
	}
	if resp.headers.Get("Access-Control-Allow-Credentials") != "true" {
		t.Errorf("ACAC=%q", resp.headers.Get("Access-Control-Allow-Credentials"))
	}
	if !strings.Contains(resp.headers.Get("Vary"), "Origin") {
		t.Errorf("Vary=%q", resp.headers.Get("Vary"))
	}
}

// ---- 5. Connection: close header on every REST response ----

func TestConnectionCloseHeader(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	paths := []string{"/healthz", "/readyz", "/metrics", "/api/app/version", "/nonexistent"}
	for _, p := range paths {
		// Verify on the wire via a raw connection: the handler emits
		// "Connection: close" on every REST response. http.Client would strip
		// this hop-by-hop header, so we read the raw response head.
		raw := rawGet(t, ts.URL, p)
		if !strings.Contains(strings.ToLower(raw), "connection: close") {
			t.Errorf("GET %s: missing 'Connection: close' on the wire; head=%q", p, raw)
		}
	}
}

// ---- 6. rate limiting ----

func TestRateLimit(t *testing.T) {
	cfg := newTestConfig(t)
	cfg.RateLimitRequests = 2
	ts, st := newTestServer(t, cfg)

	// First two hits on a rate-limited path pass; third is 429.
	for i := 0; i < 2; i++ {
		resp := doReq(t, http.MethodGet, ts.URL+"/api/register", nil, nil)
		// /api/register with GET is 405 but still counts toward the limit.
		if resp.status == 429 {
			t.Fatalf("hit %d already limited", i)
		}
	}
	resp := doReq(t, http.MethodGet, ts.URL+"/api/register", nil, nil)
	if resp.status != 429 {
		t.Fatalf("status=%d, want 429", resp.status)
	}
	if resp.headers.Get("Retry-After") == "" {
		t.Errorf("missing Retry-After")
	}
	if e := resp.errorField(t); e != "rate limited" {
		t.Errorf("error=%q", e)
	}
	if got := metricValue(st, "rate_limited_total"); got < 1 {
		t.Errorf("rate_limited_total=%d", got)
	}
}
