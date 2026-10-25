package tools

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/utils"
)

// pi's edit semantics (doc: R-tool-region result policy): every edit is
// matched against the ORIGINAL content and edits must not overlap. The result
// is a short confirmation; the unified diff is display-only via the ui
// payload.
//
// Two forms per edit:
//   - oldText/newText: exact substring replacement (oldText unique).
//   - from/to/newText: replace, or delete (newText empty), the span from the
//     line `from` (a complete line, indentation included, matched uniquely)
//     through the line `to` (the first complete line equal to `to` at or
//     after `from`; "" or "<eof>" means end of file). Matching `to` by its
//     full line — indentation included — is what makes a closing brace
//     unambiguous inside nested blocks.

type editArgs struct {
	Path  string `json:"path" jsonschema:"description=path to the file (relative or absolute)"`
	Edits []struct {
		OldText string `json:"oldText,omitempty" jsonschema:"description=exact text to replace; must be unique in the file and not overlap other edits. Use with newText for a targeted replacement"`
		NewText string `json:"newText,omitempty" jsonschema:"description=replacement text; omit to delete"`
		From    string `json:"from,omitempty" jsonschema:"description=start of a span to replace or delete: a complete line (indentation included) that matches exactly once in the file. Mutually exclusive with oldText"`
		To      string `json:"to,omitempty" jsonschema:"description=end of the span (inclusive): a complete line that is the first such line at or after from; omit or set to <eof> for end of file"`
	} `json:"edits" jsonschema:"description=one or more targeted replacements"`
}

func init() {
	Register("edit",
		"Make precise file edits, including multiple disjoint edits in one call. Each edit is one of two forms: "+
			"(1) oldText/newText — exact substring replacement; oldText must occur exactly once. "+
			"(2) from/to/newText — replace or delete (newText empty) the span from a unique `from` line through a `to` line, or to end of file when `to` is omitted or `<eof>`. "+
			"`from` and `to` match complete lines including indentation, so a closing brace is matched by its indentation and nested blocks are unambiguous. "+
			"Editing a secret path (~/.ssh, ~/.aws, /run/agenix, ...) or outside the project pauses for user approval. To create files use write.",
		func(a *editArgs) (string, string, error) { return runEdit(a) })
	// Secret paths are approvable, not silently edited: pause for Run/Deny.
	// A target outside the writable allowlist (project + assets) also pauses.
	Gate("edit", func(a *editArgs) string { return a.Path },
		safety.SecretPathRule("edits a secret path"),
		safety.OutsideWritableRule("edit target outside allowed write paths (pre-run)"))
}

func runEdit(a *editArgs) (string, string, error) {
	if len(a.Edits) == 0 {
		return "", "", fmt.Errorf("no edits given")
	}
	a.Path = utils.ToolPath(a.Path)
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
		var s span
		switch {
		case e.OldText != "" && e.From != "":
			return "", "", fmt.Errorf("edits[%d] sets both oldText and from; use one form", i)
		case e.OldText != "":
			n := strings.Count(orig, e.OldText)
			if n == 0 {
				return "", "", fmt.Errorf("edits[%d].oldText not found in %s", i, a.Path)
			}
			if n > 1 {
				return "", "", fmt.Errorf("edits[%d].oldText matches %d times in %s; include more surrounding context", i, n, a.Path)
			}
			idx := strings.Index(orig, e.OldText)
			s = span{idx, idx + len(e.OldText), e.NewText}
		case e.From != "":
			start, end, err := utils.ResolveSpan(orig, e.From, e.To)
			if err != nil {
				return "", "", fmt.Errorf("edits[%d]: %w", i, err)
			}
			// The span includes the to line's trailing newline, so a
			// replacement should too — otherwise the next line glues on.
			nt := e.NewText
			if nt != "" && !strings.HasSuffix(nt, "\n") {
				nt += "\n"
			}
			s = span{start, end, nt}
		default:
			return "", "", fmt.Errorf("edits[%d].oldText is empty (set oldText or from)", i)
		}
		for _, prev := range spans {
			if s.start < prev.end && s.end > prev.start {
				return "", "", fmt.Errorf("edits[%d] overlaps another edit; merge them into one edit", i)
			}
		}
		spans = append(spans, s)
	}

	// Rebuild from spans against the ORIGINAL content — never sequentially,
	// or an oldText could match inside an earlier edit's newText.
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
	ui := utils.UnifiedDiff(a.Path, orig, content)
	result := fmt.Sprintf("Successfully replaced %d edit(s) in %s.", len(a.Edits), a.Path)
	return result, ui, nil
}
