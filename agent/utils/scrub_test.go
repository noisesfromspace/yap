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

// A word boundary never exists between `_` and a letter, so a key written
// behind a prefix (the normal environment-variable shape) used to slip past
// the assignment scan entirely.
func TestScrubPrefixedKeys(t *testing.T) {
	for _, key := range []string{
		"OPENAI_API_KEY",
		"AWS_SECRET_ACCESS_KEY",
		"AWS_SECRET_KEY",
		"POSTGRES_PASSWORD",
		"MY_ACCESS_TOKEN",
		"DEPLOY_PRIVATE_KEY",
	} {
		got := Scrub(key + "=super-secret-value")
		if strings.Contains(got, "super-secret-value") {
			t.Errorf("%s: value leaked: %q", key, got)
		}
		if !strings.Contains(got, key) {
			t.Errorf("%s: key name should survive: %q", key, got)
		}
		if !strings.Contains(got, redacted) {
			t.Errorf("%s: no redaction marker: %q", key, got)
		}
	}
}

// Tokens that identify themselves need no key name; without these a secret
// pasted on its own (a diff, a log line, a shell trace) stayed in context.
func TestScrubVendorTokens(t *testing.T) {
	for _, in := range []string{
		"token ghp_" + strings.Repeat("a", 36),
		"key sk-" + strings.Repeat("b", 32),
		"bot xoxb-1234567890-abcdefghij",
		"google AIza" + strings.Repeat("c", 35),
		"jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
	} {
		if got := Scrub(in); !strings.Contains(got, redacted) {
			t.Errorf("token not redacted: %q -> %q", in, got)
		}
	}
}

func TestScrubBracedValue(t *testing.T) {
	got := Scrub("password={hunter2}")
	if strings.Contains(got, "hunter2") {
		t.Fatalf("braced value leaked: %q", got)
	}
}
