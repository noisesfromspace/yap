// Package document is the Go structural parser for yap session transcripts.
//
// It is the Go counterpart of the Lua scanner in
// lua/harness/model/structure.lua: one forward pass that resolves fences,
// multi-line HTML comments and yap:tool/yap:* marker regions, then the same
// recovery for an unclosed tool region. The two implementations are locked
// together by the shared fixtures in tests/transcript_cases.json (see
// document_test.go and yap_transcript_conformance_test.lua), so neither can
// drift on fence-, comment- or marker-aware boundaries.
package document

import (
	"regexp"
	"sort"
	"strings"

	"boers.email/yap/agent/render"
)

// Document is a structural parse of a session transcript. Line numbers are
// 1-based; Finish/HeaderFinish/UIStart/UIFinish are inclusive, and 0 means
// "absent" (an unfinished region has no finish). This mirrors the ranges the
// Lua parser exposes, not LSP's zero-based UTF-16 positions.
type Document struct {
	Lines       []string  `json:"lines"`
	Headings    []Heading `json:"headings"`
	Regions     []Region  `json:"regions"`
	Frontmatter int       `json:"frontmatter"`
}

// Heading is a message boundary: a `# @role` line.
type Heading struct {
	Role string `json:"role"`
	Line int    `json:"line"`
}

// Region is a structural region (tool, thinking, error, ...). Unclosed
// regions carry no Finish unless the recovery in view() bounded them at an
// inner heading, in which case Unclosed is true.
type Region struct {
	Kind         string `json:"kind"`
	Start        int    `json:"start"`
	Finish       int    `json:"finish,omitempty"`
	HeaderFinish int    `json:"header_finish,omitempty"`
	UIStart      int    `json:"ui_start,omitempty"`
	UIFinish     int    `json:"ui_finish,omitempty"`
	Unclosed     bool   `json:"unclosed,omitempty"`
}

var (
	dashLineRe     = regexp.MustCompile(`^---\s*$`)
	closeCommentRe = regexp.MustCompile(`^-->\s*$`)
	commentOpenRe  = regexp.MustCompile(`^<!--.*yap:[A-Za-z]+\s*$`)
	uiOpenRe       = regexp.MustCompile(`^<!-- yap:ui -->\s*$`)
	markerKindRe   = regexp.MustCompile(`yap:([A-Za-z]+)`)
)

// scan holds the mutable forward-pass state, mirroring structure.lua's ctx.
type scan struct {
	headings    []Heading
	regions     []Region
	inner       [][]Heading // per-region inner headings, same index as regions
	tool        int         // index of the open tool region, -1 when none
	fence       byte        // 0 when not inside a fenced block
	fenceN      int
	inComment   bool
	commentTool bool // the open comment is a multi-line tool header
}

// Parse scans text and returns its structure. Headings/Regions are always
// non-nil so the result is stable for JSON consumers.
func Parse(text string) *Document {
	lines := strings.Split(text, "\n")
	s := &scan{headings: []Heading{}, regions: []Region{}, tool: -1}
	frontmatter := frontmatterEnd(lines)
	for i, line := range lines {
		s.step(i+1, line)
	}
	s.view()
	return &Document{
		Lines:       lines,
		Headings:    s.headings,
		Regions:     s.regions,
		Frontmatter: frontmatter,
	}
}

func (s *scan) step(n int, line string) {
	switch {
	case s.fence != 0:
		c, r, tail, ok := render.FenceLine(line)
		if ok && c == s.fence && r >= s.fenceN && strings.TrimSpace(tail) == "" {
			s.fence = 0
		}
	case s.inComment:
		s.stepComment(n, line)
	case s.tool >= 0:
		s.stepTool(n, line)
	default:
		if c, r, _, ok := render.FenceLine(line); ok {
			s.fence = c
			s.fenceN = r
		} else if role, ok := render.RoleHeading(line); ok {
			s.headings = append(s.headings, Heading{role, n})
		} else if strings.HasPrefix(line, "<!-- yap:tool") {
			s.openTool(n, line)
		} else if commentOpenRe.MatchString(line) && !strings.Contains(line, "-->") {
			s.regions = append(s.regions, Region{Kind: markerKind(line), Start: n})
			s.inner = append(s.inner, nil)
			s.inComment = true
			s.commentTool = false
		} else if strings.HasPrefix(line, "<!-- /yap:tool") {
			s.endTool(n) // orphan closer: no-op when no tool is open
		}
	}
}

// stepComment is the `elseif ctx.comment` branch: a multi-line HTML comment
// (thinking/error marker, or a multi-line tool header) until its bare `-->`,
// bounded at the next `# @role` heading when it never closes.
func (s *scan) stepComment(n int, line string) {
	if closeCommentRe.MatchString(line) {
		if s.commentTool {
			s.regions[s.tool].HeaderFinish = n
		} else {
			s.regions[len(s.regions)-1].Finish = n
		}
		s.inComment = false
		s.commentTool = false
		return
	}
	if role, ok := render.RoleHeading(line); ok {
		if s.commentTool {
			s.endTool(n - 1)
		} else {
			s.regions[len(s.regions)-1].Finish = n - 1
		}
		s.inComment = false
		s.commentTool = false
		s.headings = append(s.headings, Heading{role, n})
	}
}

// stepTool is the `elseif ctx.tool` branch: inside an open tool region.
func (s *scan) stepTool(n int, line string) {
	r := &s.regions[s.tool]
	switch {
	case strings.HasPrefix(line, "<!-- /yap:tool"):
		s.endTool(n)
	case strings.HasPrefix(line, "<!-- yap:tool"):
		// A second opener while a region is open means the first was never
		// closed (the backend never nests them): bound it at its first inner
		// heading — or here — so one broken region cannot swallow the ones
		// after it, promote those inner headings, and restart at this line.
		bound := n - 1
		if len(s.inner[s.tool]) > 0 {
			bound = s.inner[s.tool][0].Line - 1
		}
		if bound < r.Start {
			bound = r.Start
		}
		r.Finish = bound
		s.headings = append(s.headings, s.inner[s.tool]...)
		s.inner[s.tool] = nil
		s.openTool(n, line)
	case strings.HasPrefix(line, "<!-- /yap:ui"):
		r.UIFinish = n
	case uiOpenRe.MatchString(line):
		if r.UIStart == 0 {
			r.UIStart = n
		}
	default:
		if role, ok := render.RoleHeading(line); ok {
			s.inner[s.tool] = append(s.inner[s.tool], Heading{role, n})
		}
	}
}

func (s *scan) openTool(n int, line string) {
	s.regions = append(s.regions, Region{Kind: "tool", Start: n})
	s.inner = append(s.inner, nil)
	s.tool = len(s.regions) - 1
	if strings.Contains(line, "-->") {
		s.regions[s.tool].HeaderFinish = n
	} else {
		s.inComment = true
		s.commentTool = true
	}
}

// endTool closes the open tool region at finish (a no-op when none is open),
// mirroring structure.lua's end_tool.
func (s *scan) endTool(finish int) {
	if s.tool >= 0 && s.regions[s.tool].Finish == 0 {
		s.regions[s.tool].Finish = finish
	}
	s.tool = -1
}

// view mirrors structure.lua's view(): an unclosed tool region is malformed,
// so it is bounded at its first inner heading and those headings are restored
// as real message boundaries. A closed region keeps its inner headings as
// content.
func (s *scan) view() {
	open := -1
	for i := len(s.regions) - 1; i >= 0; i-- {
		if s.regions[i].Kind == "tool" && s.regions[i].Finish == 0 {
			open = i
			break
		}
	}
	if open < 0 || len(s.inner[open]) == 0 {
		return
	}
	r := &s.regions[open]
	cut := s.inner[open][0].Line
	r.Finish = cut - 1
	if r.Finish < r.Start {
		r.Finish = r.Start
	}
	r.Unclosed = true
	s.headings = append(s.headings, s.inner[open]...)
	sort.Slice(s.headings, func(a, b int) bool { return s.headings[a].Line < s.headings[b].Line })
	s.inner[open] = nil
}

// frontmatterEnd returns the 1-based line of the closing `---` of a leading
// YAML frontmatter, or 0 when there is none (or it is unterminated).
func frontmatterEnd(lines []string) int {
	if len(lines) == 0 || !dashLineRe.MatchString(lines[0]) {
		return 0
	}
	for i := 1; i < len(lines); i++ {
		if dashLineRe.MatchString(lines[i]) {
			return i + 1
		}
	}
	return 0
}

func markerKind(line string) string {
	if m := markerKindRe.FindStringSubmatch(line); m != nil {
		return m[1]
	}
	return "comment"
}
