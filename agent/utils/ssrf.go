package utils

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"time"
)

// SSRF guard for fetch/curl: reject targets that resolve to non-global
// addresses (cloud metadata, private ranges, link-local, multicast, CGNAT).
// Deterministic local check — no model, nothing leaves the machine. It is
// best-effort defense (bash is deliberately unsandboxed, R-compiled-tools), not a
// security boundary.

// isBlockedIP reports whether ip must not be fetched directly. Loopback is
// deliberately allowed: the agent runs on the user's machine and
// legitimately fetches local dev servers (and its own httptest fixtures);
// blocking it would be inconsistent with the unsandboxed bash stance. The
// real SSRF targets — metadata, internal, and other non-global ranges —
// are blocked.
func isBlockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsLinkLocalUnicast() || // 169.254.0.0/16 (incl. 169.254.169.254 metadata), fe80::/10
		ip.IsLinkLocalMulticast() ||
		ip.IsInterfaceLocalMulticast() ||
		ip.IsMulticast() ||
		ip.IsPrivate() || // 10/8, 172.16/12, 192.168/16, fc00::/7 (ULA)
		ip.IsUnspecified() {
		return true
	}
	if ip4 := ip.To4(); ip4 != nil {
		// 0.0.0.0/8 ("this network") and 100.64.0.0/10 (CGNAT shared
		// address space) are not covered by the methods above.
		return ip4[0] == 0 || (ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127)
	}
	return false
}

// resolveAllowed resolves host to a single dialable IP, rejecting the host
// when ANY resolved address is blocked (OWASP: reject on any non-global
// result, not just the one you would dial).
func resolveAllowed(ctx context.Context, host string) (net.IP, error) {
	ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", host, err)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("no IP addresses for %s", host)
	}
	for _, ip := range ips {
		if isBlockedIP(ip) {
			return nil, fmt.Errorf("refusing to fetch %s: %s is a private/link-local address", host, ip)
		}
	}
	return ips[0], nil
}

// CheckURLHost validates an http(s) URL's host without dialing. It is the
// curl guard: a single pre-exec check of the initial URL. Redirect hops
// curl follows internally (-L) are not re-checked — fetch's dialer below
// is the thorough path.
func CheckURLHost(u *url.URL) error {
	host := u.Hostname()
	if host == "" {
		return fmt.Errorf("missing host in URL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := resolveAllowed(ctx, host)
	return err
}

// CheckedTransport returns an http.Transport whose dialer resolves each
// connection's host, rejects blocked addresses, and dials the checked IP —
// so both the initial request and every redirect hop are checked, and DNS
// rebinding cannot slip a private address between the check and the dial.
// Proxy is nil (no proxy): an HTTP proxy would receive the request and
// connect to the real target itself, bypassing the IP check entirely.
func CheckedTransport() *http.Transport {
	return &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ip, err := resolveAllowed(ctx, host)
			if err != nil {
				return nil, err
			}
			var d net.Dialer
			return d.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		},
	}
}
