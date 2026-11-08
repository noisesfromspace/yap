package tools

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/utils"
)

// Same limits as pi's read tool (doc: R-tool-region result policy).
const (
	readMaxLines = 2000
	readMaxBytes = 50 * 1024
)

type readArgs struct {
	Path   string `json:"path" jsonschema:"description=file to read; a trailing :START-END (or :LINE) suffix selects that 1-based inclusive line range"`
	Offset int    `json:"offset,omitempty" jsonschema:"description=first line to return (1-based)"`
	Limit  int    `json:"limit,omitempty" jsonschema:"description=maximum number of lines"`
	Range  string `json:"range,omitempty" jsonschema:"description=1-based inclusive line range as START-END, START, START- or -END (e.g. 18-22)"`
}

func init() {
	Register("read",
		"Read a text file. Returns at most 2000 lines / 50KB. Select lines with `range` (\"18-22\"), a `path:18-22` suffix, or `offset`/`limit`; a truncated or paged result reports the file's total line count.",
		func(a *readArgs) (string, string, error) {
			rng, err := resolveRange(a)
			if err != nil {
				return "", "", err
			}
			a.Path = utils.ExpandHome(a.Path)
			data, err := os.ReadFile(a.Path)
			if err != nil {
				return "", "", err
			}
			lines := strings.Split(string(data), "\n")
			total := len(lines)

			start, end, truncated, err := lineWindow(total, rng, a.Offset, a.Limit)
			if err != nil {
				return "", "", err
			}
			text := strings.Join(lines[start:end], "\n")
			if len(text) > readMaxBytes {
				text = capBytes(text, readMaxBytes)
				truncated = true
			}
			if truncated {
				text += fmt.Sprintf("\n[truncated: use offset/limit or range; file has %d lines total]", total)
			} else if start > 0 || end < total {
				// A page that fit: report the window so the model knows where it
				// is and whether it has reached the end without a truncation note.
				text += fmt.Sprintf("\n[lines %d-%d of %d]", start+1, end, total)
			}
			return text, "", nil
		})
	// Secret files are approvable, not silently read: pause for Run/Deny.
	// Inspect only the path, with any :LINE-range suffix stripped, so a
	// ranged read of a secret file still trips the rule.
	Gate("read", func(a *readArgs) string { p, _ := splitPathRange(a.Path); return p }, safety.SecretPathRule("reads a secret path"))
}

// resolveRange strips any :START-END suffix off the path and returns the
// range to apply (from the `range` field or that suffix; "" when neither is
// set), rejecting ambiguous combinations with offset/limit.
func resolveRange(a *readArgs) (string, error) {
	path, pathRange := splitPathRange(a.Path)
	a.Path = path

	explicit := a.Offset != 0 || a.Limit != 0
	switch {
	case a.Range != "" && pathRange != "":
		return "", fmt.Errorf("read: line range given both in `range` and as a path suffix")
	case (a.Range != "" || pathRange != "") && explicit:
		return "", fmt.Errorf("read: `range` and `offset`/`limit` are mutually exclusive")
	}
	if a.Range != "" {
		return a.Range, nil
	}
	return pathRange, nil
}

// lineWindow returns the 0-based [start,end) line window for a read, given
// the file's total line count and the caller's selection. rng is a parsed
// 1-based inclusive range ("" means offset/limit paging); a range end past
// EOF clamps to the last line, while a start past EOF is an error. truncated
// reports a line cap (not the byte cap applied later).
func lineWindow(total int, rng string, offset, limit int) (start, end int, truncated bool, err error) {
	if rng != "" {
		first, last, err := parseLineRange(rng)
		if err != nil {
			return 0, 0, false, err
		}
		start = first - 1
		if start < 0 {
			start = 0
		}
		if start >= total {
			return 0, 0, false, fmt.Errorf("offset %d past end of file (%d lines)", first, total)
		}
		end = last
		if end <= 0 || end > total {
			end = total
		}
		if end-start > readMaxLines {
			end = start + readMaxLines
			truncated = true
		}
		return start, end, truncated, nil
	}

	start = offset - 1
	if start < 0 {
		start = 0
	}
	if start >= total {
		return 0, 0, false, fmt.Errorf("offset %d past end of file (%d lines)", offset, total)
	}
	if limit <= 0 || limit > readMaxLines {
		limit = readMaxLines
	}
	end = start + limit
	if end > total {
		end = total
	}
	return start, end, start+limit < total, nil
}

// splitPathRange splits a trailing :START-END / :LINE range off a path,
// returning the bare path and the range text ("" when there is none). A
// numeric suffix is always treated as a range (so a file literally named
// `foo:18` is unreachable this way); any other colon — a Windows drive or a
// `foo:bar` name — is left intact.
func splitPathRange(p string) (path, rng string) {
	i := strings.LastIndexByte(p, ':')
	if i < 0 || i == len(p)-1 {
		return p, ""
	}
	suffix := p[i+1:]
	if _, _, err := parseLineRange(suffix); err != nil {
		return p, ""
	}
	return p[:i], suffix
}

// parseLineRange parses a 1-based inclusive line range of the forms "18-22",
// "18" (one line), "18-" (to EOF) or "-22" (from the start). last is 0 for an
// open-ended range (read to EOF).
func parseLineRange(s string) (first, last int, err error) {
	lo, hi, dashed := strings.Cut(s, "-")
	if dashed {
		if lo == "" && hi == "" {
			return 0, 0, fmt.Errorf("invalid line range %q", s)
		}
		if strings.Contains(hi, "-") {
			return 0, 0, fmt.Errorf("invalid line range %q", s)
		}
	}
	first, last = 1, 0
	if lo != "" {
		if first, err = parseLineNum(lo); err != nil {
			return 0, 0, fmt.Errorf("invalid line range %q: %v", s, err)
		}
	}
	if hi != "" {
		if last, err = parseLineNum(hi); err != nil {
			return 0, 0, fmt.Errorf("invalid line range %q: %v", s, err)
		}
	}
	if !dashed {
		last = first
	}
	if last > 0 && first > last {
		return 0, 0, fmt.Errorf("invalid line range %q: start %d after end %d", s, first, last)
	}
	return first, last, nil
}

// parseLineNum parses a strictly positive line number.
func parseLineNum(s string) (int, error) {
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("invalid line number %q", s)
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 {
		return 0, fmt.Errorf("invalid line number %q", s)
	}
	return n, nil
}
