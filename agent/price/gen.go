//go:build ignore

// Regenerates agent/price/pricing.json from LiteLLM's community-maintained
// model_prices_and_context_window.json. Run via `go generate ./agent/price`
// (or directly: `go run agent/price/gen.go`).
//
// Kept out of normal builds with the ignore tag; it needs network access,
// which the shipped binary must never require.
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
)

const upstream = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

type entry struct {
	Input      float64 `json:"input"`
	Output     float64 `json:"output"`
	CacheRead  float64 `json:"cache_read,omitempty"`
	CacheWrite float64 `json:"cache_write,omitempty"`
	Context    int     `json:"context,omitempty"`
}

func round4(v float64) float64 { return math.Round(v*1e4) / 1e4 }

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "pricing/gen:", err)
		os.Exit(1)
	}
}

func run() error {
	resp, err := http.Get(upstream)
	if err != nil {
		return fmt.Errorf("fetch %s: %w", upstream, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch %s: HTTP %s", upstream, resp.Status)
	}

	var raw map[string]map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return fmt.Errorf("parse upstream: %w", err)
	}

	catalog := make(map[string]entry, len(raw)/2)
	for id, m := range raw {
		if m["mode"] != "chat" {
			continue
		}
		in, okIn := m["input_cost_per_token"].(float64)
		out, okOut := m["output_cost_per_token"].(float64)
		if !okIn || !okOut || !(in > 0 || out > 0) {
			continue
		}
		e := entry{Input: round4(in * 1e6), Output: round4(out * 1e6)}
		if cr, ok := m["cache_read_input_token_cost"].(float64); ok && cr > 0 {
			e.CacheRead = round4(cr * 1e6)
		}
		if cw, ok := m["cache_creation_input_token_cost"].(float64); ok && cw > 0 {
			e.CacheWrite = round4(cw * 1e6)
		}
		if ctx, ok := m["max_input_tokens"].(float64); ok && ctx > 0 {
			e.Context = int(ctx)
		}
		catalog[id] = e
	}

	// encoding/json sorts map keys, so the committed file has stable,
	// reviewable ordering without a separate sort step. MarshalIndent keeps it
	// diffable (one model per line) instead of one unreviewable JSON line.
	b, err := json.MarshalIndent(catalog, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal catalog: %w", err)
	}

	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		return fmt.Errorf("locate gen.go")
	}
	out := filepath.Join(filepath.Dir(thisFile), "pricing.json")
	if err := os.WriteFile(out, append(b, '\n'), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", out, err)
	}

	fmt.Printf("pricing/gen: wrote %d models to %s\n", len(catalog), out)
	return nil
}
