package tools

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

// stubModels installs a lister standing in for main's discovery client.
func stubModels(t *testing.T, combos []ModelCombo, warnings []string, err error) {
	t.Helper()
	old := modelLister
	modelLister = func() ([]ModelCombo, []string, error) { return combos, warnings, err }
	t.Cleanup(func() { modelLister = old })
}

func TestModels(t *testing.T) {
	stubModels(t, []ModelCombo{
		{Name: "moonshot/kimi-k3"},
		{Name: "openai/gpt-5-mini", Input: 0.15, Output: 0.6},
	}, []string{"broken: HTTP 500"}, nil)

	// No filter: a cheap provider summary instead of a combo dump.
	r, _, err := run(t, "models", `{}`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(r, "2 providers, 2 combos") {
		t.Fatalf("provider summary: %q", r)
	}
	if !strings.Contains(r, "moonshot (1)") || !strings.Contains(r, "openai (1)") {
		t.Fatalf("provider counts: %q", r)
	}
	if !strings.Contains(r, "warnings:") || !strings.Contains(r, "HTTP 500") {
		t.Fatalf("provider warning missing: %q", r)
	}

	// A filter lists combos with their price per 1M tokens when known.
	r, _, _ = run(t, "models", `{"filter":"GPT"}`)
	if !strings.Contains(r, "openai/gpt-5-mini") || strings.Contains(r, "kimi") {
		t.Fatalf("filter: %q", r)
	}
	if !strings.Contains(r, "in $0.15 · out $0.6 per 1M tokens") {
		t.Fatalf("price hint missing: %q", r)
	}
	r, _, _ = run(t, "models", `{"filter":"nope"}`)
	if !strings.Contains(r, "no combo matches") {
		t.Fatalf("empty filter: %q", r)
	}
}

func TestModelsCap(t *testing.T) {
	// The filtered list is capped so a huge provider cannot flood the context.
	var combos []ModelCombo
	for i := 0; i < 120; i++ {
		combos = append(combos, ModelCombo{Name: fmt.Sprintf("p/m%d", i)})
	}
	stubModels(t, combos, nil, nil)
	r, _, err := run(t, "models", `{"filter":"m"}`)
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(r, "\np/m"); n > modelsMax {
		t.Fatalf("cap not applied: %d lines", n)
	}
	if !strings.Contains(r, "narrow with filter") {
		t.Fatalf("cap note missing: %q", r)
	}
}

func TestModelsUnavailable(t *testing.T) {
	// A lister failure is a tool error, not a silent empty list; without a
	// lister (no serve) the tool says so instead of panicking.
	stubModels(t, nil, nil, errors.New("boom"))
	if _, _, err := run(t, "models", `{}`); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("expected failure to surface, got %v", err)
	}
	stubModels(t, nil, nil, nil)
	modelLister = nil
	if _, _, err := run(t, "models", `{}`); err == nil || !strings.Contains(err.Error(), "requires yap serve") {
		t.Fatalf("expected unavailable error, got %v", err)
	}
}
