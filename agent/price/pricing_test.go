package price

import (
	"math"
	"testing"
)

// The catalog is generated and committed; these tests pin the lookups the
// agent actually relies on so a bad regeneration fails loudly.
func TestCatalogLoads(t *testing.T) {
	if len(catalog) < 1000 {
		t.Fatalf("catalog suspiciously small: %d models", len(catalog))
	}
}

func TestLookup(t *testing.T) {
	cases := []struct {
		provider, model string
		wantInput       float64
		wantOutput      float64
		wantCacheRead   float64
		wantCacheWrite  float64
		wantCtx         int
	}{
		{"openai", "gpt-4o", 2.5, 10, 1.25, 0, 128000},
		{"moonshot", "kimi-k3", 3, 15, 0.3, 0, 1048576},
		{"deepseek", "deepseek-chat", 0.28, 0.42, 0.028, 0, 131072},
		{"", "claude-sonnet-4-5", 3, 15, 0.3, 3.75, 200000},
	}
	for _, c := range cases {
		info, ok := Lookup(c.provider, c.model)
		if !ok {
			t.Errorf("Lookup(%q, %q) missed", c.provider, c.model)
			continue
		}
		if info.Input != c.wantInput || info.Output != c.wantOutput || info.ContextWindow != c.wantCtx {
			t.Errorf("Lookup(%q, %q) = %+v, want {%v %v %d}",
				c.provider, c.model, info, c.wantInput, c.wantOutput, c.wantCtx)
		}
		if info.CacheRead != c.wantCacheRead || info.CacheWrite != c.wantCacheWrite {
			t.Errorf("Lookup(%q, %q) cache = {read %v write %v}, want {read %v write %v}",
				c.provider, c.model, info.CacheRead, info.CacheWrite, c.wantCacheRead, c.wantCacheWrite)
		}
	}
}

// TestLookupBareFallback: a provider-prefixed model id (OpenRouter style)
// resolves through its bare suffix, and Google's two provider names both
// reach the catalog's "gemini/" keys.
func TestLookupBareFallback(t *testing.T) {
	if info, ok := Lookup("openrouter", "openai/gpt-4o"); !ok || info.ContextWindow != 128000 {
		t.Fatalf("bare-id fallback: %+v ok=%v", info, ok)
	}
	if info, ok := Lookup("google", "gemini-2.5-pro"); !ok || info.Input <= 0 {
		t.Fatalf("google provider name: %+v ok=%v", info, ok)
	}
}

func TestLookupMiss(t *testing.T) {
	if _, ok := Lookup("nonexistent", "not-a-real-model-xyz"); ok {
		t.Fatal("expected a miss for an unknown model")
	}
}

// TestCost pins the per-step pricing math: uncached input, cache reads and
// writes, and output each at their own rate, with cache falling back to the
// input rate when the catalog has no separate cache price.
func TestCost(t *testing.T) {
	info := Info{Input: 3, Output: 15, CacheRead: 0.3, CacheWrite: 3.75}
	// 1000 uncached + 2000 read + 500 write + 100 output.
	want := (1000*3 + 2000*0.3 + 500*3.75 + 100*15) / 1e6
	if got := Cost(info, 1000, 2000, 500, 100); math.Abs(got-want) > 1e-12 {
		t.Fatalf("Cost = %v, want %v", got, want)
	}

	// No cache rates: cached tokens bill at the input rate, never free.
	plain := Info{Input: 2, Output: 8}
	wantPlain := (1000*2 + 500*2 + 100*8) / 1e6
	if got := Cost(plain, 1000, 500, 0, 100); math.Abs(got-wantPlain) > 1e-12 {
		t.Fatalf("Cost(fallback) = %v, want %v", got, wantPlain)
	}
}
