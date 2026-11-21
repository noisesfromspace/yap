package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// configHome points XDG_CONFIG_HOME at a temp dir and returns the settings
// path LoadConfig will read.
func configHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	xdg := filepath.Join(home, ".config")
	t.Setenv("XDG_CONFIG_HOME", xdg)
	return filepath.Join(xdg, "yap", "settings.json")
}

func writeSettings(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A first run has no settings file. The error has to carry the whole answer:
// where the file belongs, a working example, and where the details are.
func TestLoadConfigMissingFileIsFirstRunAdvice(t *testing.T) {
	path := configHome(t)
	_, err := LoadConfig()
	if err == nil {
		t.Fatal("expected an error for a missing settings file")
	}
	msg := err.Error()
	for _, want := range []string{path, "no settings file at", `"api_key_env"`, ":help yap-configuration"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("missing-file error lacks %q:\n%s", want, msg)
		}
	}
}

func TestLoadConfigEmptyProviders(t *testing.T) {
	path := configHome(t)
	writeSettings(t, path, `{"mcp": {"echo": {"command": "true"}}}`)
	_, err := LoadConfig()
	if err == nil || !strings.Contains(err.Error(), "configures no providers") {
		t.Fatalf("expected a no-providers error, got %v", err)
	}
}

func TestLoadConfigInvalidJSON(t *testing.T) {
	path := configHome(t)
	writeSettings(t, path, `{ not json`)
	_, err := LoadConfig()
	if err == nil || !strings.Contains(err.Error(), "parse "+path) {
		t.Fatalf("expected a parse error naming the file, got %v", err)
	}
}

func TestLoadConfigValid(t *testing.T) {
	path := configHome(t)
	writeSettings(t, path, `{"providers": {"openai": {"api_key_env": "OPENAI_API_KEY"}}}`)
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.Providers["openai"].APIKeyEnv != "OPENAI_API_KEY" {
		t.Fatalf("providers not decoded: %+v", cfg.Providers)
	}
}

// A relative $XDG_CONFIG_HOME is ignored (the XDG spec and the Lua side both
// refuse it), so a bad value cannot move the config into the project dir.
func TestConfigPathIgnoresRelativeXDG(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "relative/path")
	want := filepath.Join(home, ".config", "yap", "settings.json")
	if got := configPath(); got != want {
		t.Fatalf("configPath = %q, want %q", got, want)
	}
}
