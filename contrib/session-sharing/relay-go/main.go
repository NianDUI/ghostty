package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	config, err := buildConfig(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	state := newRelayState(config)

	publicSrv := &http.Server{
		Addr:    net.JoinHostPort(config.Host, itoa(config.Port)),
		Handler: &server{state: state, config: config, admin: false},
	}
	var adminSrv *http.Server
	if config.AdminPort > 0 {
		adminSrv = &http.Server{
			Addr:    net.JoinHostPort(config.AdminHost, itoa(config.AdminPort)),
			Handler: &server{state: state, config: config, admin: true},
		}
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	cleanupStop := make(chan struct{})
	go state.cleanupLoop(cleanupStop)

	authMode := "accept-any-token"
	if len(config.AllowedUserTokens) > 0 {
		authMode = "token-allowlist"
	}
	trustedProxies := make([]string, 0, len(config.TrustedProxies))
	for _, p := range config.TrustedProxies {
		trustedProxies = append(trustedProxies, p.String())
	}

	logEvent("relay_started",
		f("host", config.Host),
		f("port", config.Port),
		f("static_root", config.StaticRoot),
		f("auth_mode", authMode),
		f("configured_user_tokens", len(config.AllowedUserTokens)),
		f("allow_user_token_client_access", config.AllowUserTokenClientAccess),
		f("offline_ttl", config.OfflineTTL),
		f("token_ttl", config.TokenTTL),
		f("max_body_bytes", config.MaxBodyBytes),
		f("max_sessions", config.MaxSessions),
		f("max_clients_per_session", config.MaxClientsPerSession),
		f("max_frame_bytes", config.MaxFrameBytes),
		f("rate_limit_requests", config.RateLimitRequests),
		f("rate_limit_window_seconds", config.RateLimitWindowSeconds),
		f("trusted_proxies", trustedProxies),
		f("token_expiry_check_seconds", config.TokenExpiryCheckSeconds),
		f("ping_interval_seconds", config.PingIntervalSeconds),
		f("ping_timeout_seconds", config.PingTimeoutSeconds),
		f("client_send_buffer_bytes", config.ClientSendBufferBytes),
		f("admin_host", config.AdminHost),
		f("admin_port", config.AdminPort),
		f("upload_max_bytes", config.UploadMaxBytes),
		f("upload_session_max_bytes", config.UploadSessionMaxBytes),
		f("upload_max_pending", config.UploadMaxPending),
		f("upload_global_max_pending", config.UploadGlobalMaxPending),
		f("upload_ttl", config.UploadTTL),
		f("upload_dir", config.UploadDir),
	)

	errCh := make(chan error, 2)
	go func() { errCh <- publicSrv.ListenAndServe() }()
	if adminSrv != nil {
		go func() { errCh <- adminSrv.ListenAndServe() }()
	}

	select {
	case <-sigCh:
		if state.shuttingDown.CompareAndSwap(false, true) {
			logEvent("shutdown_requested")
		}
	case err := <-errCh:
		state.shuttingDown.Store(true)
		logEvent("listen_failed", f("error", err.Error()))
	}

	close(cleanupStop)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = publicSrv.Shutdown(ctx)
	if adminSrv != nil {
		_ = adminSrv.Shutdown(ctx)
	}
	logEvent("relay_stopped")
}
