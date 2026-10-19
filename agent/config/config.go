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

type Config struct {
	Providers map[string]Provider `json:"providers"`
	Websearch Websearch           `json:"websearch"`
	GitHub    GitHub              `json:"github"`
	SSH       SSH                 `json:"ssh"`
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
