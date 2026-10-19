package safety

import (
	"net"
	"net/url"
	"testing"
)

func TestIsBlockedIP(t *testing.T) {
	blocked := []string{
		"169.254.169.254", // cloud metadata
		"169.254.1.1",     // link-local
		"10.0.0.1",        // private
		"172.16.0.1",
		"192.168.1.1",
		"100.64.0.1", // CGNAT
		"0.0.0.1",    // "this network"
		"224.0.0.1",  // multicast
		"fe80::1",    // link-local v6
		"fd00::1",    // ULA
		"ff02::1",    // multicast v6
	}
	for _, s := range blocked {
		ip := net.ParseIP(s)
		if ip == nil {
			t.Fatalf("bad test IP %q", s)
		}
		if !isBlockedIP(ip) {
			t.Errorf("%s should be blocked", s)
		}
	}
	allowed := []string{
		"127.0.0.1", // loopback: local dev + httptest fixtures
		"::1",
		"8.8.8.8",
		"1.1.1.1",
		"2606:4700:4700::1111",
	}
	for _, s := range allowed {
		ip := net.ParseIP(s)
		if ip == nil {
			t.Fatalf("bad test IP %q", s)
		}
		if isBlockedIP(ip) {
			t.Errorf("%s should be allowed", s)
		}
	}
}

func TestCheckURLHost(t *testing.T) {
	for _, raw := range []string{"http://127.0.0.1/", "http://[::1]/", "http://8.8.8.8/"} {
		u, err := url.Parse(raw)
		if err != nil {
			t.Fatalf("parse %s: %v", raw, err)
		}
		if err := CheckURLHost(u); err != nil {
			t.Errorf("%s should be allowed: %v", raw, err)
		}
	}
	for _, raw := range []string{"http://169.254.169.254/", "http://192.168.1.1/", "http://10.0.0.1/", "http://[fd00::1]/"} {
		u, err := url.Parse(raw)
		if err != nil {
			t.Fatalf("parse %s: %v", raw, err)
		}
		if err := CheckURLHost(u); err == nil {
			t.Errorf("%s should be blocked", raw)
		}
	}
}
