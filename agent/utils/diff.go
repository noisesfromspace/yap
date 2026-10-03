package utils

import (
	"fmt"
	"strings"

	"github.com/sergi/go-diff/diffmatchpatch"
)

// UnifiedDiff returns unified-diff output for old vs new content of path,
// or "" when the inputs are identical or too large. Display-only
// (yap:ui), never sent to the model — any imperfection degrades
// gracefully. Self-contained (sergi/go-diff, line mode).
func UnifiedDiff(path, oldContent, newContent string) string {
	const maxDiffBytes = 512 * 1024
	if oldContent == newContent || len(oldContent)+len(newContent) > maxDiffBytes {
		return ""
	}
	dmp := diffmatchpatch.New()
	c1, c2, lineArray := dmp.DiffLinesToChars(oldContent, newContent)
	diffs := dmp.DiffCharsToLines(dmp.DiffMain(c1, c2, false), lineArray)

	type l struct {
		typ  diffmatchpatch.Operation
		text string
	}
	var ls []l
	for _, d := range diffs {
		parts := strings.SplitAfter(d.Text, "\n")
		if parts[len(parts)-1] == "" {
			parts = parts[:len(parts)-1]
		}
		for _, p := range parts {
			ls = append(ls, l{d.Type, strings.TrimSuffix(p, "\n")})
		}
	}

	var changed []int
	for i, x := range ls {
		if x.typ != diffmatchpatch.DiffEqual {
			changed = append(changed, i)
		}
	}
	if len(changed) == 0 {
		return ""
	}

	const ctx = 3
	var out strings.Builder
	fmt.Fprintf(&out, "--- a/%s\n+++ b/%s\n", path, path)

	start := max(changed[0]-ctx, 0)
	for ci := 0; ci < len(changed); {
		// Extend the hunk while the next change's context window would
		// overlap this one (a gap of fewer than 2*ctx equal lines).
		end := changed[ci] + ctx + 1
		j := ci
		for j+1 < len(changed) && changed[j+1] < changed[j]+2*ctx+1 {
			j++
			end = changed[j] + ctx + 1
		}
		end = min(end, len(ls))

		oldStart, newStart := 1, 1
		for k := 0; k < start; k++ {
			if ls[k].typ != diffmatchpatch.DiffInsert {
				oldStart++
			}
			if ls[k].typ != diffmatchpatch.DiffDelete {
				newStart++
			}
		}
		oldCount, newCount := 0, 0
		for k := start; k < end; k++ {
			switch ls[k].typ {
			case diffmatchpatch.DiffEqual:
				oldCount++
				newCount++
			case diffmatchpatch.DiffDelete:
				oldCount++
			case diffmatchpatch.DiffInsert:
				newCount++
			}
		}
		fmt.Fprintf(&out, "@@ -%d,%d +%d,%d @@\n", oldStart, oldCount, newStart, newCount)
		for k := start; k < end; k++ {
			switch ls[k].typ {
			case diffmatchpatch.DiffEqual:
				out.WriteString(" " + ls[k].text + "\n")
			case diffmatchpatch.DiffDelete:
				out.WriteString("-" + ls[k].text + "\n")
			case diffmatchpatch.DiffInsert:
				out.WriteString("+" + ls[k].text + "\n")
			}
		}

		if j+1 >= len(changed) {
			break
		}
		start = max(changed[j+1]-ctx, end)
		ci = j + 1
	}
	return strings.TrimRight(out.String(), "\n")
}
