package main

import (
	"net/netip"
	"strings"
)

// parseTrustedProxies mirrors parse_trusted_proxies: comma-separated
// IPs/CIDRs into prefixes. Empty/unparseable entries dropped (the latter
// logged). A bare IP is treated as a /32 or /128.
func parseTrustedProxies(value string) []netip.Prefix {
	var out []netip.Prefix
	for _, raw := range strings.Split(value, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if p, err := netip.ParsePrefix(raw); err == nil {
			out = append(out, p)
			continue
		}
		if addr, err := netip.ParseAddr(raw); err == nil {
			out = append(out, netip.PrefixFrom(addr, addr.BitLen()))
			continue
		}
		logEvent("trusted_proxy_invalid", f("value", raw))
	}
	return out
}

// resolveClientIP mirrors resolve_client_ip: honor X-Forwarded-For only when
// the socket peer itself is a trusted proxy; otherwise return the socket peer.
func resolveClientIP(peerHost string, xff string, trusted []netip.Prefix) string {
	if peerHost == "" {
		return "unknown"
	}
	if len(trusted) == 0 {
		return peerHost
	}
	peerIP, err := netip.ParseAddr(peerHost)
	if err != nil {
		return peerHost
	}
	isTrusted := false
	for _, net := range trusted {
		if net.Contains(peerIP) {
			isTrusted = true
			break
		}
	}
	if !isTrusted {
		return peerHost
	}
	forwarded := strings.TrimSpace(xff)
	if forwarded == "" {
		return peerHost
	}
	firstHop := strings.TrimSpace(strings.SplitN(forwarded, ",", 2)[0])
	if firstHop == "" {
		return peerHost
	}
	if _, err := netip.ParseAddr(firstHop); err != nil {
		return peerHost
	}
	return firstHop
}

// hostRequiresPublicBindAck mirrors host_requires_public_bind_ack. Returns
// true when binding to host exposes the relay beyond a single private
// interface (and thus needs --allow-public-bind).
//
// CGNAT (100.64.0.0/10): server.py's docstring claims a CGNAT bind is LAN and
// needs no ack, but its actual code routes through ipaddress.is_private, which
// does NOT include 100.64/10 — so Python at runtime DOES require
// --allow-public-bind for a CGNAT bind. We match Python's runtime behaviour:
// Go's netip.Addr.IsPrivate likewise excludes CGNAT, so we do not special-case
// it and a CGNAT host falls through to requiring an ack.
func hostRequiresPublicBindAck(host string) bool {
	normalized := strings.ToLower(strings.TrimSpace(host))
	if normalized == "localhost" {
		return false
	}
	ip, err := netip.ParseAddr(normalized)
	if err != nil {
		return true // unparseable hostname: treat as public, conservatively.
	}
	if ip.IsUnspecified() {
		return true // 0.0.0.0 / :: bind every interface.
	}
	if ip.IsLoopback() {
		return false
	}
	if ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return false // deliberate LAN deployment.
	}
	return true
}
