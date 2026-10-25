package main

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"boers.email/yap/agent/config"
	"boers.email/yap/agent/internal/testutil"
)

func TestListModelsNativeShapes(t *testing.T) {
	tests := []struct {
		name, path, response string
		want                 string
		checkAuth            func(*http.Request) bool
	}{
		{
			name: "anthropic", path: "/v1/models", response: `{"data":[{"id":"claude-test"}]}`, want: "claude-test",
			checkAuth: func(r *http.Request) bool {
				return r.Header.Get("x-api-key") == "k" && r.Header.Get("anthropic-version") != ""
			},
		},
		{
			name: "google", path: "/v1beta/models", response: `{"models":[{"name":"models/gemini-test"}]}`, want: "gemini-test",
			checkAuth: func(r *http.Request) bool { return r.Header.Get("x-goog-api-key") == "k" },
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != tt.path || !tt.checkAuth(r) {
					t.Fatalf("request path=%q headers=%v", r.URL.Path, r.Header)
				}
				fmt.Fprint(w, tt.response)
			}))
			defer srv.Close()
			ids, err := config.ListModels(t.Context(), tt.name, srv.URL, "k")
			if err != nil || len(ids) != 1 || ids[0] != tt.want {
				t.Fatalf("ids=%v err=%v", ids, err)
			}
		})
	}
}

func TestModelsSkipMissingKey(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		fmt.Fprint(w, `{"data":[{"id":"m1"}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"alpha": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_MISSING_KEY"}`)
	t.Setenv("YAP_TEST_MISSING_KEY", "")
	combos, warnings, err := config.ListCombos()
	if err != nil || len(combos) != 0 || len(warnings) != 1 || called {
		t.Fatalf("missing key should skip provider: combos=%v warnings=%v err=%v called=%v", combos, warnings, err, called)
	}
}

// TestModels: models() queries each configured provider, sorts output, and
// skips a failing provider with a stderr warning.
func TestModels(t *testing.T) {
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			t.Errorf("path: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer k" {
			t.Errorf("auth header: %s", r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"data":[{"id":"m2"},{"id":"m1"}]}`)
	}))
	defer good.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusInternalServerError)
	}))
	defer bad.Close()

	testutil.WriteConfig(t,
		`"zeta": {"base_url": "`+bad.URL+`/v1", "api_key_env": "YAP_TEST_KEY"},
		 "alpha": {"base_url": "`+good.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	err := config.List()
	w.Close()
	os.Stdout = old
	var buf bytes.Buffer
	buf.ReadFrom(r)
	if err != nil {
		t.Fatalf("models: %v", err)
	}
	if got := strings.Fields(buf.String()); len(got) != 2 || got[0] != "alpha/m1" || got[1] != "alpha/m2" {
		t.Fatalf("output: %v", got)
	}
}
