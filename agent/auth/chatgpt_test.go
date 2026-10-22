package auth

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// fakeIDToken builds an unsigned JWT carrying the claims under test.
func fakeIDToken(t *testing.T, claims map[string]any) string {
	t.Helper()
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	enc := base64.RawURLEncoding
	return enc.EncodeToString([]byte(`{"alg":"none"}`)) + "." +
		enc.EncodeToString(payload) + "." + enc.EncodeToString([]byte("sig"))
}

func TestIDTokenClaims(t *testing.T) {
	good := map[string]any{
		"iss":   "https://auth.openai.com",
		"aud":   "oaiapp_123",
		"sub":   "subject-1",
		"email": "user@example.com",
		"nonce": "n-1",
	}
	tok := fakeIDToken(t, good)
	c, err := idTokenClaims(tok, "oaiapp_123", "n-1")
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if c.Sub != "subject-1" || c.Email != "user@example.com" {
		t.Errorf("claims = %+v, want subject/email from the token", c)
	}

	// aud may be an array of audiences rather than a single string.
	arrayAud := map[string]any{"iss": "https://auth.openai.com", "aud": []string{"other", "oaiapp_123"}, "sub": "s", "nonce": "n-1"}
	if _, err := idTokenClaims(fakeIDToken(t, arrayAud), "oaiapp_123", "n-1"); err != nil {
		t.Errorf("array audience rejected: %v", err)
	}

	cases := map[string]struct {
		claims   map[string]any
		clientID string
		nonce    string
	}{
		"wrong nonce":    {good, "oaiapp_123", "n-2"},
		"wrong audience": {good, "oaiapp_999", "n-1"},
		"wrong issuer":   {map[string]any{"iss": "https://evil.example", "aud": "oaiapp_123", "sub": "s", "nonce": "n-1"}, "oaiapp_123", "n-1"},
		"no subject":     {map[string]any{"iss": "https://auth.openai.com", "aud": "oaiapp_123", "nonce": "n-1"}, "oaiapp_123", "n-1"},
	}
	for name, tc := range cases {
		if _, err := idTokenClaims(fakeIDToken(t, tc.claims), tc.clientID, tc.nonce); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := idTokenClaims(strings.Join([]string{"a", "b"}, "."), "oaiapp_123", "n-1"); err == nil {
		t.Error("two-segment token accepted")
	}
}

func TestNeedsRefresh(t *testing.T) {
	fresh := &Creds{AccessToken: "a", Expiry: time.Now().Add(time.Hour)}
	if needsRefresh(fresh) {
		t.Error("token valid for an hour should not refresh")
	}
	expiring := &Creds{AccessToken: "a", Expiry: time.Now().Add(time.Minute)}
	if !needsRefresh(expiring) {
		t.Error("token expiring inside the refresh margin should refresh")
	}
	if !needsRefresh(&Creds{Expiry: time.Now().Add(time.Hour)}) {
		t.Error("a record without an access token should refresh")
	}
}

func TestNewHostID(t *testing.T) {
	id, err := newHostID()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(id, "urn:uuid:") || len(id) != len("urn:uuid:")+36 {
		t.Errorf("host id %q is not a urn:uuid: UUID", id)
	}
	if id[len("urn:uuid:")+14] != '4' { // version nibble: third group starts at 14
		t.Errorf("host id %q is not a version 4 UUID", id)
	}
}
