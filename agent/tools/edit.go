package tools

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/utils"
)

// Every edit matches the ORIGINAL content and edits must not overlap. A failed
// batch writes nothing. The unified diff is display-only via the ui payload.

type editArgs struct {
	Path  string `json:"path" jsonschema:"description=path to the file (relative or absolute)"`
	Edits []struct {
		OldText string `json:"oldText" jsonschema:"description=exact nonempty text to replace; must occur exactly once in the file"`
		NewText string `json:"newText" jsonschema:"description=replacement text; empty string deletes oldText"`
	} `json:"edits" jsonschema:"description=one or more non-overlapping exact replacements matched against the original file"`
}

func init() {
	Register("edit",
		"Replace exact text in an existing file. Each oldText must occur exactly once; include surrounding text if necessary. "+
			"Use newText as the replacement (empty string deletes). Multiple edits must not overlap and all match the original file; "+
			"if any edit fails, none are applied. Editing a secret path (~/.ssh, ~/.aws, /run/agenix, ...) "+
			"or outside the project pauses for user approval. To create files use write.",
		func(a *editArgs) (string, string, error) { return runEdit(a) })
	// Secret paths are approvable, not silently edited: pause for Run/Deny.
	// A target outside the writable allowlist (project + assets) also pauses.
	Gate("edit", func(a *editArgs) string { return a.Path },
		safety.SecretPathRule("edits a secret path"),
		safety.OutsideWritableRule("edit target outside allowed write paths (pre-run)"))
}

// Diagnostics return line numbers, not nearby file contents.
func matchLines(content, text string, limit, total int) string {
	var lines []string
	for start := 0; start < len(content); {
		idx := strings.Index(content[start:], text)
		if idx < 0 {
			break
		}
		pos := start + idx
		lines = append(lines, fmt.Sprint(strings.Count(content[:pos], "\n")+1))
		if len(lines) == limit {
			break
		}
		start = pos + len(text)
	}
	if total > len(lines) {
		return strings.Join(lines, ", ") + ", ..."
	}
	return strings.Join(lines, ", ")
}

func spanLines(content string, start, end int) string {
	first := strings.Count(content[:start], "\n") + 1
	last := strings.Count(content[:end], "\n") + 1
	if end > start && content[end-1] == '\n' {
		last--
	}
	if first == last {
		return fmt.Sprint(first)
	}
	return fmt.Sprintf("%d-%d", first, last)
}

func editNotFoundHint(content, old string) string {
	if (strings.Contains(old, "\n") && strings.Contains(content, strings.ReplaceAll(old, "\n", "\r\n"))) ||
		(strings.Contains(old, "\r\n") && strings.Contains(content, strings.ReplaceAll(old, "\r\n", "\n"))) {
		return "; line endings differ (LF vs CRLF)"
	}
	first := strings.SplitN(old, "\n", 2)[0]
	if strings.TrimSpace(first) == "" {
		return ""
	}
	var candidates []string
	whitespaceDiff := false
	for i, line := range strings.Split(content, "\n") {
		if strings.TrimSpace(line) == strings.TrimSpace(first) {
			whitespaceDiff = whitespaceDiff || line != first
			candidates = append(candidates, fmt.Sprint(i+1))
			if len(candidates) == 5 {
				break
			}
		}
	}
	if len(candidates) > 0 {
		if whitespaceDiff {
			return "; first line matches with different surrounding whitespace at line(s) " + strings.Join(candidates, ", ")
		}
		if strings.Contains(old, "\n") {
			return "; first line found at line(s) " + strings.Join(candidates, ", ") + " but full block differs"
		}
	}
	return ""
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
		if e.OldText == "" {
			return "", "", fmt.Errorf("edits[%d].oldText is empty; no edits applied", i)
		}
		n := strings.Count(orig, e.OldText)
		if n == 0 {
			return "", "", fmt.Errorf("edits[%d].oldText not found in %s%s; no edits applied", i, a.Path, editNotFoundHint(orig, e.OldText))
		}
		if n > 1 {
			return "", "", fmt.Errorf("edits[%d].oldText matches %d times in %s at lines %s; include more surrounding context; no edits applied", i, n, a.Path, matchLines(orig, e.OldText, 5, n))
		}
		idx := strings.Index(orig, e.OldText)
		s := span{idx, idx + len(e.OldText), e.NewText}
		for j, prev := range spans {
			if s.start < prev.end && s.end > prev.start {
				return "", "", fmt.Errorf("edits[%d] (lines %s) overlaps another edit (edits[%d], lines %s); merge them into one edit; no edits applied", i, spanLines(orig, s.start, s.end), j, spanLines(orig, prev.start, prev.end))
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
