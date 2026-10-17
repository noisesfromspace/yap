package main

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

// Decision configures the decision-model backend used by the decision tool and
// the alert gate. Provider selects the backend (default "jev"; each backend is
// a self-registering file in agent/decide). BaseURL/APIKeyEnv/Model are the
// common options; zero values fall back to OpenRouter's Decisions API,
// OPENROUTER_API_KEY, and the pinned Jev release. agent/decide.Model is the
// plug point for other decision backends.
type Decision struct {
	Provider  string `json:"provider"`
	BaseURL   string `json:"base_url"`
	APIKeyEnv string `json:"api_key_env"`
	Model     string `json:"model"`
}

// Alert tunes the pre-execution tool-call gate (see agent/utils/alert.go).
// Zero values use DefaultAlertConfig; set a value only to override it.
type Alert struct {
	ApprovalProb  float64 `json:"approval_prob"`
	AdvisoryProb  float64 `json:"advisory_prob"`
	MinConfidence float64 `json:"min_confidence"`
}

// VPN configures the `vpn` flag on the bash, curl and fetch tools. Command
// is the argv prefix that enters the VPN network namespace and then execs
// the tool's own command — e.g. ["/run/wrappers/bin/tunnel"] (the setuid
// wrapper the netns module builds) or ["sudo", "-n", "ip", "netns", "exec",
// "mullvad"]. When empty, the vpn flag is unavailable and fails loudly.
type VPN struct {
	Command []string `json:"command"`
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
	Decision  Decision            `json:"decision"`
	Alert     Alert               `json:"alert"`
	VPN       VPN                 `json:"vpn"`
	SSH       SSH                 `json:"ssh"`
}

func configPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "yap", "settings.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "yap", "settings.json")
}

func loadConfig() (*Config, error) {
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
