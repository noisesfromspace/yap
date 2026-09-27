package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// ─── Config (~/.pitel/config.json) ───────────────────────────────────────────

type Provider struct {
	BaseURL   string `json:"base_url"`
	APIKeyEnv string `json:"api_key_env"`
}

type Config struct {
	Providers map[string]Provider `json:"providers"`
	// Optional per-model pricing in USD per 1M tokens; used to compute the
	// cost field in the pitel:usage marker.
	Pricing map[string]Pricing `json:"pricing"`
}

type Pricing struct {
	Input  float64 `json:"input"`
	Output float64 `json:"output"`
}

func configPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".pitel", "config.json")
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
