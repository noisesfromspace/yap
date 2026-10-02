package tools

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// pi's edit semantics (doc: R12 result policy): every oldText is matched
// against the ORIGINAL content, must occur exactly once, and edits must
// not overlap. The result is a short confirmation; the unified diff is
// display-only via the ui payload.

type editArgs struct {
	Path  string `json:"path" jsonschema:"description=path to the file (relative or absolute)"`
	Edits []struct {
		OldText string `json:"oldText" jsonschema:"description=exact text; must be unique in the file and not overlap other edits"`
		NewText string `json:"newText" jsonschema:"description=replacement text"`
	} `json:"edits" jsonschema:"description=one or more targeted replacements"`
}

func init() {
	Register("edit",
		"Make precise file edits with exact text replacement, including multiple "+
			"disjoint edits in one call. Runs immediately with no confirmation. Each edits[].oldText is matched against the original "+
			"file, must occur exactly once (include more context if ambiguous), and must not "+
			"overlap another edit. To create files use write.",
		func(a *editArgs) (string, string, error) {
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
		})
}
