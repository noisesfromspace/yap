package tools

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// pi's edit semantics (doc: R12 result policy): every oldText is matched
// against the ORIGINAL content, must occur exactly once, and edits must
// not overlap. The result is a short confirmation; the unified diff is
// display-only via the ui payload.

type editOp struct {
	OldText string `json:"oldText"`
	NewText string `json:"newText"`
}

func init() {
	Register(&Tool{
		Name: "edit",
		Description: "Make precise file edits with exact text replacement, including multiple " +
			"disjoint edits in one call. Each edits[].oldText is matched against the original " +
			"file, must occur exactly once (include more context if ambiguous), and must not " +
			"overlap another edit. To create files use write.",
		Schema: `{"type":"object","properties":{
			"path":{"type":"string","description":"path to the file (relative or absolute)"},
			"edits":{"type":"array","description":"one or more targeted replacements","items":{"type":"object","properties":{
				"oldText":{"type":"string","description":"exact text, unique in the file, not overlapping other edits"},
				"newText":{"type":"string","description":"replacement text"}},"required":["oldText","newText"]}}},
			"required":["path","edits"]}`,
		Run: func(args json.RawMessage) (string, string, error) {
			var a struct {
				Path  string   `json:"path"`
				Edits []editOp `json:"edits"`
			}
			if err := json.Unmarshal(args, &a); err != nil {
				return "", "", err
			}
			if len(a.Edits) == 0 {
				return "", "", fmt.Errorf("no edits given")
			}
			data, err := os.ReadFile(a.Path)
			if err != nil {
				if os.IsNotExist(err) {
					return "", "", fmt.Errorf("file does not exist: %s (use write to create it)", a.Path)
				}
				return "", "", err
			}
			orig := string(data)

			type span struct {
				start, end int
				newText    string
			}
			spans := make([]span, 0, len(a.Edits))
			for i, e := range a.Edits {
				if e.OldText == "" {
					return "", "", fmt.Errorf("edits[%d].oldText is empty", i)
				}
				n := strings.Count(orig, e.OldText)
				if n == 0 {
					return "", "", fmt.Errorf("edits[%d].oldText not found in %s", i, a.Path)
				}
				if n > 1 {
					return "", "", fmt.Errorf("edits[%d].oldText matches %d times in %s; include more surrounding context", i, n, a.Path)
				}
				idx := strings.Index(orig, e.OldText)
				for _, s := range spans {
					if idx < s.end && idx+len(e.OldText) > s.start {
						return "", "", fmt.Errorf("edits[%d].oldText overlaps another edit; merge them into one edit", i)
					}
				}
				spans = append(spans, span{idx, idx + len(e.OldText), e.NewText})
			}

			// Rebuild from spans against the ORIGINAL content — never
			// sequentially, or an oldText could match inside an earlier
			// edit's newText.
			sort.Slice(spans, func(i, j int) bool { return spans[i].start < spans[j].start })
			var b strings.Builder
			pos := 0
			for _, s := range spans {
				b.WriteString(orig[pos:s.start])
				b.WriteString(s.newText)
				pos = s.end
			}
			b.WriteString(orig[pos:])
			content := b.String()

			if err := os.WriteFile(a.Path, []byte(content), 0o644); err != nil {
				return "", "", err
			}
			ui := unifiedDiff(a.Path, orig, content)
			return fmt.Sprintf("Successfully replaced %d block(s) in %s.", len(a.Edits), a.Path), ui, nil
		},
	})
}
