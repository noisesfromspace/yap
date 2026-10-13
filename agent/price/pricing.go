// Package price bundles a committed per-model catalog (pricing.json) so cost
// and context-window display work without per-model entries in
// ~/.config/yap/settings.json. Prices are USD per 1M tokens; `context` is the
// model's context window in tokens.
//
// The catalog is generated from LiteLLM's community-maintained
// model_prices_and_context_window.json (direct-provider pricing), trimmed
// to language models with a numeric per-token price. It is committed so normal
// builds and runs stay offline; refresh it with:
//
//	go generate ./agent/price
package price

import (
	_ "embed"
	"encoding/json"
	"strings"
)

// Info is one model's catalog entry. Input/Output are USD per 1M tokens.
// CacheRead/CacheWrite are USD per 1M cached-input tokens (0 when the
// upstream catalog lists no separate cache rate); a zero rate falls back to
// the input rate in Cost so cached tokens are never silently free.
type Info struct {
	Input         float64 `json:"input"`
	Output        float64 `json:"output"`
	CacheRead     float64 `json:"cache_read,omitempty"`
	CacheWrite    float64 `json:"cache_write,omitempty"`
	ContextWindow int     `json:"context,omitempty"`
}

//go:generate go run gen.go

//go:embed pricing.json
var raw []byte

var catalog = func() map[string]Info {
	var m map[string]Info
	if err := json.Unmarshal(raw, &m); err != nil {
		// pricing.json is generated and committed; a parse failure here is
		// a build bug, not a runtime condition worth recovering from.
		panic("pricing: parse pricing.json: " + err.Error())
	}
	return m
}()

// Cost prices one generation step. prompt is uncached input, cacheRead and
// cacheWrite are the cached-input portions (cacheWrite is Anthropic's cache
// creation), and completion is output tokens (reasoning included). A missing
// cache rate falls back to the input rate so cache traffic is never free.
func Cost(info Info, prompt, cacheRead, cacheWrite, completion int) float64 {
	read := info.CacheRead
	if read <= 0 {
		read = info.Input
	}
	write := info.CacheWrite
	if write <= 0 {
		write = info.Input
	}
	return float64(prompt)/1e6*info.Input +
		float64(cacheRead)/1e6*read +
		float64(cacheWrite)/1e6*write +
		float64(completion)/1e6*info.Output
}

// Lookup returns the catalog entry for a provider/model combo. It tries the
// model id verbatim, then prefixed with the provider, then the bare id when
// the model is itself provider-prefixed (OpenRouter style). Google's API is
// listed under "gemini/" in the catalog, so both provider names are tried.
// The catalog is lowercase, so lookups are case-insensitive.
func Lookup(provider, model string) (Info, bool) {
	model = strings.ToLower(model)
	provider = strings.ToLower(provider)
	candidates := make([]string, 0, 4)
	candidates = append(candidates, model)
	if provider != "" {
		candidates = append(candidates, provider+"/"+model)
		switch provider {
		case "google":
			candidates = append(candidates, "gemini/"+model)
		case "gemini":
			candidates = append(candidates, "google/"+model)
		}
	}
	if i := strings.LastIndexByte(model, '/'); i >= 0 {
		candidates = append(candidates, model[i+1:])
	}
	for _, c := range candidates {
		if info, ok := catalog[c]; ok {
			return info, true
		}
	}
	return Info{}, false
}
