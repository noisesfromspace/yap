package main

// The agent loop: one chat completion per iteration; tool calls are
// executed (compiled-in tools from the tools package) and re-sent until
// the final answer or the iteration bound. The whole turn is one process.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strings"
	"syscall"

	"boers.email/pitel/agent/tools"
)

// Bound on tool-call iterations per send (gptel has none; runaway loops
// burn tokens silently).
const maxToolIterations = 25

// ─── Wire types (OpenAI-compatible) ──────────────────────────────────────────

type ToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"` // JSON-encoded string per spec
	} `json:"function"`
}

type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
}

type Request struct {
	Messages []Message `json:"messages"`
}

type chatRequest struct {
	Model    string     `json:"model"`
	Messages []Message  `json:"messages"`
	Stream   bool       `json:"stream"`
	Tools    []toolDef  `json:"tools,omitempty"`
	// Ask the provider to end the stream with a token-usage chunk.
	StreamOptions *struct {
		IncludeUsage bool `json:"include_usage"`
	} `json:"stream_options,omitempty"`
}

type toolDef struct {
	Type     string `json:"type"`
	Function struct {
		Name        string          `json:"name"`
		Description string          `json:"description"`
		Parameters  json.RawMessage `json:"parameters"`
	} `json:"function"`
}

// Delta tool_calls arrive index-keyed: first chunk has id/type/name,
// subsequent chunks stream function.arguments fragments.
type deltaToolCall struct {
	Index    int    `json:"index"`
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

type streamChunk struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
			// ReasoningContent is the OpenAI-compatible thinking field
			// (DeepSeek, Moonshot/Kimi). Streamed wrapped in a
			// <!-- pitel:thinking --> marker, which parse_buffer excludes
			// from the message array on the next send.
			ReasoningContent string          `json:"reasoning_content"`
			ToolCalls        []deltaToolCall `json:"tool_calls"`
		} `json:"delta"`
		FinishReason *string `json:"finish_reason"`
	} `json:"choices"`
	// Final chunk when stream_options.include_usage is set (choices empty).
	Usage *struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

type apiError struct {
	Error struct {
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error"`
}

func toolDefs() []toolDef {
	all := tools.All()
	if len(all) == 0 {
		return nil
	}
	defs := make([]toolDef, 0, len(all))
	for _, t := range all {
		var d toolDef
		d.Type = "function"
		d.Function.Name = t.Name
		d.Function.Description = t.Description
		d.Function.Parameters = json.RawMessage(t.Schema)
		defs = append(defs, d)
	}
	return defs
}

// ─── Agent loop ──────────────────────────────────────────────────────────────

type turn struct {
	text               string
	calls              []ToolCall
	finishReason       string
	prompt, completion int
	// Buffer-write state at return, for block spacing in the agent loop.
	outWrote bool // anything was written (false: cursor still on the empty line)
	outTrail int  // trailing newlines of everything written
}

// lineEscaper buffers streamed text to line granularity so dangerous
// sequences can be neutralized before they reach the buffer. Used for
// thinking text: ANY `-->` closes the HTML comment for renderers, even
// inline — so every one is neutralized. Chunks split mid-line, so
// per-chunk replacement doesn't work.
type lineEscaper struct {
	w   *bufio.Writer
	buf []byte
	esc func(string) string
}

func newCommentEscaper(w *bufio.Writer) *lineEscaper {
	return &lineEscaper{w: w, esc: escapeComment}
}

func (l *lineEscaper) WriteString(s string) {
	l.buf = append(l.buf, s...)
	flushed := false
	for {
		i := bytes.IndexByte(l.buf, '\n')
		if i < 0 {
			break
		}
		l.w.WriteString(l.esc(string(l.buf[:i])) + "\n")
		l.buf = l.buf[i+1:]
		flushed = true
	}
	if flushed {
		l.w.Flush()
	}
}

func (l *lineEscaper) Flush() {
	if len(l.buf) > 0 {
		l.w.WriteString(l.esc(string(l.buf)))
		l.buf = nil
	}
	l.w.Flush()
}

// streamCompletion performs one streaming chat completion, writing text and
// thinking markers to out as they arrive, and returns what the model said.
// wrote reports whether earlier output already sits in the buffer (tool
// regions of previous iterations): the first write of a turn gets one
// leading blank only when nothing has been written yet.
func streamCompletion(req chatRequest, url, apiKey string, out *bufio.Writer, wrote bool) (*turn, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	httpReq, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+apiKey)
	httpReq.Header.Set("Accept", "text/event-stream")

	client := &http.Client{Timeout: 0} // no total timeout; streams can be long
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("POST %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		var ae apiError
		if json.Unmarshal(errBody, &ae) == nil && ae.Error.Message != "" {
			return nil, fmt.Errorf("%s: %s", resp.Status, ae.Error.Message)
		}
		return nil, fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(errBody)))
	}

	// SSE stream: lines of "data: {json}", terminated by "data: [DONE]".
	t := &turn{}
	callArgs := map[int]*ToolCall{} // by delta index
	inThinking := false
	esc := newCommentEscaper(out) // for thinking text
	// The first block of the whole turn gets one leading blank (the
	// cursor sits on the empty line after the # @assistant heading);
	// everything after that self-terminates with a blank line.
	firstWrite := func() {
		if !wrote {
			out.WriteString("\n")
			wrote = true
		}
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			break
		}
		var chunk streamChunk
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue // keep-alive pings and other non-chunk events
		}
		if chunk.Usage != nil {
			t.prompt += chunk.Usage.PromptTokens
			t.completion += chunk.Usage.CompletionTokens
		}
		for _, c := range chunk.Choices {
			if c.FinishReason != nil {
				t.finishReason = *c.FinishReason
			}
			if c.Delta.ReasoningContent != "" {
				if !inThinking {
					firstWrite()
					out.WriteString("<!-- pitel:thinking\n")
					inThinking = true
				}
				esc.WriteString(c.Delta.ReasoningContent)
			}
			if c.Delta.Content != "" {
				if inThinking {
					esc.Flush()
					out.WriteString("\n-->\n\n")
					inThinking = false
				}
				firstWrite()
				out.WriteString(c.Delta.Content)
				t.text += c.Delta.Content
				out.Flush()
			}
			for _, dc := range c.Delta.ToolCalls {
				tc, ok := callArgs[dc.Index]
				if !ok {
					tc = &ToolCall{ID: dc.ID, Type: dc.Type}
					tc.Function.Name = dc.Function.Name
					callArgs[dc.Index] = tc
				}
				if dc.ID != "" {
					tc.ID = dc.ID
				}
				if dc.Function.Name != "" {
					tc.Function.Name = dc.Function.Name
				}
				tc.Function.Arguments += dc.Function.Arguments
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading stream: %w", err)
	}
	if inThinking {
		// Stream ended mid-thinking (or the model emitted nothing else):
		// close the marker so the block stays parseable.
		esc.Flush()
		out.WriteString("\n-->\n\n")
	}
	t.outWrote = wrote
	switch {
	case t.text != "":
		t.outTrail = trailingNL(t.text)
	case wrote:
		t.outTrail = 2 // thinking-only turn: closed with a blank line
	}
	// Providers should use contiguous 0-based indices, but don't assume:
	// collect and sort the keys so sparse indices can't silently drop calls.
	idxs := make([]int, 0, len(callArgs))
	for i := range callArgs {
		idxs = append(idxs, i)
	}
	sort.Ints(idxs)
	for _, i := range idxs {
		tc := callArgs[i]
		tc.Type = "function"
		t.calls = append(t.calls, *tc)
	}
	return t, nil
}

// toolHeaderMaxSingle is the longest header kept on one line; longer
// calls (write/edit content) are emitted as pretty-printed multi-line
// JSON inside the marker, which the Lua side folds closed by default.
const toolHeaderMaxSingle = 120

// escapeComment neutralizes every `-->` in text that lives inside an
// HTML comment region (thinking, ui): HTML comments are not line-based,
// so even an inline `-->` (e.g. in backticked prose) closes the comment
// early for markdown renderers. A space keeps the text readable. (A
// backslash-escape can't work here: `\-->` still CONTAINS the `-->`
// sequence a character-based comment scanner looks for.)
func escapeComment(s string) string {
	return strings.ReplaceAll(s, "-->", "-- >")
}

// escapeMarkerPrefixes neutralizes dangerous constructs in tool results
// (raw markdown in the buffer) with a VISIBLE backslash-escape, valid
// CommonMark for ASCII punctuation: renderers show the literal text,
// treesitter sees an escape instead of a tag, and the line-start-anchored
// Lua parser never matches. No invisible bytes (a ZWSP breaks
// markdown_inline's html_tag grammar and renders as a literal <200b>;
// a soft hyphen hides corruption from the user while still reaching
// registers and the model).
//
// Two cases:
//   - lines starting with a pitel marker opener — they would end the
//     tool region early during parsing;
//   - `<style`/`<script` open tags — in a raw-HTML result (fetch returns
//     pages as-is) treesitter's combined HTML injection hands their
//     content to the css/javascript parsers, whose raw-text injection
//     ranges then bleed to the end of the buffer.
var rawTextTagRe = regexp.MustCompile(`(?i)<(style|script)([\s>/])`)

func escapeMarkerPrefixes(s string) string {
	s = rawTextTagRe.ReplaceAllString(s, "\\<$1$2")
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "<!-- pitel:") || strings.HasPrefix(l, "<!-- /pitel:") {
			lines[i] = "\\" + l
		}
	}
	return strings.Join(lines, "\n")
}

// emitToolHeader writes the pitel:tool opener (full call as JSON)
// immediately when the model commits to the call — the arguments are
// visible in the buffer while the tool runs, and the gap to the result
// honestly represents execution time. Flushed so the header lands
// before a long-running tool's result. Blocks carry no leading
// newlines; the caller pads (one blank line between blocks, R7).
func emitToolHeader(out *bufio.Writer, call ToolCall) {
	var args any
	if err := json.Unmarshal([]byte(call.Function.Arguments), &args); err != nil {
		args = call.Function.Arguments // malformed/truncated JSON: keep raw
	}
	// Struct, not map: stable key order (id, name, arguments).
	header, _ := json.Marshal(struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Arguments any    `json:"arguments"`
	}{call.ID, call.Function.Name, args})
	if len(header) <= toolHeaderMaxSingle {
		fmt.Fprintf(out, "<!-- pitel:tool %s -->\n", header)
	} else {
		pretty, _ := json.MarshalIndent(json.RawMessage(header), "", "  ")
		fmt.Fprintf(out, "<!-- pitel:tool\n%s\n-->\n", pretty)
	}
	out.Flush()
}

// trailingNL counts the newline characters at the end of s.
func trailingNL(s string) int {
	n := 0
	for n < len(s) && s[len(s)-1-n] == '\n' {
		n++
	}
	return n
}

// emitToolResult finishes an open pitel:tool region: the result text
// (what the model received), an optional display-only ui section, and
// the region closer.
func emitToolResult(out *bufio.Writer, result, ui string) {
	result = escapeMarkerPrefixes(result)
	ui = escapeComment(ui)
	out.WriteString(result + "\n")
	// Results are raw markdown in the buffer. A fence left open (truncated
	// read/bash output, or a file that genuinely contains a lone ``` line)
	// would swallow the rest of the buffer as a code block in every
	// CommonMark renderer, treesitter included. Close it before the ui
	// block so that still parses as a comment.
	if fence := unclosedFence(strings.Split(result, "\n")); fence != "" {
		out.WriteString(fence + "\n")
	}
	if ui != "" {
		fmt.Fprintf(out, "<!-- pitel:ui\n%s\n-->\n", ui)
	}
	// Regions self-terminate with exactly one blank line (R7).
	out.WriteString("<!-- /pitel:tool -->\n\n")
	out.Flush()
}

// unclosedFence returns the fence run left open at the end of lines
// (e.g. "```"), or "" when all fences balance. Follows CommonMark: an
// opener is up to 3 spaces + a run of >=3 backticks or tildes; a closer
// is a run of the same char at least as long.
func unclosedFence(lines []string) string {
	var char byte
	var n int
	for _, l := range lines {
		t := strings.TrimLeft(l, " ")
		if len(l)-len(t) > 3 {
			continue
		}
		c, k := fenceRun(t)
		if n == 0 {
			if k >= 3 {
				char, n = c, k
			}
		} else if c == char && k >= n {
			char, n = 0, 0
		}
	}
	if n == 0 {
		return ""
	}
	return strings.Repeat(string(char), n)
}

func fenceRun(s string) (byte, int) {
	if s == "" || (s[0] != '`' && s[0] != '~') {
		return 0, 0
	}
	i := 0
	for i < len(s) && s[i] == s[0] {
		i++
	}
	return s[0], i
}

func send(providerName, model string, in io.Reader, outw io.Writer) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	prov, ok := cfg.Providers[providerName]
	if !ok {
		names := make([]string, 0, len(cfg.Providers))
		for n := range cfg.Providers {
			names = append(names, n)
		}
		return fmt.Errorf("unknown provider %q (configured: %s)", providerName, strings.Join(names, ", "))
	}
	apiKey := os.Getenv(prov.APIKeyEnv)
	if apiKey == "" {
		return fmt.Errorf("provider %q: env var %s is not set", providerName, prov.APIKeyEnv)
	}

	var req Request
	if err := json.NewDecoder(in).Decode(&req); err != nil {
		return fmt.Errorf("read request from stdin: %w", err)
	}
	if len(req.Messages) == 0 {
		return errors.New("request contains no messages")
	}

	url := strings.TrimRight(prov.BaseURL, "/") + "/chat/completions"
	out := bufio.NewWriter(outw)
	messages := req.Messages
	var totPrompt, totCompletion int

	// Block spacing (R7): blocks never start with newlines and
	// self-terminate with exactly one blank line; pad() bridges the
	// transitions (heading → first block, streamed text → tool header).
	wrote, trail := false, 0
	pad := func() {
		if !wrote {
			out.WriteString("\n") // cursor sits on the empty line after the heading
			wrote, trail = true, 1
			return
		}
		for ; trail < 2; trail++ {
			out.WriteString("\n")
		}
	}

	// :PitelStop kills this process; take in-flight tool commands (own
	// process groups) down with it instead of orphaning them.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sig)
	go func() {
		<-sig
		tools.KillAll()
		fmt.Fprintln(os.Stderr, "interrupted")
		os.Exit(1)
	}()

	for iter := 0; ; iter++ {
		t, err := streamCompletion(chatRequest{
			Model:    model,
			Messages: messages,
			Stream:   true,
			Tools:    toolDefs(),
			StreamOptions: &struct {
				IncludeUsage bool `json:"include_usage"`
			}{IncludeUsage: true},
		}, url, apiKey, out, wrote)
		if err != nil {
			return err
		}
		totPrompt += t.prompt
		totCompletion += t.completion
		if t.outWrote {
			wrote, trail = true, t.outTrail
		}

		if len(t.calls) == 0 {
			if strings.TrimSpace(t.text) == "" {
				// An empty completion is always an anomaly (provider hiccup,
				// token budget eaten by reasoning, model expected tools that
				// are not compiled in). Never fail silently.
				reason := t.finishReason
				if reason == "" {
					reason = "unknown"
				}
				pad()
				fmt.Fprintf(out, "<!-- pitel:error\nmodel returned an empty completion (finish_reason: %s)\n-->\n\n", reason)
			}
			break // final answer streamed; turn complete
		}
		if iter+1 >= maxToolIterations {
			pad()
			fmt.Fprintf(out, "<!-- pitel:error\nmax tool iterations (%d) reached\n-->\n\n", maxToolIterations)
			break
		}

		// Append the assistant turn with its calls to the request-local
		// history, execute each call, and emit one pitel:tool region per
		// call+result pair (R12) — both to the buffer and to the history.
		// The header lands BEFORE the tool runs so the call is visible
		// while it executes; live output is followed via the tool's own
		// log file (:PitelLive), never written into this buffer.
		messages = append(messages, Message{Role: "assistant", Content: t.text, ToolCalls: t.calls})
		for _, call := range t.calls {
			tool, ok := tools.Get(call.Function.Name)
			var result, ui string
			if !ok {
				result = "error: unknown tool " + call.Function.Name
				pad()
				emitToolResult(out, result, "")
			} else {
				pad()
				emitToolHeader(out, call)
				var err error
				result, ui, err = tool.Run(json.RawMessage(call.Function.Arguments))
				if err != nil {
					result = "error: " + err.Error()
					ui = ""
				}
				emitToolResult(out, result, ui)
			}
			wrote, trail = true, 2 // regions self-terminate with a blank line
			messages = append(messages, Message{Role: "tool", ToolCallID: call.ID, Content: result})
		}
		out.Flush()
	}

	if totPrompt+totCompletion > 0 {
		// Reported as a parse-excluded marker; the Lua side folds it into
		// the session frontmatter and removes the line.
		m := map[string]any{"prompt": totPrompt, "completion": totCompletion}
		if p, ok := cfg.Pricing[model]; ok {
			m["cost"] = float64(totPrompt)/1e6*p.Input + float64(totCompletion)/1e6*p.Output
		}
		b, _ := json.Marshal(m)
		pad()
		fmt.Fprintf(out, "<!-- pitel:usage %s -->\n", b)
	}
	out.Flush()
	return nil
}
