package main

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type rateLimitBucket struct {
	windowStartedAt float64
	count           int
}

// initialMetricKeys are the counters server.py seeds at 0. Others
// (name_update_total, web_bundle_total, web_bundle_rejected_total) are
// created lazily on first increment.
var initialMetricKeys = []string{
	"register_requests_total", "register_rejected_total", "register_reused_total",
	"agent_grace_started_total", "agent_grace_canceled_total", "agent_grace_expired_total",
	"agent_connect_total", "agent_disconnect_total",
	"client_connect_total", "client_disconnect_total",
	"auth_rejected_total", "expired_session_rejected_total", "rate_limited_total",
	"slow_consumer_drop_total",
	"upload_init_total", "upload_init_rejected_total",
	"upload_put_total", "upload_put_rejected_total",
	"upload_pull_total", "upload_pull_rejected_total",
	"upload_expired_total", "upload_bytes_total",
	"apk_download_total", "apk_download_rejected_total",
	"apk_download_grant_total", "apk_download_grant_rejected_total",
}

// RelayState mirrors the RelayState class (PORT-SPEC §5).
//
// Locking: mu is the single global mutex protecting sessions, rateLimits,
// apkGrants and every Session's mutable fields — equivalent to server.py's
// asyncio.Lock. metricsMu is independent (counters are bumped from many call
// sites, some already holding mu); lock order is always mu -> metricsMu.
// Never do socket/file IO while holding mu.
type RelayState struct {
	config     *RelayConfig
	offlineTTL float64

	mu         sync.Mutex
	sessions   map[string]*Session
	rateLimits map[string]*rateLimitBucket
	apkGrants  map[string]float64 // grant token -> expires_at (epoch)

	startedAt    float64
	shuttingDown atomic.Bool

	metricsMu sync.Mutex
	metrics   map[string]int64
}

func newRelayState(config *RelayConfig) *RelayState {
	m := map[string]int64{}
	for _, k := range initialMetricKeys {
		m[k] = 0
	}
	return &RelayState{
		config:     config,
		offlineTTL: config.OfflineTTL,
		sessions:   map[string]*Session{},
		rateLimits: map[string]*rateLimitBucket{},
		apkGrants:  map[string]float64{},
		startedAt:  nowSec(),
		metrics:    m,
	}
}

func (s *RelayState) isValidUserToken(token string) bool {
	allowed := s.config.AllowedUserTokens
	if len(allowed) == 0 {
		return true // accept-any mode
	}
	_, ok := allowed[token]
	return ok
}

func (s *RelayState) incMetric(name string) { s.addMetric(name, 1) }

func (s *RelayState) addMetric(name string, amount int64) {
	s.metricsMu.Lock()
	s.metrics[name] += amount
	s.metricsMu.Unlock()
}

// metricsText renders the Prometheus exposition. Caller must hold mu (it
// reads sessions for the gauges); it takes metricsMu internally.
func (s *RelayState) metricsText() string {
	sessionsTotal := len(s.sessions)
	sessionsOnline := 0
	activeAgents := 0
	activeClients := 0
	for _, sess := range s.sessions {
		if sess.Online {
			sessionsOnline++
		}
		if sess.AgentWriter != nil {
			activeAgents++
		}
		activeClients += len(sess.Clients)
	}
	sessionsOffline := sessionsTotal - sessionsOnline

	var b strings.Builder
	b.WriteString("# TYPE ghostty_relay_sessions gauge\n")
	fmt.Fprintf(&b, "ghostty_relay_sessions %d\n", sessionsTotal)
	b.WriteString("# TYPE ghostty_relay_sessions_online gauge\n")
	fmt.Fprintf(&b, "ghostty_relay_sessions_online %d\n", sessionsOnline)
	b.WriteString("# TYPE ghostty_relay_sessions_offline gauge\n")
	fmt.Fprintf(&b, "ghostty_relay_sessions_offline %d\n", sessionsOffline)
	b.WriteString("# TYPE ghostty_relay_active_agents gauge\n")
	fmt.Fprintf(&b, "ghostty_relay_active_agents %d\n", activeAgents)
	b.WriteString("# TYPE ghostty_relay_active_clients gauge\n")
	fmt.Fprintf(&b, "ghostty_relay_active_clients %d\n", activeClients)
	b.WriteString("# TYPE ghostty_relay_uptime_seconds gauge\n")
	fmt.Fprintf(&b, "ghostty_relay_uptime_seconds %d\n", int64(nowSec()-s.startedAt))

	s.metricsMu.Lock()
	keys := make([]string, 0, len(s.metrics))
	for k := range s.metrics {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(&b, "# TYPE ghostty_relay_%s counter\n", k)
		fmt.Fprintf(&b, "ghostty_relay_%s %d\n", k, s.metrics[k])
	}
	s.metricsMu.Unlock()

	return b.String()
}

// shouldRateLimit mirrors should_rate_limit (fixed window per key). Caller
// must hold mu.
func (s *RelayState) shouldRateLimit(key string, now float64) (bool, int) {
	if s.config.RateLimitRequests <= 0 {
		return false, 0
	}
	bucket := s.rateLimits[key]
	if bucket == nil || now-bucket.windowStartedAt >= s.config.RateLimitWindowSeconds {
		s.rateLimits[key] = &rateLimitBucket{windowStartedAt: now, count: 1}
		return false, 0
	}
	if bucket.count >= s.config.RateLimitRequests {
		retryAfter := int(s.config.RateLimitWindowSeconds - (now - bucket.windowStartedAt))
		if retryAfter < 1 {
			retryAfter = 1
		}
		return true, retryAfter
	}
	bucket.count++
	return false, 0
}

// cleanupLoop mirrors cleanup_loop: every 5s drop expired uploads, offline
// sessions past TTL, expired apk grants and stale rate buckets.
func (s *RelayState) cleanupLoop(stop <-chan struct{}) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
		}
		now := nowSec()
		cutoff := now - s.offlineTTL
		rateLimitCutoff := now - s.config.RateLimitWindowSeconds

		s.mu.Lock()
		// Expired uploads first, so temp files go even if the session is
		// also expiring this tick.
		for _, sess := range s.sessions {
			var expired []*PendingUpload
			for _, u := range sess.PendingUploads {
				if u.ExpiresAt < now {
					expired = append(expired, u)
				}
			}
			for _, u := range expired {
				s.incMetric("upload_expired_total")
				removeUpload(sess, u, "ttl_expired")
				logEvent("upload_expired", f("session_id", sess.SessionID), f("upload_id", u.UploadID))
			}
		}
		// Expired sessions.
		var expiredSessions []string
		for id, sess := range s.sessions {
			if !sess.Online && sess.LastSeenAt < cutoff {
				expiredSessions = append(expiredSessions, id)
			}
		}
		for _, id := range expiredSessions {
			sess := s.sessions[id]
			delete(s.sessions, id)
			if sess != nil {
				for _, u := range sess.PendingUploads {
					removeUpload(sess, u, "session_expired")
				}
			}
			logEvent("session_expired", f("session_id", id))
		}
		// Expired apk grants.
		for grant, deadline := range s.apkGrants {
			if deadline < now {
				delete(s.apkGrants, grant)
			}
		}
		// Stale rate buckets.
		for key, bucket := range s.rateLimits {
			if bucket.windowStartedAt < rateLimitCutoff {
				delete(s.rateLimits, key)
			}
		}
		s.mu.Unlock()
	}
}
