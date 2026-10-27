// Package config loads the provider settings (~/.config/yap/settings.json)
// and discovers the provider/model combos those settings expose. LoadConfig
// reads the file; List, ListCombos and ListModels query the configured
// providers for their model lists, so the picker, the `models` CLI and the
// `models` tool share one source of truth.
package config

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"boers.email/yap/agent/auth"
	"boers.email/yap/agent/mcp"
)

// ─── Config (~/.config/yap/settings.json) ──────────────────────────────────

type Provider struct {
	BaseURL   string `json:"base_url"`
	APIKeyEnv string `json:"api_key_env"`
	// Auth opts this provider into an interactive login instead of an API
	// key. The value is a login method registered by agent/auth ("chatgpt"
	// today), authorized once with `yap login`.
	Auth string `json:"auth"`
}

// AuthToken returns the refreshable token callback for a provider that opts
// into a login, or nil when it authenticates with a static API key.
func AuthToken(prov Provider) func(context.Context) (string, error) {
	if prov.Auth == "" {
		return nil
	}
	return func(ctx context.Context) (string, error) { return auth.Token(ctx, prov.Auth) }
}

// AuthOptions returns the request options a login route requires (nil when
// none, or when the provider uses an API key).
func AuthOptions(prov Provider) map[string]any {
	if prov.Auth == "" {
		return nil
	}
	return auth.ProviderOptions(prov.Auth)
}

// credential resolves the bearer token a provider's model listing needs: a
// refreshed login token, or the env-var API key.
func credential(ctx context.Context, prov Provider) (string, error) {
	if prov.Auth != "" {
		return auth.Token(ctx, prov.Auth)
	}
	key := os.Getenv(prov.APIKeyEnv)
	if prov.APIKeyEnv != "" && key == "" {
		return "", fmt.Errorf("%s is not set", prov.APIKeyEnv)
	}
	return key, nil
}

// MCP servers are consumed as tools: each configured server is connected once
// per backend, its tools discovered at runtime, and exposed to the model as
// mcp_<server>_<tool>.

// Sandbox configures the bash tool's bubblewrap sandbox (Linux only).
// Enabled is a pointer so a missing key defaults to true: the sandbox is on
// unless the settings file explicitly sets enabled=false. AllowWrite and
// DenyRead add directories to the writable allowlist and the read-denied
// shadow list beyond the built-ins (the project dir and session assets dir
// are always writable; the secret paths are always shadowed).
type Sandbox struct {
	Enabled    *bool    `json:"enabled"`
	AllowWrite []string `json:"allow_write"`
	DenyRead   []string `json:"deny_read"`
}

type Config struct {
	Providers map[string]Provider         `json:"providers"`
	MCP       map[string]mcp.ServerConfig `json:"mcp"`
	Sandbox   Sandbox                     `json:"sandbox"`
}

func configPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "yap", "settings.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "yap", "settings.json")
}

func LoadConfig() (*Config, error) {
	data, err := os.ReadFile(configPath())
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", configPath(), err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", configPath(), err)
	}
	for name, prov := range cfg.Providers {
		if prov.Auth != "" {
			if err := auth.Validate(prov.Auth); err != nil {
				return nil, fmt.Errorf("provider %q: %w", name, err)
			}
		}
	}
	return &cfg, nil
}
