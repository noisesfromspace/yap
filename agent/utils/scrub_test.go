package utils

import (
	"strings"
	"testing"
)

func TestScrub(t *testing.T) {
	cases := []struct {
		in   string
		want string // substring that must survive, or "" for exact match
	}{
		// PEM private keys are redacted wholesale
		{"-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----", ""},
		{"-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----", ""},
		// age secret keys
		{"AGE-SECRET-KEY-1" + strings.Repeat("A", 40), ""},
		// AWS access key ID
		{"AKIAIOSFODNN7EXAMPLE", ""},
		// Bearer token (prefix survives, token is redacted)
		{"Authorization: Bearer abcdefghijklmnopqrstuvwxyz", "Authorization: [REDACTED]"},
	}

	for _, c := range cases {
		got := Scrub(c.in)
		want := c.want
		if want == "" {
			want = redacted
		}
		if got != want {
			t.Fatalf("Scrub(%q) = %q, want %q", c.in, got, want)
		}
	}

	// assignment patterns keep the key and quoting, drop the value
	got := Scrub(`api_key="1234567890123456"`)
	if got != `api_key="[REDACTED]"` {
		t.Fatalf("assignment: %q", got)
	}
	got = Scrub("password = supersecretvalue")
	if got != "password = [REDACTED]" {
		t.Fatalf("assignment spaced: %q", got)
	}

	// JSON, shell assignments, short and punctuated secrets are redacted.
	for _, c := range []struct{ in, want string }{
		{`{"password":"short!"}`, `{"password":"[REDACTED]"}`},
		{`API_KEY='a:b!c@d'`, `API_KEY='[REDACTED]'`},
		{`Authorization: Bearer abc12345`, `Authorization: [REDACTED]`},
	} {
		if got := Scrub(c.in); got != c.want {
			t.Errorf("Scrub(%q) = %q, want %q", c.in, got, c.want)
		}
	}

	// benign content is untouched
	const benign = "func main() { println(\"hello world\") }\nAKIA is a prefix but not a key\n"
	if Scrub(benign) != benign {
		t.Fatalf("benign changed: %q", Scrub(benign))
	}
}
