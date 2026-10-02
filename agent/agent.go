package main

// The agent loop: one generation step per iteration; tool calls are
// executed (compiled-in tools from the tools package) and re-sent until
// the final answer or the iteration bound. The whole turn is one process.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"boers.email/yap/agent/pricing"
	"boers.email/yap/agent/providers"
	"boers.email/yap/agent/providers/goai"
	"boers.email/yap/agent/tools"
	"boers.email/yap/agent/utils"
)

// ─── Wire types (stdin) ────────────────────────────────────────────────────

type Message struct {
	Role       string          `json:"role"`
	Content    string          `json:"content"`
	ToolCalls  json.RawMessage `json:"tool_calls,omitempty"`
	ToolCallID string          `json:"tool_call_id,omitempty"`
}

type Request struct {
	Messages []Message `json:"messages"`
}

// providerToolDefs converts compiled-in tools to adapter Tool definitions.
func providerToolDefs() []providers.Tool {
	all := tools.All()
	if len(all) == 0 {
		return nil
	}
	defs := make([]providers.Tool, 0, len(all))
	for _, t := range all {
		defs = append(defs, providers.Tool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: json.RawMessage(t.Schema),
		})
	}
	return defs
}

// ─── Agent loop ──────────────────────────────────────────────────────────────

type turn struct {
	text               string
	calls              []providers.ToolCall
	finishReason       string
	prompt, completion int
	// Buffer-write state at return, for block spacing in the agent loop.
	outWrote bool // anything was written (false: cursor still on the empty line)
	outTrail int  // trailing newlines of everything written
	// The exact assistant message(s) GoAI produced for this step (ordered
	// parts + provider metadata); appended verbatim to history.
	responseMessages []providers.Message
}

// lineEscaper buffers streamed text to line granularity so dangerous
// sequences can be neutralized before they reach the buffer. Used for
// thinking text: ANY `-->` closes the HTML comment for renderers, even
// inline — so every one is neutralized. Chunks split mid-line, so
// per-chunk replacement doesn't work.
type lineEscaper struct {
	w      *bufio.Writer
	buf    []byte
	esc    func(string) string
	lastNL bool // last byte written to w was '\n'
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
		l.lastNL = true
		l.w.Flush()
	}
}

func (l *lineEscaper) Flush() {
	if len(l.buf) > 0 {
		l.w.WriteString(l.esc(string(l.buf)))
		l.buf = nil
		l.lastNL = false
	}
	l.w.Flush()
}

// streamStep runs one generation step via the adapter. Writes thinking
// markers and streams assistant prose live; defers prose for tool-bearing
// rounds to the caller (which re-writes it after the tool regions — the
// harness relocates the live-streamed copy).
func streamStep(ctx context.Context, model providers.LanguageModel, messages []providers.Message, out *bufio.Writer, wrote bool) (*turn, error) {
	stream, err := model.DoStream(ctx, providers.Params{Messages: messages, Tools: providerToolDefs()})
	if err != nil {
		return nil, err
	}

	t := &turn{}
	inThinking := false
	sawThinking := false
	esc := newCommentEscaper(out)
	firstWrite := func() {
		if !wrote {
			out.WriteString("\n")
			wrote = true
		}
	}
	// closeThinking ends the open thinking comment with `-->` on its own
	// line. The escaper flushes streamed text without a trailing newline,
	// so the closer must add one — unless the final reasoning chunk already
	// ended with one, in which case an extra blank line would leak into the
	// comment.
	closeThinking := func() {
		esc.Flush()
		if !esc.lastNL {
			out.WriteString("\n")
		}
		out.WriteString("-->\n\n")
		inThinking = false
	}

	for ev := range stream.Events {
		switch ev.Type {
		case providers.EventReasoning:
			if !inThinking {
				firstWrite()
				out.WriteString("<!-- yap:thinking\n")
				inThinking = true
				sawThinking = true
			}
			esc.WriteString(ev.Text)
		case providers.EventText:
			if inThinking {
				closeThinking()
			}
			firstWrite()
			out.WriteString(ev.Text)
			out.Flush()
			t.text += ev.Text
			t.outWrote = true
		}
	}

	if inThinking {
		closeThinking()
		// Thinking-only round still wrote a block that self-terminates
		// with a blank line; report spacing to the caller.
		t.outWrote = true
		t.outTrail = 2
	} else if sawThinking && t.text == "" {
		// We opened and closed thinking earlier (before any assistant text),
		// ensure spacing is reported.
		t.outWrote = true
		t.outTrail = 2
	}

	res := stream.Result()
	if res.Err != nil {
		return nil, res.Err
	}

	if len(res.ToolCalls) > 0 && len(res.ResponseMessages) == 0 {
		return nil, errors.New("provider returned tool calls without a replayable assistant message")
	}
	t.finishReason = res.FinishReason
	t.calls = res.ToolCalls
	t.prompt = res.Usage.PromptTokens
	t.completion = res.Usage.CompletionTokens
	t.responseMessages = res.ResponseMessages

	if t.text != "" {
		t.outTrail = trailingNL(t.text)
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
//   - lines starting with a yap marker opener — they would end the
//     tool region early during parsing;
//   - `<style`/`<script` open tags — in an extracted-Markdown result
//     (fetch converts pages to Markdown, which may embed raw HTML)
//     treesitter's combined HTML injection hands their
//     content to the css/javascript parsers, whose raw-text injection
//     ranges then bleed to the end of the buffer.
var rawTextTagRe = regexp.MustCompile(`(?i)<(style|script)([\s>/])`)

func escapeMarkerPrefixes(s string) string {
	s = rawTextTagRe.ReplaceAllString(s, "\\<$1$2")
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "<!-- yap:") || strings.HasPrefix(l, "<!-- /yap:") {
			lines[i] = "\\" + l
		}
	}
	return strings.Join(lines, "\n")
}

// emitToolHeader writes the yap:tool opener (full call as JSON)
// immediately when the model commits to the call — the arguments are
// visible in the buffer while the tool runs, and the gap to the result
// honestly represents execution time. Flushed so the header lands
// before a long-running tool's result. Blocks carry no leading
// newlines; the caller pads (one blank line between blocks, R7).
func emitToolHeader(out *bufio.Writer, call providers.ToolCall) {
	// write/edit carry their full content in the arguments; the header
	// keeps only the shape — the yap:ui diff shows the change and the
	// audit log has the full arguments (R12).
	argsJSON := string(call.Input)
	args, ok := utils.SlimArgs(call.Name, argsJSON)
	if !ok {
		if err := json.Unmarshal(call.Input, &args); err != nil {
			args = argsJSON // malformed/truncated JSON: keep raw
		}
	}
	// Struct, not map: stable key order (id, name, arguments).
	header, _ := json.Marshal(struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Arguments any    `json:"arguments"`
	}{call.ID, call.Name, args})
	if len(header) <= toolHeaderMaxSingle {
		fmt.Fprintf(out, "<!-- yap:tool %s -->\n", header)
	} else {
		pretty, _ := json.MarshalIndent(json.RawMessage(header), "", "  ")
		fmt.Fprintf(out, "<!-- yap:tool\n%s\n-->\n", pretty)
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

// emitToolResult finishes an open yap:tool region: the result text
// (what the model received), an optional display-only ui section, and
// the region closer.
func emitToolResult(out *bufio.Writer, result, ui string) {
	result = escapeMarkerPrefixes(result)
	out.WriteString(result + "\n")
	// Results are raw markdown in the buffer. A fence left open (truncated
	// read/bash output, or a file that genuinely contains a lone ``` line)
	// would swallow the rest of the buffer as a code block in every
	// CommonMark renderer, treesitter included. Close it before the ui
	// block so that still parses.
	if fence := unclosedFence(strings.Split(result, "\n")); fence != "" {
		out.WriteString(fence + "\n")
	}
	if ui != "" {
		// The ui diff used to live INSIDE a `<!-- yap:ui … -->` comment,
		// where treesitter never parses a fence — a comment is one leaf
		// html_block node, so a ```diff inside it got no highlighting.
		// Paired one-line markers leave the fence at block level, so the
		// markdown grammar parses it and injects the diff parser.
		fence := backtickFence(ui)
		fmt.Fprintf(out, "<!-- yap:ui -->\n%sdiff\n%s\n%s\n<!-- /yap:ui -->\n", fence, ui, fence)
	}
	// Regions self-terminate with exactly one blank line (R7).
	out.WriteString("<!-- /yap:tool -->\n\n")
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

// backtickFence returns a run of backticks one longer than any run in s
// (min 3), so s can be embedded in a fenced block it cannot close early.
func backtickFence(s string) string {
	max := 0
	for _, l := range strings.Split(s, "\n") {
		if c, k := fenceRun(strings.TrimLeft(l, " ")); c == '`' && k > max {
			max = k
		}
	}
	n := max + 1
	if n < 3 {
		n = 3
	}
	return strings.Repeat("`", n)
}

// fenceResult wraps a content-bearing tool result in a fenced code
// block (with a language info string when detectable) so the chat
// buffer's markdown parser renders it as code, not prose — raw file
// content and command output otherwise get markdown_inline styling
// (links, emphasis, headings, <hr>). The fence is one backtick longer
// than any run inside, so content fences can't close it early. Applied
// to the SAME string that goes to the model, so the buffer and the
// replayed history stay identical across turns.
func fenceResult(name, argsJSON, result string) string {
	lang, ok := utils.ResultFence(name, argsJSON)
	if !ok {
		return result
	}
	fence := backtickFence(result)
	return fence + lang + "\n" + strings.TrimRight(result, "\n") + "\n" + fence
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

// providerFactory builds a Yap provider for the given configured provider.
var providerFactory = func(name string, prov Provider) (providers.Provider, error) {
	return goai.NewProvider(providers.ProviderConfig{
		Name:    name,
		BaseURL: prov.BaseURL,
		APIKey:  os.Getenv(prov.APIKeyEnv),
	})
}

func send(providerName, model string, in io.Reader, outw io.Writer) error {
	start := time.Now()
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	tools.SetWebsearchAPIKeyEnv(cfg.Websearch.APIKeyEnv)
	prov, ok := cfg.Providers[providerName]
	if !ok {
		names := make([]string, 0, len(cfg.Providers))
		for n := range cfg.Providers {
			names = append(names, n)
		}
		return fmt.Errorf("unknown provider %q (configured: %s)", providerName, strings.Join(names, ", "))
	}
	if os.Getenv(prov.APIKeyEnv) == "" {
		return fmt.Errorf("provider %q: env var %s is not set", providerName, prov.APIKeyEnv)
	}

	p, err := providerFactory(providerName, prov)
	if err != nil {
		return err
	}

	var req Request
	if err := json.NewDecoder(in).Decode(&req); err != nil {
		return fmt.Errorf("read request from stdin: %w", err)
	}
	if len(req.Messages) == 0 {
		return errors.New("request contains no messages")
	}

	out := bufio.NewWriter(outw)
	messages := make([]providers.Message, 0, len(req.Messages))
	for _, m := range req.Messages {
		if len(m.ToolCalls) > 0 || m.ToolCallID != "" || m.Role == "tool" {
			return errors.New("persisted native tool messages are unsupported; flatten tool history into transcript text")
		}
		var role providers.Role
		switch m.Role {
		case "system":
			role = providers.RoleSystem
		case "user":
			role = providers.RoleUser
		case "assistant":
			role = providers.RoleAssistant
		default:
			return fmt.Errorf("unsupported message role %q", m.Role)
		}
		var content []providers.Part
		if m.Content != "" {
			content = append(content, providers.Part{Type: providers.PartText, Text: m.Content})
		}
		messages = append(messages, providers.Message{Role: role, Content: content})
	}
	modelImpl := p.Model(model)
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

	// :YapStop kills this process; take in-flight tool commands (own
	// process groups) down with it instead of orphaning them.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sig)
	go func() {
		<-sig
		utils.KillAll()
		fmt.Fprintln(os.Stderr, "interrupted")
		os.Exit(1)
	}()

	ctx := context.Background()
	for iter := 0; ; iter++ {
		t, err := streamStep(ctx, modelImpl, messages, out, wrote)
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
				fmt.Fprintf(out, "<!-- yap:error\nmodel returned an empty completion (finish_reason: %s)\n-->\n\n", reason)
			}
			break // final answer streamed; turn complete
		}

		// Append the exact assistant message(s) GoAI produced — ordered
		// parts and provider metadata (reasoning items/encrypted content,
		// signatures, thought signatures, reasoning_content) intact — then
		// execute each call and append native tool-result messages.
		messages = append(messages, t.responseMessages...)
		for _, call := range t.calls {
			// Flush the session-visible call before publishing its audit event.
			// stdout/stderr are separate pipes, so this is the only causal
			// boundary Yap can establish before the tool starts.
			pad()
			emitToolHeader(out, call)
			// Audit trail (yap:event on stderr): the full call before
			// it runs, the full result after. The Lua side appends these
			// to the session's audit log, which is what makes slimmed
			// headers and :YapClear lossless.
			utils.EmitEvent(map[string]any{"type": "tool_call", "id": call.ID, "name": call.Name, "args": string(call.Input)})
			tool, ok := tools.Get(call.Name)
			var result, ui string
			if !ok {
				result = "error: unknown tool " + call.Name
				emitToolResult(out, result, "")
			} else {
				var err error
				result, ui, err = tool.Run(call.Input)
				if err != nil {
					result = "error: " + err.Error()
					ui = ""
				} else {
					result = fenceResult(call.Name, string(call.Input), result)
				}
				emitToolResult(out, result, ui)
			}
			utils.EmitEvent(map[string]any{"type": "tool_result", "id": call.ID, "name": call.Name, "bytes": len(result), "result": result})
			wrote, trail = true, 2 // regions self-terminate with a blank line
			messages = append(messages, providers.Message{
				Role: providers.RoleTool,
				Content: []providers.Part{{
					Type:       providers.PartToolResult,
					ToolCallID: call.ID,
					ToolName:   call.Name,
					ToolOutput: result,
				}},
			})
		}
		// Prose from a tool-bearing provider round is display-only here: it
		// is already in the assistant history above, but showing it after the
		// completed calls keeps calls visible before execution and before any
		// text that refers to their results.
		if t.text != "" {
			out.WriteString(t.text)
			trail = trailingNL(t.text)
			if trail == 0 {
				out.WriteString("\n\n")
				trail = 2
			} else if trail == 1 {
				out.WriteString("\n")
				trail = 2
			}
			wrote = true
		}
		out.Flush()
	}

	if totPrompt+totCompletion > 0 {
		// Reported as a parse-excluded marker; the Lua side folds it into
		// the session totals and removes the line.
		m := map[string]any{"prompt": totPrompt, "completion": totCompletion}
		// Cost: explicit config pricing wins; the committed catalog
		// (agent/pricing) is the fallback. A miss on both tracks tokens
		// only. The catalog also supplies the context window for the
		// toolbar's context-fill display.
		input, output := 0.0, 0.0
		havePricing := false
		if p, ok := cfg.Pricing[model]; ok {
			input, output = p.Input, p.Output
			havePricing = true
		}
		if info, ok := pricing.Lookup(providerName, model); ok {
			if !havePricing {
				input, output = info.Input, info.Output
			}
			if info.ContextWindow > 0 {
				m["context_window"] = info.ContextWindow
			}
		}
		if havePricing || input > 0 || output > 0 {
			m["cost"] = float64(totPrompt)/1e6*input + float64(totCompletion)/1e6*output
		}
		b, _ := json.Marshal(m)
		pad()
		fmt.Fprintf(out, "<!-- yap:usage %s -->\n", b)
		out.Flush() // session state must precede the corresponding audit event
		// Audit: one turn journal line (tail buffer + audit log).
		m["type"] = "turn_end"
		m["model"] = model
		m["ms"] = time.Since(start).Milliseconds()
		utils.EmitEvent(m)
	}
	out.Flush()
	return nil
}
