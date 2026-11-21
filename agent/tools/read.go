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

// readArgs follows the Read convention the common harnesses use (file_path +
// offset/limit), so a model's default "read a file" call lands correctly.
// `path` is kept as a deprecated alias for older sessions; `offset` is the
// 1-based start line and `limit` the line count. A trailing :START-END or
// :LINE suffix on the path is a convenience for pasted paths (`foo.go:18-22`)
// and is translated into offset/limit.
type readArgs struct {
	FilePath string `json:"file_path,omitempty" jsonschema:"description=path to the file to read; a trailing :START-END or :LINE suffix selects a 1-based line range"`
	Path     string `json:"path,omitempty" jsonschema:"description=deprecated alias for file_path"`
	Offset   int    `json:"offset,omitempty" jsonschema:"description=line number to start reading from (1-based); only provide when the file is too large to read at once"`
	Limit    int    `json:"limit,omitempty" jsonschema:"description=number of lines to read; only provide when the file is too large to read at once"`
}

func init() {
	Register("read",
		"Read a text file. Returns at most 2000 lines / 50KB. "+
			"Page a large file with offset (1-based start line) and limit (line count); "+
			"a truncated or paged result reports the file's total line count.",
		func(a *readArgs) (string, string, error) {
			path, offset, limit, explicit, err := resolveRead(a)
			if err != nil {
				return "", "", err
			}
			path = utils.ExpandHome(path)
			data, err := os.ReadFile(path)
			if err != nil {
				return "", "", err
			}
			lines := strings.Split(string(data), "\n")
			total := len(lines)

			start, end, truncated, err := lineWindow(total, offset, limit, explicit)
			if err != nil {
				return "", "", err
			}
			text := strings.Join(lines[start:end], "\n")
			if len(text) > readMaxBytes {
				text = capBytes(text, readMaxBytes)
				truncated = true
			}
			if truncated {
				text += fmt.Sprintf("\n[truncated: use offset/limit; file has %d lines total]", total)
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
	Gate("read", func(a *readArgs) string {
		p := a.FilePath
		if p == "" {
			p = a.Path
		}
		p, _ = splitPathRange(p)
		return p
	}, safety.SecretPathRule("reads a secret path"))
}

// resolveRead returns the path (with any :LINE suffix stripped), the
// offset/limit window to read, and whether the window came from an explicit
// :LINE/':START-END' suffix (as opposed to offset/limit paging). A suffix is an
// explicit selection and wins over any offset/limit; otherwise offset/limit
// pass through untouched. It never rejects a conflicting selector — the model
// fumbles that combination constantly, and the suffix is unambiguous, so
// normalizing here removes a whole class of self-inflicted errors.
func resolveRead(a *readArgs) (path string, offset, limit int, explicit bool, err error) {
	p := a.FilePath
	if p == "" {
		p = a.Path
	}
	if strings.TrimSpace(p) == "" {
		return "", 0, 0, false, fmt.Errorf("file_path is required (the file to read)")
	}
	path, suffix := splitPathRange(p)
	if suffix == "" {
		return path, a.Offset, a.Limit, false, nil
	}
	first, last, err := parseLineRange(suffix)
	if err != nil {
		return path, 0, 0, false, err
	}
	offset = first
	if last > 0 {
		limit = last - first + 1
	} else {
		limit = 0 // open-ended: read to EOF (capped at readMaxLines)
	}
	return path, offset, limit, true, nil
}

// lineWindow returns the 0-based [start,end) line window for a read, given
// the file's total line count and the caller's offset/limit (offset is
// 1-based; limit 0 means "to EOF"). For an explicit range (a :START-END
// suffix), truncated means the window was longer than the line cap; for
// offset/limit paging it means more lines exist past the returned page.
func lineWindow(total, offset, limit int, explicit bool) (start, end int, truncated bool, err error) {
	start = offset - 1
	if start < 0 {
		start = 0
	}
	if start >= total {
		return 0, 0, false, fmt.Errorf("offset %d past end of file (%d lines)", offset, total)
	}
	if explicit {
		end = start + limit
		if limit <= 0 {
			end = total // open-ended: read to EOF
		} else if end > total {
			end = total
		}
		if end-start > readMaxLines {
			end = start + readMaxLines
			truncated = true
		}
		return start, end, truncated, nil
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
