package main

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// server implements http.Handler for one listener. admin=true restricts it to
// the operator endpoints.
type server struct {
	state  *RelayState
	config *RelayConfig
	admin  bool
}

// capacitorCORSOrigins: allowlist for native WebView cross-origin fetches.
var capacitorCORSOrigins = map[string]struct{}{
	"https://localhost":     {},
	"http://localhost":      {},
	"capacitor://localhost": {},
	"ionic://localhost":     {},
}

func buildCORSHeaders(origin string) map[string]string {
	if origin == "" {
		return nil
	}
	if _, ok := capacitorCORSOrigins[origin]; !ok {
		return nil
	}
	return map[string]string{
		"Access-Control-Allow-Origin":      origin,
		"Access-Control-Allow-Credentials": "true",
		"Vary":                             "Origin",
	}
}

// writeResponse mirrors send_response: set Content-Type + extra, then inject
// CORS via setdefault (never clobbering handler-set values).
func writeResponse(w http.ResponseWriter, r *http.Request, status int, body []byte, contentType string, extra map[string]string) {
	h := w.Header()
	h.Set("Content-Type", contentType)
	// server.py writes Connection: close on every response and closes the
	// socket (one request per connection). net/http defaults to keep-alive;
	// setting this header makes it close after the reply, matching Python.
	h.Set("Connection", "close")
	for k, v := range extra {
		h.Set(k, v)
	}
	// Advertise the body length so browsers show the download size and
	// clients can render real progress. body is always a complete []byte
	// here, so len(body) is exact; without this the explicit WriteHeader
	// below makes net/http fall back to chunked transfer (no Content-Length),
	// which is why APK downloads showed "unknown size". Content-Length is a
	// CORS-safelisted response header, so native cross-origin fetch can read
	// it too.
	if h.Get("Content-Length") == "" {
		h.Set("Content-Length", strconv.Itoa(len(body)))
	}
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	for k, v := range buildCORSHeaders(origin) {
		if h.Get(k) == "" {
			h.Set(k, v)
		}
	}
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, body []byte) {
	writeResponse(w, r, status, body, "application/json; charset=utf-8", nil)
}

func writeJSONExtra(w http.ResponseWriter, r *http.Request, status int, body []byte, extra map[string]string) {
	writeResponse(w, r, status, body, "application/json; charset=utf-8", extra)
}

func bearerToken(r *http.Request) string {
	value := r.Header.Get("Authorization")
	if value == "" {
		return ""
	}
	if len(value) >= 7 && strings.EqualFold(value[:7], "bearer ") {
		return value[7:]
	}
	return ""
}

func firstQuery(q url.Values, key string) string { return q.Get(key) }

var errBodyTooLarge = errors.New("request body too large")

// readBodyCapped mirrors read_http_body: reject when Content-Length exceeds
// the cap, else read exactly that many bytes (0/unknown -> empty).
func readBodyCapped(r *http.Request, max int) ([]byte, error) {
	declared := r.ContentLength
	if declared > int64(max) {
		return nil, errBodyTooLarge
	}
	if declared <= 0 {
		return []byte{}, nil
	}
	buf := make([]byte, declared)
	if _, err := io.ReadFull(r.Body, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

var adminPaths = map[string]struct{}{
	"/healthz": {}, "/readyz": {}, "/metrics": {},
}

var rateLimitedPaths = map[string]struct{}{
	"/api/register":          {},
	"/api/sessions":          {},
	"/ws/agent":              {},
	"/ws/client":             {},
	"/api/upload/init":       {},
	"/api/app/android":       {},
	"/api/app/android/grant": {},
	"/api/app/version":       {},
	"/api/web/manifest.json": {},
	"/api/web/bundle":        {},
}

// ServeHTTP is the single dispatcher (PORT-SPEC §9), in strict order.
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	st := s.state
	peerHost, _, _ := net.SplitHostPort(r.RemoteAddr)
	method := r.Method
	path := r.URL.Path
	query := r.URL.Query()
	upgrade := strings.ToLower(r.Header.Get("Upgrade"))
	clientIP := resolveClientIP(peerHost, r.Header.Get("X-Forwarded-For"), s.config.TrustedProxies)
	adminEnabled := s.config.AdminPort > 0

	// CORS / OPTIONS preflight (§9.7).
	cors := buildCORSHeaders(strings.TrimSpace(r.Header.Get("Origin")))
	if method == http.MethodOptions {
		if len(cors) == 0 {
			writeResponse(w, r, 403, []byte{}, "text/plain", nil)
			return
		}
		requested := r.Header.Get("Access-Control-Request-Headers")
		if requested == "" {
			requested = "Authorization, Content-Type"
		}
		writeResponse(w, r, 204, []byte{}, "text/plain", map[string]string{
			"Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, HEAD, OPTIONS",
			"Access-Control-Allow-Headers": requested,
			"Access-Control-Max-Age":       "86400",
		})
		return
	}

	// Body: upload PUT/PATCH stream; everything else reads under the cap.
	streamingBody := (method == http.MethodPut || method == http.MethodPatch) &&
		strings.HasPrefix(path, "/api/upload/")
	var body []byte
	if !streamingBody {
		b, err := readBodyCapped(r, s.config.MaxBodyBytes)
		if err != nil {
			logEvent("bad_request", f("remote", peerHost), f("path", path))
			writeJSON(w, r, 400, jsonError("bad request"))
			return
		}
		body = b
	}

	// Admin listener: only health/ready/metrics.
	if s.admin {
		s.serveOperator(w, r, path)
		return
	}

	// Public listener must not expose operator endpoints when a dedicated
	// admin listener is enabled.
	if _, isAdminPath := adminPaths[path]; isAdminPath && adminEnabled {
		writeResponse(w, r, 404, []byte("not found"), "text/plain; charset=utf-8", nil)
		return
	}
	if _, isAdminPath := adminPaths[path]; isAdminPath {
		s.serveOperator(w, r, path)
		return
	}

	// Rate limiting.
	isUploadInit := path == "/api/upload/init"
	isUploadResource := strings.HasPrefix(path, "/api/upload/") && !isUploadInit
	_, isRateLimited := rateLimitedPaths[path]
	if isRateLimited || isUploadResource {
		st.mu.Lock()
		limited, retryAfter := st.shouldRateLimit(clientIP, nowSec())
		st.mu.Unlock()
		if limited {
			st.incMetric("rate_limited_total")
			logEvent("rate_limited", f("remote", clientIP), f("path", path), f("retry_after", retryAfter))
			writeJSONExtra(w, r, 429, jsonError("rate limited"), map[string]string{
				"Retry-After": itoa(retryAfter),
			})
			return
		}
	}

	// WebSocket upgrades.
	if upgrade == "websocket" && path == "/ws/agent" {
		s.handleWSAgent(w, r, query)
		return
	}
	if upgrade == "websocket" && path == "/ws/client" {
		s.handleWSClient(w, r, query)
		return
	}

	// REST routes.
	switch {
	case path == "/api/register":
		s.handleRegister(w, r, method, body)
		return
	case path == "/api/sessions":
		s.handleSessions(w, r, method)
		return
	case path == "/api/app/android":
		s.handleAPKDownload(w, r, method, query)
		return
	case path == "/api/app/android/grant":
		s.handleAPKGrant(w, r, method)
		return
	case path == "/api/app/version":
		s.handleAPKVersion(w, r, method)
		return
	case path == "/api/web/manifest.json":
		s.handleWebManifest(w, r, method)
		return
	case path == "/api/web/bundle":
		s.handleWebBundle(w, r, method)
		return
	case isUploadInit:
		s.handleUploadInit(w, r, method, body)
		return
	case isUploadResource:
		s.routeUploadResource(w, r, method, query, path)
		return
	}

	s.serveStatic(w, r, path)
}

// serveOperator serves the health/ready/metrics endpoints.
func (s *server) serveOperator(w http.ResponseWriter, r *http.Request, path string) {
	st := s.state
	switch path {
	case "/healthz":
		writeJSON(w, r, 200, jsonBytes(map[string]any{"ok": true}))
	case "/readyz":
		st.mu.Lock()
		n := len(st.sessions)
		st.mu.Unlock()
		writeJSON(w, r, 200, jsonBytes(map[string]any{
			"ok":             !st.shuttingDown.Load(),
			"sessions":       n,
			"uptime_seconds": int64(nowSec() - st.startedAt),
		}))
	case "/metrics":
		st.mu.Lock()
		text := st.metricsText()
		st.mu.Unlock()
		writeResponse(w, r, 200, []byte(text), "text/plain; version=0.0.4; charset=utf-8", nil)
	default:
		writeResponse(w, r, 404, []byte("not found"), "text/plain; charset=utf-8", nil)
	}
}

// routeUploadResource mirrors the /api/upload/<id>[/pull] sub-routing (§13.6).
func (s *server) routeUploadResource(w http.ResponseWriter, r *http.Request, method string, query url.Values, path string) {
	rest := strings.TrimPrefix(path, "/api/upload/")
	if strings.HasSuffix(rest, "/pull") {
		uploadID := strings.TrimSuffix(rest, "/pull")
		if uploadID == "" {
			writeJSON(w, r, 404, jsonError("not_found"))
			return
		}
		s.handleUploadPull(w, r, method, query, uploadID)
		return
	}
	uploadID := rest
	if strings.Contains(uploadID, "/") || uploadID == "" {
		writeJSON(w, r, 404, jsonError("not_found"))
		return
	}
	switch method {
	case http.MethodPut:
		s.handleUploadPut(w, r, uploadID)
	case http.MethodPatch:
		s.handleUploadPatch(w, r, uploadID)
	case http.MethodHead:
		s.handleUploadHead(w, r, uploadID)
	default:
		writeJSON(w, r, 405, jsonError("method not allowed"))
	}
}
