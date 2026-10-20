// Package config loads the provider settings (~/.config/yap/settings.json)
// and discovers the provider/model combos those settings expose. LoadConfig
// reads the file; List, ListCombos and ListModels query the configured
// providers for their model lists, so the picker, the `models` CLI and the
// `models` tool share one source of truth.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// ─── Config (~/.config/yap/settings.json) ──────────────────────────────────

type Provider struct {
	BaseURL   string `json:"base_url"`
	APIKeyEnv string `json:"api_key_env"`
}

// Websearch configures the websearch tool. Provider selects the search
// backend (default "exa"; each provider is a self-registering file in
// agent/tools). APIKeyEnv names the env var holding the Exa API key; the
// key VALUE lives in the agenix secret env file sourced by the wrapper
// before exec'ing the agent.
type Websearch struct {
	Provider  string `json:"provider"`
	APIKeyEnv string `json:"api_key_env"`
}

// GitHub names the environment variable containing the GitHub read token.
type GitHub struct {
	APIKeyEnv string `json:"api_key_env"`
}

// SSH configures the ssh tool's trust boundary. KnownHosts overrides the
// known_hosts file hosts are checked against; empty auto-detects (the
// system-wide file when present, else ~/.ssh/known_hosts).
type SSH struct {
	KnownHosts string `json:"known_hosts"`
}

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
	Providers map[string]Provider `json:"providers"`
	Websearch Websearch           `json:"websearch"`
	GitHub    GitHub              `json:"github"`
	SSH       SSH                 `json:"ssh"`
	Sandbox   Sandbox             `json:"sandbox"`
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
	return &cfg, nil
}
