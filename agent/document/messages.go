package document

import (
	"bytes"
	"encoding/json"
	"strings"

	"boers.email/yap/agent/render"
)

// Message is one flattened transcript message: the request shape a send
// derives from the session markdown (R-markers-not-sent, R-role-alternation).
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ToolHeader is the decoded JSON of a yap:tool region header.
type ToolHeader struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// DecodeToolHeader decodes a tool region's JSON header. It mirrors
// structure.lua's decode_header: the single-line form (`<!-- yap:tool {…} -->`)
// or the multi-line form (the JSON between the opener and its `-->`). Returns
// nil when the region has no closed header or the JSON is not a usable tool
// record (no id and name).
func DecodeToolHeader(lines []string, r Region) *ToolHeader {
	if r.HeaderFinish == 0 || r.Start <= 0 || r.Start > len(lines) {
		return nil
	}
	var raw string
	if r.HeaderFinish == r.Start {
		raw = toolHeaderSingle(lines[r.Start-1])
	} else {
		lo, hi := r.Start, r.HeaderFinish-1
		if lo > hi {
			lo = hi
		}
		if hi > len(lines) {
			hi = len(lines)
		}
		raw = strings.Join(lines[lo:hi], "\n")
	}
	if raw == "" {
		return nil
	}
	var h struct {
		ID        json.RawMessage `json:"id"`
		Name      json.RawMessage `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if json.Unmarshal([]byte(raw), &h) != nil {
		return nil
	}
	// Lua's decode_header requires both id and name to be present (non-nil),
	// so a marker without them is not a usable tool record.
	if h.ID == nil || h.Name == nil {
		return nil
	}
	var id, name string
	_ = json.Unmarshal(h.ID, &id)
	_ = json.Unmarshal(h.Name, &name)
	return &ToolHeader{ID: id, Name: name, Arguments: h.Arguments}
}

// toolHeaderSingle extracts the JSON of a single-line tool header
// (`<!-- yap:tool {…} -->`), matching structure.lua's greedy capture up to the
// final ` -->` before trailing whitespace.
func toolHeaderSingle(line string) string {
	const open = "<!-- yap:tool "
	if !strings.HasPrefix(line, open) {
		return ""
	}
	rest := line[len(open):]
	idx := strings.LastIndex(rest, " -->")
	if idx < 0 || strings.TrimSpace(rest[idx+len(" -->"):]) != "" {
		return ""
	}
	return rest[:idx]
}

// Messages flattens a session transcript into the request messages. It is the
// Go counterpart of structure.lua's messages_from, sharing the same rules:
// marker regions are skipped (or tool regions flattened), adjacent same-role
// messages merge, empty messages drop, and pre-heading text is ignored. The
// two implementations are locked by tests/transcript_messages_cases.json.
func Messages(text string) []Message {
	return messagesFrom(Parse(text))
}

func messagesFrom(doc *Document) []Message {
	lines := doc.Lines
	headingAt := make(map[int]string, len(doc.Headings))
	for _, h := range doc.Headings {
		headingAt[h.Line] = h.Role
	}

	var out = make([]Message, 0)
	var acc []string
	role := ""

	// flush trims and commits the accumulated lines as one message. Empty
	// messages drop; adjacent same-role messages merge (R-role-alternation);
	// text before the first heading is discarded (R-pre-heading-ignored).
	flush := func() {
		if role == "" {
			acc = nil
			return
		}
		text := strings.TrimSpace(strings.Join(acc, "\n"))
		acc = nil
		if text == "" {
			return
		}
		if n := len(out); n > 0 && out[n-1].Role == role {
			out[n-1].Content += "\n\n" + text
		} else {
			out = append(out, Message{Role: role, Content: text})
		}
	}

	ri := 0
	for i := 1; i <= len(lines); {
		if ri < len(doc.Regions) && doc.Regions[ri].Start == i {
			r := doc.Regions[ri]
			ri++
			finish := r.Finish
			if finish == 0 {
				finish = len(lines)
			}
			if finish < r.Start {
				finish = r.Start
			}
			// A tool region flattens only inside an assistant message with a
			// decodable header; anything else (orphan, user-block, malformed)
			// is skipped whole, like messages_from.
			if h := DecodeToolHeader(lines, r); h != nil && role == "assistant" {
				acc = append(acc, "Tool call: "+h.Name)
				acc = append(acc, "Arguments: "+flattenArgs(h.Arguments))
				acc = append(acc, "Tool result:")
				first := r.Start + 1
				if r.HeaderFinish != 0 {
					first = r.HeaderFinish + 1
				}
				last := finish - 1
				if r.UIStart != 0 {
					last = r.UIStart - 1
				}
				for k := first; k <= last && k <= len(lines); k++ {
					acc = append(acc, lines[k-1])
				}
			} else if r.Kind == "error" && role == "assistant" {
				// An error marker poisons the assistant block it follows: the
				// partial before it is a failed attempt, never a real answer,
				// so it is excluded from the request (R-error-surface). The
				// marker itself is already skipped by this region branch.
				acc = nil
			}
			i = finish + 1
			continue
		}
		line := lines[i-1]
		if hr, ok := headingAt[i]; ok {
			flush()
			role = hr
		} else if render.IsMarkerLine(line) {
			// A single-line marker or orphan closer is never message text.
		} else {
			acc = append(acc, line)
		}
		i++
	}
	flush()
	return out
}

// flattenArgs renders a tool call's arguments the way structure.lua does:
// a JSON string is used verbatim; any other value (object, array, scalar,
// null) is re-encoded compactly, with HTML escaping disabled so `&`, `<`, `>`
// stay literal — matching vim.json.encode. Key order of a multi-key object
// may differ from LuaJIT's hash order; the shared fixture avoids relying on it.
func flattenArgs(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return "{}"
	}
	if raw[0] == '"' {
		var s string
		if json.Unmarshal(raw, &s) == nil {
			return s
		}
		return "{}"
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if dec.Decode(&v) != nil {
		return "{}"
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
	return strings.TrimSuffix(buf.String(), "\n")
}
