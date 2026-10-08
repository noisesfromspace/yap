package tools

import (
	"fmt"
	"strconv"
	"strings"
)

// ModelCombo is one discoverable provider/model pair, carrying its price when
// known (USD per 1M tokens, 0 when unknown). The `models` tool uses it to let
// a session weigh options without a separate pricing lookup.
type ModelCombo struct {
	Name   string
	Input  float64
	Output float64
}

// modelLister is main's discovery client (the `yap models` command), which
// knows the providers in ~/.config/yap.json and cannot be imported from here.
// The serve loop installs it with SetModelLister, so the tool, the picker and
// the CLI list exactly the same combos from one implementation.
var modelLister func() (combos []ModelCombo, warnings []string, err error)

// SetModelLister installs the combo discovery client for the `models` tool.
func SetModelLister(f func() ([]ModelCombo, []string, error)) { modelLister = f }

// modelsMax caps the combos handed to the model for one filter. A provider
// like openrouter answers with hundreds of models; the tool is meant to be
// narrowed, not dumped.
const modelsMax = 100

type modelsArgs struct {
	Filter string `json:"filter,omitempty" jsonschema:"description=case-insensitive substring matched against the provider/model combos, e.g. \"gpt-5\" or \"anthropic/\"; omit to list the configured providers instead"`
}

func init() {
	Register("models", "List the provider/model combos available to :YapChangeModel and to a subagent's `model` argument. With no filter, returns a summary of the configured providers and how many models each has; with a filter, lists up to 100 matching combos and their price per 1M tokens when known. Providers that do not answer are reported as warnings. Prefer a filter over listing everything.", func(a *modelsArgs) (string, string, error) {
		if modelLister == nil {
			return "", "", fmt.Errorf("models requires yap serve")
		}
		combos, warnings, err := modelLister()
		if err != nil {
			return "", "", fmt.Errorf("list models: %w", err)
		}
		filter := strings.ToLower(strings.TrimSpace(a.Filter))
		var b strings.Builder
		if filter == "" {
			if len(combos) == 0 {
				b.WriteString("no combos available")
			} else {
				summary := providerSummary(combos)
				fmt.Fprintf(&b, "%d providers, %d combos (filter to list one provider's models):\n", len(summary), len(combos))
				for _, line := range summary {
					b.WriteString(line + "\n")
				}
			}
		} else {
			var matches []ModelCombo
			for _, combo := range combos {
				if strings.Contains(strings.ToLower(combo.Name), filter) {
					matches = append(matches, combo)
				}
			}
			switch {
			case len(matches) == 0:
				fmt.Fprintf(&b, "no combo matches %q (%d available)", filter, len(combos))
			case len(matches) > modelsMax:
				for _, combo := range matches[:modelsMax] {
					b.WriteString(comboLine(combo))
				}
				fmt.Fprintf(&b, "... %d more match; narrow with filter\n", len(matches)-modelsMax)
			default:
				for _, combo := range matches {
					b.WriteString(comboLine(combo))
				}
			}
		}
		if len(warnings) > 0 {
			b.WriteString("\nwarnings:\n" + strings.Join(warnings, "\n") + "\n")
		}
		return strings.TrimSpace(b.String()), "", nil
	})
}

// providerSummary collapses the sorted combo list into "provider (count)" lines,
// one per distinct provider in list order.
func providerSummary(combos []ModelCombo) []string {
	var summary []string
	cur, n := "", 0
	flush := func() {
		if cur != "" {
			summary = append(summary, fmt.Sprintf("%s (%d)", cur, n))
		}
	}
	for _, c := range combos {
		p := c.Name
		if i := strings.IndexByte(p, '/'); i >= 0 {
			p = p[:i]
		}
		if p != cur {
			flush()
			cur, n = p, 0
		}
		n++
	}
	flush()
	return summary
}

// comboLine renders one combo with a price hint when known: `in $X · out $Y
// per 1M tokens`. A zero pair means unknown and is left off rather than shown
// as $0.
func comboLine(c ModelCombo) string {
	if c.Input <= 0 && c.Output <= 0 {
		return c.Name + "\n"
	}
	return fmt.Sprintf("%s  [in %s · out %s per 1M tokens]\n", c.Name, money(c.Input), money(c.Output))
}

func money(f float64) string {
	return "$" + strconv.FormatFloat(f, 'g', -1, 64)
}
