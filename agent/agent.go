package main

// The agent loop: one generation step per iteration; tool calls are
// executed (compiled-in tools from the tools package) and re-sent until
// the final answer or the iteration bound. Turns may share a long-lived process.

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"boers.email/yap/agent/decision"
	"boers.email/yap/agent/decision/jev"
	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/llm/goai"
	"boers.email/yap/agent/pricing"
	"boers.email/yap/agent/render"
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
	Tools    *[]string `json:"tools,omitempty"` // nil: all tools; child role: allowlist
}

// providerToolDefs converts compiled-in tools to adapter Tool definitions.
func providerToolDefs(allowed *[]string) []llm.Tool {
	permitted := map[string]bool{}
	if allowed != nil {
		for _, name := range *allowed {
			permitted[name] = true
		}
	}
	all := tools.All()
	if len(all) == 0 {
		return nil
	}
	defs := make([]llm.Tool, 0, len(all))
	for _, t := range all {
		if allowed != nil && !permitted[t.Name] {
			continue
		}
		defs = append(defs, llm.Tool{
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
	calls              []llm.ToolCall
	finishReason       string
	prompt, completion int
	// Buffer-write state at return, for block spacing in the agent loop.
	outWrote bool // anything was written (false: cursor still on the empty line)
	outTrail int  // trailing newlines of everything written
	// The exact assistant message(s) GoAI produced for this step (ordered
	// parts + provider metadata); appended verbatim to history.
	responseMessages []llm.Message
}

// streamStep runs one generation step via the adapter. It writes thinking
// markers and streams assistant prose live. Prose from a tool-bearing round
// stays where it streamed (before the tool blocks), matching the model's
// part order: preamble text precedes the calls it introduces.
func streamStep(ctx context.Context, model llm.LanguageModel, messages []llm.Message, out *bufio.Writer, wrote bool, allowed *[]string) (*turn, error) {
	stream, err := model.DoStream(ctx, llm.Params{Messages: messages, Tools: providerToolDefs(allowed)})
	if err != nil {
		return nil, err
	}

	t := &turn{}
	inThinking := false
	sawThinking := false
	esc := render.NewCommentEscaper(out)
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
		if !esc.LastNL() {
			out.WriteString("\n")
		}
		out.WriteString("-->\n\n")
		inThinking = false
	}

	for ev := range stream.Events {
		switch ev.Type {
		case llm.EventReasoning:
			if !inThinking {
				firstWrite()
				out.WriteString("<!-- yap:thinking\n")
				inThinking = true
				sawThinking = true
				t.outWrote = true
			}
			esc.WriteString(ev.Text)
		case llm.EventText:
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
		// Report what was already emitted (if anything) so the caller can
		// decide whether a retry is safe: a mid-stream error after text has
		// streamed cannot be retried without corrupting the document.
		return t, res.Err
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

// maxToolIterations bounds the agent loop: one generation step per
// iteration, capped so a model stuck emitting tool calls cannot loop
// forever.
const maxToolIterations = 300

// retryMaxAttempts bounds how many times a transient generation error is
// retried (on top of the initial call) when the failed step emitted nothing.
const retryMaxAttempts = 3

// retryBaseDelay is the backoff before the first retry; each attempt doubles
// it. A var so tests can shorten it.
var retryBaseDelay = 2 * time.Second

// retryDelay returns the sleep before retry attempt n (0-indexed): 2s, 4s,
// 8s, capped at 30s.
func retryDelay(attempt int) time.Duration {
	d := retryBaseDelay << attempt
	if d > 30*time.Second {
		d = 30 * time.Second
	}
	return d
}

// trailingNL counts the newline characters at the end of s.
func trailingNL(s string) int {
	n := 0
	for n < len(s) && s[len(s)-1-n] == '\n' {
		n++
	}
	return n
}

// providerFactory builds a Yap provider for the given configured provider.
var providerFactory = func(name string, prov Provider) (llm.Provider, error) {
	return goai.NewProvider(llm.ProviderConfig{
		Name:    name,
		BaseURL: prov.BaseURL,
		APIKey:  os.Getenv(prov.APIKeyEnv),
	})
}

// decisionModel builds the backend for the jev tool from config, defaulting
// to Jev via OpenRouter's Decisions API. OPENROUTER_API_KEY authenticates
// both the chat and decisions surfaces.
func decisionModel(cfg *Config) decision.Model {
	env := cfg.Decision.APIKeyEnv
	if env == "" {
		env = "OPENROUTER_API_KEY"
	}
	return jev.New(jev.Config{
		BaseURL: cfg.Decision.BaseURL,
		APIKey:  os.Getenv(env),
		Model:   cfg.Decision.Model,
	})
}

func send(providerName, model string, in io.Reader, outw io.Writer) error {
	var req Request
	if err := json.NewDecoder(in).Decode(&req); err != nil {
		return fmt.Errorf("read request from stdin: %w", err)
	}
	return runTurn(providerName, model, req, outw)
}

func runTurn(providerName, model string, req Request, outw io.Writer) error {
	start := time.Now()
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	tools.SetWebsearchAPIKeyEnv(cfg.Websearch.APIKeyEnv)
	tools.SetDecisionModel(decisionModel(cfg))
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

	if len(req.Messages) == 0 {
		return errors.New("request contains no messages")
	}

	out := bufio.NewWriter(outw)
	messages := make([]llm.Message, 0, len(req.Messages))
	for _, m := range req.Messages {
		if len(m.ToolCalls) > 0 || m.ToolCallID != "" || m.Role == "tool" {
			return errors.New("persisted native tool messages are unsupported; flatten tool history into transcript text")
		}
		var role llm.Role
		switch m.Role {
		case "system":
			role = llm.RoleSystem
		case "user":
			role = llm.RoleUser
		case "assistant":
			role = llm.RoleAssistant
		default:
			return fmt.Errorf("unsupported message role %q", m.Role)
		}
		var content []llm.Part
		if m.Content != "" {
			content = append(content, llm.Part{Type: llm.PartText, Text: m.Content})
		}
		messages = append(messages, llm.Message{Role: role, Content: content})
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

	ctx := context.Background()
	for iter := 0; ; iter++ {
		t, err := streamStep(ctx, modelImpl, messages, out, wrote, req.Tools)
		if err != nil {
			// Retry transient errors (429/5xx, network) only while the failed
			// step emitted nothing to the buffer: a mid-stream failure after
			// text has already streamed cannot be retried without corrupting
			// the document. Pre-stream failures are already retried by the
			// SDK, so this is a safety net for the remainder.
			for attempt := 0; err != nil && goai.IsRetryable(err) && (t == nil || !t.outWrote) && attempt < retryMaxAttempts; attempt++ {
				delay := retryDelay(attempt)
				utils.EmitEvent(map[string]any{
					"type":     "retry",
					"attempt":  attempt + 1,
					"delay_ms": delay.Milliseconds(),
					"error":    err.Error(),
				})
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(delay):
				}
				t, err = streamStep(ctx, modelImpl, messages, out, wrote, req.Tools)
			}
			if err != nil {
				return err
			}
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

		if iter >= maxToolIterations {
			pad()
			fmt.Fprintf(out, "<!-- yap:error\nreached %d tool iterations without a final answer\n-->\n\n", maxToolIterations)
			break
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
			render.EmitToolHeader(out, call)
			// Audit trail (yap:event on stderr): the full call before
			// it runs, the full result after. The Lua side appends these
			// to the session's audit log, which is what makes slimmed
			// headers and :YapClear lossless.
			utils.EmitEvent(map[string]any{"type": "tool_call", "id": call.ID, "name": call.Name, "args": tools.Scrub(string(call.Input))})
			tool, ok := tools.Get(call.Name)
			if req.Tools != nil {
				permitted := false
				for _, name := range *req.Tools {
					if name == call.Name {
						permitted = true
						break
					}
				}
				if !permitted {
					ok = false
				}
			}
			var result, ui string
			if !ok {
				result = "error: unknown tool " + call.Name
				render.EmitToolResult(out, result, "")
			} else {
				var err error
				result, ui, err = tool.Run(call.Input)
				if err != nil {
					result = "error: " + err.Error()
					ui = ""
				} else {
					result = render.FenceResult(call.Name, string(call.Input), result)
				}
				result = tools.Scrub(result)
				render.EmitToolResult(out, result, ui)
			}
			utils.EmitEvent(map[string]any{"type": "tool_result", "id": call.ID, "name": call.Name, "bytes": len(result), "result": result})
			wrote, trail = true, 2 // regions self-terminate with a blank line
			messages = append(messages, llm.Message{
				Role: llm.RoleTool,
				Content: []llm.Part{{
					Type:       llm.PartToolResult,
					ToolCallID: call.ID,
					ToolName:   call.Name,
					ToolOutput: result,
				}},
			})
		}
		// Prose for this round already streamed live before the tool blocks;
		// the tool regions self-terminate with a blank line (R7), so nothing
		// more to emit here.
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
		b := render.MarshalCommentJSON(m, "")
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
