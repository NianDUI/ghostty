package main

import (
	"flag"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ---- defaults (mirror server.py module constants) ----

const (
	defaultMaxBodyBytes           = 64 * 1024
	defaultMaxSessions            = 4096
	defaultMaxClientsPerSession   = 8
	defaultMaxFrameBytes          = 256 * 1024
	defaultRateLimitRequests      = 120
	defaultRateLimitWindowSeconds = 60.0

	defaultUploadMaxBytes         = 100 * 1024 * 1024      // 100 MiB / file
	defaultUploadSessionMaxBytes  = 2 * 1024 * 1024 * 1024 // 2 GiB / session
	defaultUploadMaxPending       = 4
	defaultUploadGlobalMaxPending = 128
	defaultUploadTTL              = 600.0
	defaultUploadInitBodyBytes    = 4096
	defaultUploadChunkBytes       = 1 * 1024 * 1024  // streaming read block (PUT/PATCH)
	defaultUploadPatchChunkBytes  = 5 * 1024 * 1024  // recommended PATCH chunk
	defaultUploadPatchMaxBytes    = 16 * 1024 * 1024 // hard cap per PATCH body

	// agentDisconnectGraceSeconds has no CLI/env knob in server.py; it's a
	// dataclass default. 0 disables the grace.
	defaultAgentDisconnectGraceSeconds = 8.0
)

// Read-once env knobs for the replay backlog (no CLI flag in server.py).
var (
	sessionBacklogLimit      = envInt("GHOSTTY_RELAY_SESSION_BACKLOG_BYTES", 64*1024)
	sessionBacklogFrameLimit = envInt("GHOSTTY_RELAY_SESSION_BACKLOG_FRAMES", 256)
)

// RelayConfig is the immutable runtime configuration (PORT-SPEC §2).
type RelayConfig struct {
	Host                        string
	Port                        int
	OfflineTTL                  float64
	TokenTTL                    float64
	AllowedUserTokens           map[string]struct{}
	AllowUserTokenClientAccess  bool
	StaticRoot                  string
	MaxBodyBytes                int
	MaxSessions                 int
	MaxClientsPerSession        int
	MaxFrameBytes               int
	RateLimitRequests           int
	RateLimitWindowSeconds      float64
	TrustedProxies              []netip.Prefix
	TokenExpiryCheckSeconds     float64
	PingIntervalSeconds         float64
	PingTimeoutSeconds          float64
	AgentDisconnectGraceSeconds float64
	ClientSendBufferBytes       int
	AdminHost                   string
	AdminPort                   int
	UploadMaxBytes              int
	UploadSessionMaxBytes       int
	UploadMaxPending            int
	UploadGlobalMaxPending      int
	UploadTTL                   float64
	UploadDir                   string
}

// ---- env helpers (mirror env_str/env_int/env_float/env_bool) ----

func envStr(name, def string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	return def
}

func envInt(name string, def int) int {
	v, ok := os.LookupEnv(name)
	if !ok {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return def
	}
	return n
}

func envFloat(name string, def float64) float64 {
	v, ok := os.LookupEnv(name)
	if !ok {
		return def
	}
	n, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil {
		return def
	}
	return n
}

func envBool(name string, def bool) bool {
	v, ok := os.LookupEnv(name)
	if !ok {
		return def
	}
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

// loadAllowedUserTokens mirrors load_allowed_user_tokens: merge inline env
// list and a token file (one per line, '#' and blanks skipped).
func loadAllowedUserTokens() map[string]struct{} {
	out := map[string]struct{}{}
	inline := os.Getenv("GHOSTTY_RELAY_USER_TOKENS")
	if strings.TrimSpace(inline) != "" {
		for _, tok := range strings.Split(inline, ",") {
			tok = strings.TrimSpace(tok)
			if tok != "" {
				out[tok] = struct{}{}
			}
		}
	}
	tokenFile := strings.TrimSpace(os.Getenv("GHOSTTY_RELAY_USER_TOKENS_FILE"))
	if tokenFile != "" {
		data, err := os.ReadFile(tokenFile)
		if err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				tok := strings.TrimSpace(line)
				if tok != "" && !strings.HasPrefix(tok, "#") {
					out[tok] = struct{}{}
				}
			}
		}
	}
	return out
}

// defaultStaticRoot mirrors the spirit of server.py's
// pathlib.Path(__file__).parent.parent/"web". A compiled Go binary has no
// source path, so we resolve "<cwd>/../web" is not reliable either; we use
// the sibling "web" of session-sharing relative to the executable's grand-
// parent when possible, else "./web". Production always sets the env.
func defaultStaticRoot() string {
	// Mirror layout: contrib/session-sharing/{relay-go,web}. If the binary
	// sits in relay-go/, ../web is the target.
	if exe, err := os.Executable(); err == nil {
		cand := filepath.Join(filepath.Dir(exe), "..", "web")
		if st, err := os.Stat(cand); err == nil && st.IsDir() {
			if abs, err := filepath.Abs(cand); err == nil {
				return abs
			}
		}
	}
	abs, _ := filepath.Abs("web")
	return abs
}

// buildConfig parses flags (defaults sourced from env) and returns the
// config. It mirrors main()'s argparse block, including the public-bind ack
// check. On a bind-ack violation it returns an error.
func buildConfig(args []string) (*RelayConfig, error) {
	fs := flag.NewFlagSet("ghostty-relay", flag.ContinueOnError)

	host := fs.String("host", envStr("GHOSTTY_RELAY_HOST", "127.0.0.1"), "bind host")
	port := fs.Int("port", envInt("GHOSTTY_RELAY_PORT", 18080), "bind port")
	offlineTTL := fs.Float64("offline-ttl", envFloat("GHOSTTY_RELAY_OFFLINE_TTL", 300.0), "")
	tokenTTL := fs.Float64("token-ttl", envFloat("GHOSTTY_RELAY_TOKEN_TTL", 300.0), "")
	maxBodyBytes := fs.Int("max-body-bytes", envInt("GHOSTTY_RELAY_MAX_BODY_BYTES", defaultMaxBodyBytes), "")
	maxSessions := fs.Int("max-sessions", envInt("GHOSTTY_RELAY_MAX_SESSIONS", defaultMaxSessions), "")
	maxClients := fs.Int("max-clients-per-session", envInt("GHOSTTY_RELAY_MAX_CLIENTS_PER_SESSION", defaultMaxClientsPerSession), "")
	maxFrameBytes := fs.Int("max-frame-bytes", envInt("GHOSTTY_RELAY_MAX_FRAME_BYTES", defaultMaxFrameBytes), "")
	rateLimitReq := fs.Int("rate-limit-requests", envInt("GHOSTTY_RELAY_RATE_LIMIT_REQUESTS", defaultRateLimitRequests), "")
	rateLimitWin := fs.Float64("rate-limit-window-seconds", envFloat("GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS", defaultRateLimitWindowSeconds), "")
	allowUserTokenClient := fs.Bool("allow-user-token-client-access", envBool("GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS", false), "")
	allowPublicBind := fs.Bool("allow-public-bind", envBool("GHOSTTY_RELAY_ALLOW_PUBLIC_BIND", false), "")
	trustedProxies := fs.String("trusted-proxies", envStr("GHOSTTY_RELAY_TRUSTED_PROXIES", ""), "comma-separated IPs/CIDRs whose X-Forwarded-For is trusted")
	tokenExpiryCheck := fs.Float64("token-expiry-check-seconds", envFloat("GHOSTTY_RELAY_TOKEN_EXPIRY_CHECK_SECONDS", 30.0), "")
	pingInterval := fs.Float64("ping-interval-seconds", envFloat("GHOSTTY_RELAY_PING_INTERVAL_SECONDS", 30.0), "")
	pingTimeout := fs.Float64("ping-timeout-seconds", envFloat("GHOSTTY_RELAY_PING_TIMEOUT_SECONDS", 60.0), "")
	clientSendBuffer := fs.Int("client-send-buffer-bytes", envInt("GHOSTTY_RELAY_CLIENT_SEND_BUFFER_BYTES", 1024*1024), "")
	adminHost := fs.String("admin-host", envStr("GHOSTTY_RELAY_ADMIN_HOST", "127.0.0.1"), "admin listener host")
	adminPort := fs.Int("admin-port", envInt("GHOSTTY_RELAY_ADMIN_PORT", 0), "admin listener port; 0 keeps admin on public listener")
	staticRoot := fs.String("static-root", envStr("GHOSTTY_RELAY_STATIC_ROOT", defaultStaticRoot()), "")
	uploadMaxBytes := fs.Int("upload-max-bytes", envInt("GHOSTTY_RELAY_UPLOAD_MAX_BYTES", defaultUploadMaxBytes), "")
	uploadSessionMax := fs.Int("upload-session-max-bytes", envInt("GHOSTTY_RELAY_UPLOAD_SESSION_MAX_BYTES", defaultUploadSessionMaxBytes), "")
	uploadMaxPending := fs.Int("upload-max-pending", envInt("GHOSTTY_RELAY_UPLOAD_MAX_PENDING", defaultUploadMaxPending), "")
	uploadGlobalMaxPending := fs.Int("upload-global-max-pending", envInt("GHOSTTY_RELAY_UPLOAD_GLOBAL_MAX_PENDING", defaultUploadGlobalMaxPending), "")
	uploadTTL := fs.Float64("upload-ttl", envFloat("GHOSTTY_RELAY_UPLOAD_TTL", defaultUploadTTL), "")
	uploadDir := fs.String("upload-dir", envStr("GHOSTTY_RELAY_UPLOAD_DIR", "/tmp/ghostty-uploads"), "")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}

	if hostRequiresPublicBindAck(*host) && !*allowPublicBind {
		return nil, fmt.Errorf("public bind requires --allow-public-bind (or GHOSTTY_RELAY_ALLOW_PUBLIC_BIND=1)")
	}

	staticAbs, _ := filepath.Abs(*staticRoot)
	uploadAbs, _ := filepath.Abs(*uploadDir)

	return &RelayConfig{
		Host:                        *host,
		Port:                        *port,
		OfflineTTL:                  *offlineTTL,
		TokenTTL:                    *tokenTTL,
		AllowedUserTokens:           loadAllowedUserTokens(),
		AllowUserTokenClientAccess:  *allowUserTokenClient,
		StaticRoot:                  staticAbs,
		MaxBodyBytes:                *maxBodyBytes,
		MaxSessions:                 *maxSessions,
		MaxClientsPerSession:        *maxClients,
		MaxFrameBytes:               *maxFrameBytes,
		RateLimitRequests:           *rateLimitReq,
		RateLimitWindowSeconds:      *rateLimitWin,
		TrustedProxies:              parseTrustedProxies(*trustedProxies),
		TokenExpiryCheckSeconds:     *tokenExpiryCheck,
		PingIntervalSeconds:         *pingInterval,
		PingTimeoutSeconds:          *pingTimeout,
		AgentDisconnectGraceSeconds: defaultAgentDisconnectGraceSeconds,
		ClientSendBufferBytes:       *clientSendBuffer,
		AdminHost:                   *adminHost,
		AdminPort:                   *adminPort,
		UploadMaxBytes:              *uploadMaxBytes,
		UploadSessionMaxBytes:       *uploadSessionMax,
		UploadMaxPending:            *uploadMaxPending,
		UploadGlobalMaxPending:      *uploadGlobalMaxPending,
		UploadTTL:                   *uploadTTL,
		UploadDir:                   uploadAbs,
	}, nil
}
