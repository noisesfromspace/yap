package auth

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestRefreshErrors(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	originalClient := http.DefaultClient
	defer func() { http.DefaultClient = originalClient }()
	for _, tc := range []struct {
		name, body string
		status     int
		login      bool
	}{
		{"invalid grant", `{"error":"invalid_grant"}`, 400, true},
		{"reuse", `{"error":"refresh_token_reused"}`, 400, true},
		{"expired", `{"error":"refresh_token_expired"}`, 400, true},
		{"nested", `{"error":{"code":"refresh_token_invalidated"}}`, 400, true},
		{"invalid client", `{"error":"invalid_client"}`, 400, false},
		{"temporary", `{"error":"server_error"}`, 503, false},
		{"non json", `service unavailable`, 503, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := save(&Creds{ClientID: "test-client", RefreshToken: "test-refresh", Expiry: time.Now().Add(-time.Hour)}); err != nil {
				t.Fatal(err)
			}
			before, err := os.ReadFile(Path())
			if err != nil {
				t.Fatal(err)
			}
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(tc.status); fmt.Fprint(w, tc.body) }))
			defer srv.Close()
			target, err := url.Parse(srv.URL)
			if err != nil {
				t.Fatal(err)
			}
			http.DefaultClient = &http.Client{Transport: redirectTokenTransport{target}}
			// Twice also checks that errors release the registry lock.
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			for range 2 {
				_, err = Token(ctx, "chatgpt")
				if err == nil {
					t.Fatal("expected refresh error")
				}
				if got := strings.Contains(err.Error(), "run `yap login chatgpt`"); got != tc.login {
					t.Errorf("login hint=%v, want %v: %v", got, tc.login, err)
				}
				if !strings.Contains(err.Error(), tc.body) {
					t.Errorf("lost server diagnostic: %v", err)
				}
			}
			after, err := os.ReadFile(Path())
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(before) {
				t.Error("refresh error changed credentials")
			}
		})
	}
}
