package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// ─── Config (~/.config/yap.json) ───────────────────────────────────────────

type Provider struct {
	BaseURL   string `json:"base_url"`
	APIKeyEnv string `json:"api_key_env"`
}

// Websearch configures the Exa websearch tool. Only the API key env var
// name is needed; the key VALUE lives in the agenix secret env file
// sourced by the wrapper before exec'ing the agent.
type Websearch struct {
	APIKeyEnv string `json:"api_key_env"`
}

type Config struct {
	Providers map[string]Provider `json:"providers"`
	Websearch Websearch           `json:"websearch"`
	// Optional per-model pricing in USD per 1M tokens; used to compute the
	// cost field in the yap:usage marker.
	Pricing map[string]Pricing `json:"pricing"`
}

type Pricing struct {
	Input  float64 `json:"input"`
	Output float64 `json:"output"`
}

func configPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "yap.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "yap.json")
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
