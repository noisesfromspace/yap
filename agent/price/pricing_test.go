package price

import "testing"

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
		wantCtx         int
	}{
		{"openai", "gpt-4o", 2.5, 10, 128000},
		{"moonshot", "kimi-k3", 3, 15, 1048576},
		{"deepseek", "deepseek-chat", 0.28, 0.42, 131072},
		{"", "claude-sonnet-4-5", 3, 15, 1000000},
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
