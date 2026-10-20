package turn

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"boers.email/yap/agent/config"
	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/llm/goai"
	"boers.email/yap/agent/price"
	"boers.email/yap/agent/render"
	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/tools"
	"boers.email/yap/agent/utils"
	"boers.email/yap/agent/websearch/exa"
	"boers.email/yap/agent/wire"
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
	Tools    *[]string `json:"tools,omitempty"` // nil: all tools; child agent: allowlist
	// ReasoningLevel is the cross-provider reasoning-effort knob (low|medium|high).
	ReasoningLevel string `json:"reasoning_level,omitempty"`
	// Cwd is the frontend's working directory at send time. Request-only,
	// like the context tail: the serve process's own cwd is fixed when the
	// buffer spawns it, so without this a `:cd` in Neovim would leave the
	// documented "default: the Neovim cwd" of bash (and the project
	// root in the outside-root write note) pointing at the directory the
	// session was started in. Empty for a one-shot `yap send`.
	Cwd string `json:"cwd,omitempty"`
	// AssetsDir is the per-session folder for transient tool files (live-tail
	// logs, inline scripts, header files, SSH control sockets) and the
	// agent's scratch files. Set by the frontend from the session folder so
	// those files live with the session instead of the system temp dir.
	// Empty for a one-shot `yap send`.
	AssetsDir string `json:"assets_dir,omitempty"`
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

type step struct {
	text               string
	calls              []llm.ToolCall
	finishReason       string
	prompt, completion int
	cacheRead          int
	cacheWrite         int
	// Buffer-write state at return, for block spacing in the agent loop.
	outWrote bool // anything was written (false: cursor still on the empty line)
	outTrail int  // trailing newlines of everything written
	// The exact assistant message(s) GoAI produced for this step (ordered
	// parts + provider metadata); appended verbatim to history.
	responseMessages []llm.Message
}

// boundary is a pending mid-turn injection from the frontend, delivered at
// the next model boundary (before the next generation step). A non-empty
// steer is a user message to inject; provider/model (non-empty together)
// switch the generation model for the remainder of the turn.
type Boundary struct {
	Steer    string
	Provider string
	Model    string
}

// streamStep runs one generation step via the adapter. It writes thinking
// markers and streams assistant prose live. Prose from a tool-bearing round
// stays where it streamed (before the tool regions), matching the model's
// part order: preamble text precedes the calls it introduces.
func streamStep(ctx context.Context, model llm.LanguageModel, messages []llm.Message, out *bufio.Writer, wrote bool, allowed *[]string, reasoningLevel string) (*step, error) {
	stream, err := model.DoStream(ctx, llm.Params{Messages: messages, Tools: providerToolDefs(allowed), ReasoningLevel: reasoningLevel})
	if err != nil {
		return nil, err
	}

	t := &step{}
	inThinking := false
	sawThinking := false
	esc := render.NewCommentEscaper(out)
	prose := render.NewProseEscaper(out)
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
			prose.WriteString(ev.Text)
			t.text += ev.Text
			t.outWrote = true
		}
	}

	prose.Flush()

	if inThinking {
		closeThinking()
		// Thinking-only round still wrote a region that self-terminates
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
	// A user cancel mid-stream may surface as a provider stream error, or —
	// because the SDK closes the response body on cancellation — as a clean
	// EOF with no error at all. Check the turn context first so a cancel
	// always looks like cancellation, never a successful (truncated) answer.
	if ctx.Err() != nil {
		return t, ctx.Err()
	}
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
	t.cacheRead = res.Usage.CacheReadTokens
	t.cacheWrite = res.Usage.CacheWriteTokens
	t.responseMessages = res.ResponseMessages

	if t.text != "" {
		t.outTrail = trailingNL(t.text)
	}
	return t, nil
}

// A model occasionally writes a tool call as ordinary prose instead of a
// native tool call. Two shapes are common: the flattened transcript form
// (`Tool call: <name>` / `Arguments: …`, which document.lua synthesizes for
// history) and the Anthropic-style `<invoke>`/`<parameter>` XML convention.
// Nothing in the harness emits either as live output, so a match means an
// intended call never ran. Detection is advisory: a false positive only
// surfaces a warning — it never blocks or rewrites the answer.
//
// A call that is merely *described* (documentation, examples, code blocks)
// must not match: only text outside fenced code blocks is inspected, and an
// XML match needs structural evidence of a real invocation — a tag carrying
// a tool or parameter name — not a bare mention of `<invoke>`/`<parameter>`.
var (
	flattenedToolCallRe = regexp.MustCompile(`(?m)^Tool call:\s*(\S+)\s*$`)
	xmlToolCallRe       = regexp.MustCompile(`(?i)<\s*(?:antml:)?(?:invoke|parameter)\b[^>]*\bname\s*=`)
)

// stripFences removes fenced code blocks (``` and ~~~) so a quoted example
// of the tool-call syntax is not mistaken for a live call. A model that
// really wants to run a tool emits the XML bare, never fenced.
func stripFences(text string) string {
	var out []byte
	inFence := false
	fence := ""
	for len(text) > 0 {
		i := strings.IndexByte(text, '\n')
		var line, rest string
		if i < 0 {
			line, rest = text, ""
		} else {
			line, rest = text[:i], text[i+1:]
		}
		trimmed := strings.TrimLeft(line, " \t")
		if !inFence {
			if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
				inFence = true
				fence = trimmed[:3]
			} else {
				out = append(out, line...)
				out = append(out, '\n')
			}
		} else if strings.HasPrefix(trimmed, fence) {
			inFence = false
		}
		text = rest
	}
	return string(out)
}

// detectTextToolCall reports whether the assistant text looks like an
// unexecuted tool call and, when it does, a short label for the message.
// The flattened tool name is sanitized so it cannot close the error marker
// comment early.
func detectTextToolCall(text string) (string, bool) {
	body := stripFences(text)
	if m := flattenedToolCallRe.FindStringSubmatch(body); m != nil {
		return "text tool call (" + strings.ReplaceAll(m[1], "-->", "-- >") + ")", true
	}
	if xmlToolCallRe.MatchString(body) {
		return "XML <invoke> tool call", true
	}
	return "", false
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
var providerFactory = func(name string, prov config.Provider) (llm.Provider, error) {
	return goai.NewProvider(llm.ProviderConfig{
		Name:    name,
		BaseURL: prov.BaseURL,
		APIKey:  os.Getenv(prov.APIKeyEnv),
	})
}

// Send runs one turn from a JSON request on in, writing the streamed reply
// to outw. It is the one-shot "yap send" path (no mid-turn steering).
func Send(providerName, model string, in io.Reader, outw io.Writer) error {
	var req Request
	if err := json.NewDecoder(in).Decode(&req); err != nil {
		return fmt.Errorf("read request from stdin: %w", err)
	}
	return Run(context.Background(), providerName, model, req, outw, func() Boundary { return Boundary{} })
}

// Run runs one agent loop. poll is consulted before each generation
// step after the first: it returns a pending steering message and/or a
// provider/model switch (zero values when none). A steer is written into
// the buffer as a `# @user` block and appended to the native message
// history; a model switch rebuilds the provider/model and continues the
// same turn. Both land at the next tool boundary, so native tool results
// stay native — unlike a stop-and-resend, which flattens them to
// transcript text.
func Run(ctx context.Context, providerName, model string, req Request, outw io.Writer, poll func() Boundary) error {
	start := time.Now()
	// Install the turn's context so tools (RunStreamed, fetch, curl, approval,
	// subagent) can abort promptly when the frontend cancels the turn. Cleared
	// after the background task pool has drained (see the defer below).
	wire.SetTurnContext(ctx)
	defer wire.SetTurnContext(context.Background())
	cfg, err := config.LoadConfig()
	if err != nil {
		return err
	}
	utils.SetFrontendCwd(req.Cwd)
	utils.SetAssetsBase(req.AssetsDir)
	tools.SetWebsearchProvider(cfg.Websearch.Provider)
	exa.SetAPIKeyEnv(cfg.Websearch.APIKeyEnv)
	tools.SetGitHubAPIKeyEnv(cfg.GitHub.APIKeyEnv)
	tools.SetSSHKnownHosts(cfg.SSH.KnownHosts)
	enabled := cfg.Sandbox.Enabled == nil || *cfg.Sandbox.Enabled
	safety.SetSandboxConfig(safety.SandboxConfig{
		Enabled:    enabled,
		AllowWrite: cfg.Sandbox.AllowWrite,
		DenyRead:   cfg.Sandbox.DenyRead,
	})
	tools.SetModelLister(config.ListCombos)
	// totCost accumulates the model-step cost for the turn, so one number
	// lands in the usage event and the audit log.
	var totCost float64
	// resolveModel builds the provider + model for a combo. It is re-run on
	// every mid-turn switch so a stale or bad combo fails loudly instead of
	// silently continuing on the previous model.
	resolveModel := func(provName, mdl string) (llm.LanguageModel, error) {
		prov, ok := cfg.Providers[provName]
		if !ok {
			names := make([]string, 0, len(cfg.Providers))
			for n := range cfg.Providers {
				names = append(names, n)
			}
			return nil, wire.CodedError{Code: wire.CodeInvalidParam, Err: fmt.Errorf("unknown provider %q (configured: %s)", provName, strings.Join(names, ", "))}
		}
		if os.Getenv(prov.APIKeyEnv) == "" {
			return nil, wire.CodedError{Code: wire.CodeInvalidParam, Err: fmt.Errorf("provider %q: env var %s is not set", provName, prov.APIKeyEnv)}
		}
		p, err := providerFactory(provName, prov)
		if err != nil {
			return nil, err
		}
		return p.Model(mdl), nil
	}

	modelImpl, err := resolveModel(providerName, model)
	if err != nil {
		return err
	}

	if len(req.Messages) == 0 {
		return wire.CodedError{Code: wire.CodeInvalidParam, Err: errors.New("request contains no messages")}
	}

	out := bufio.NewWriter(outw)
	messages := make([]llm.Message, 0, len(req.Messages))
	for _, m := range req.Messages {
		if len(m.ToolCalls) > 0 || m.ToolCallID != "" || m.Role == "tool" {
			return wire.CodedError{Code: wire.CodeInvalidParam, Err: errors.New("persisted native tool messages are unsupported; flatten tool history into transcript text")}
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
			return wire.CodedError{Code: wire.CodeInvalidParam, Err: fmt.Errorf("unsupported message role %q", m.Role)}
		}
		var content []llm.Part
		if m.Content != "" {
			if role == llm.RoleUser {
				content, err = userParts(m.Content)
				if err != nil {
					return err
				}
			} else {
				content = append(content, llm.Part{Type: llm.PartText, Text: m.Content})
			}
		}
		messages = append(messages, llm.Message{Role: role, Content: content})
	}
	var totPrompt, totCompletion int
	lastPrompt := 0
	// contextPromptTokens is the full size of the prompt the model saw on a
	// step, including cached input. The SDK reports uncached input in
	// PromptTokens and the cached portions separately, so the full window
	// occupancy is their sum for every provider.
	contextPromptTokens := func(t *step) int {
		return t.prompt + t.cacheRead + t.cacheWrite
	}
	// stepCost prices one step at the model that produced it; the running
	// total keeps a mid-turn switch honest (each segment billed at its own
	// provider/model rate). Prices come from the committed catalog only.
	stepCost := func(t *step) float64 {
		info, ok := price.Lookup(providerName, model)
		if !ok {
			return 0
		}
		return price.Cost(info, t.prompt, t.cacheRead, t.cacheWrite, t.completion)
	}
	usagePayload := func(prompt, completion, contextPrompt int) map[string]any {
		m := map[string]any{"prompt": prompt, "completion": completion, "context_prompt": contextPrompt}
		if info, ok := price.Lookup(providerName, model); ok && info.ContextWindow > 0 {
			m["context_window"] = info.ContextWindow
		}
		if totCost > 0 {
			m["cost"] = totCost
		}
		return m
	}

	// Block spacing (R-blank-lines): blocks never start with newlines and
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

	pool := &taskPool{tasks: make(map[string]*backgroundTask)}
	defer func() { pool.wait(nil) }() // also reap tasks on model errors or iteration limit
	for iter := 0; ; iter++ {
		// Mid-turn injections land at the next model boundary — after the
		// previous round's tool batch, before the next generation. Steering
		// appends a native user message; a model switch rebuilds the
		// provider/model for the remainder of the turn. Both keep native tool
		// history intact, unlike a stop-and-resend.
		if iter > 0 {
			b := poll()
			if b.Provider != "" && (b.Provider != providerName || b.Model != model) {
				newImpl, serr := resolveModel(b.Provider, b.Model)
				if serr != nil {
					// A bad combo must not corrupt the turn: keep the current
					// model and surface the failure as an error marker.
					fmt.Fprintf(out, "<!-- yap:error\nmodel switch to %s/%s failed: %s\n-->\n\n", b.Provider, b.Model, serr)
					out.Flush()
					wrote, trail = true, 2
					wire.EmitEvent(map[string]any{
						"type":  "model_change",
						"from":  providerName + "/" + model,
						"to":    b.Provider + "/" + b.Model,
						"error": serr.Error(),
					})
				} else {
					from := providerName + "/" + model
					providerName, model = b.Provider, b.Model
					modelImpl = newImpl
					payload := render.MarshalCommentJSON(map[string]any{
						"from": from,
						"to":   providerName + "/" + model,
					}, "")
					fmt.Fprintf(out, "<!-- yap:model %s -->\n\n", payload)
					out.Flush()
					wrote, trail = true, 2
					wire.EmitEvent(map[string]any{
						"type":     "model_change",
						"from":     from,
						"to":       providerName + "/" + model,
						"provider": providerName,
						"model":    model,
					})
				}
			}
			if b.Steer != "" {
				fmt.Fprintf(out, "# @user\n%s\n\n# @assistant\n\n", render.EscapeProseText(b.Steer))
				out.Flush()
				wrote, trail = true, 2
				wire.EmitEvent(map[string]any{"type": "steer", "text": b.Steer})
				messages = append(messages, llm.Message{
					Role:    llm.RoleUser,
					Content: []llm.Part{{Type: llm.PartText, Text: b.Steer}},
				})
			}
		}
		// Prompt-cache breakpoint at the end of stable history (the last
		// assistant message): the trailing user message is excluded because it
		// carries the volatile cwd/git tail. Anthropic maps CacheControl to
		// cache_control; OpenAI/Gemini/DeepSeek/... ignore it.
		if iter == 0 {
			for i := len(messages) - 1; i >= 0; i-- {
				if messages[i].Role == llm.RoleAssistant {
					if c := messages[i].Content; len(c) > 0 {
						c[len(c)-1].CacheControl = "ephemeral"
					}
					break
				}
			}
		}
		t, err := streamStep(ctx, modelImpl, messages, out, wrote, req.Tools, req.ReasoningLevel)
		if err != nil {
			// Retry transient errors (429/5xx, network) only while the failed
			// step emitted nothing to the buffer: a mid-stream failure after
			// text has already streamed cannot be retried without corrupting
			// the document. Pre-stream failures are already retried by the
			// SDK, so this is a safety net for the remainder.
			for attempt := 0; err != nil && goai.IsRetryable(err) && (t == nil || !t.outWrote) && attempt < retryMaxAttempts; attempt++ {
				delay := retryDelay(attempt)
				wire.EmitEvent(map[string]any{
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
				t, err = streamStep(ctx, modelImpl, messages, out, wrote, req.Tools, req.ReasoningLevel)
			}
			if err != nil {
				return err
			}
		}
		totPrompt += t.prompt
		totCompletion += t.completion
		totCost += stepCost(t)
		lastPrompt = contextPromptTokens(t)
		if t.prompt+t.completion > 0 {
			m := usagePayload(totPrompt, totCompletion, lastPrompt)
			m["type"] = "usage"
			wire.EmitEvent(m)
		}
		if t.outWrote {
			wrote, trail = true, t.outTrail
		}

		if len(t.calls) == 0 {
			if ids := pool.pending(); len(ids) > 0 {
				// A final answer cannot race outstanding checks. Complete them,
				// show their output chronologically, and let the model revise its
				// answer with actual results rather than treating launch as success.
				results := pool.wait(ids)
				injection := "Background task results (automatic turn-scoped wait):\n" + render.FenceResult("bash", "", results) + "\nReview these before your final answer."
				pad()
				fmt.Fprintf(out, "# @user\n%s\n\n# @assistant\n\n", injection)
				out.Flush()
				wrote, trail = true, 2
				messages = append(messages, t.responseMessages...)
				messages = append(messages, llm.Message{Role: llm.RoleUser, Content: []llm.Part{{Type: llm.PartText, Text: injection}}})
				continue
			}
			if label, ok := detectTextToolCall(t.text); ok {
				// The model wrote a tool call as prose (flattened transcript
				// form, or <invoke> XML) instead of a native tool call, so
				// nothing ran. Surface it and stop — the intended call must
				// not be silently dropped from the transcript.
				pad()
				fmt.Fprintf(out, "<!-- yap:error\nmodel emitted a %s as plain text; the tool was not executed\n-->\n\n", label)
				wire.EmitEvent(map[string]any{"type": "tool_text_warning", "detail": label})
			} else if strings.TrimSpace(t.text) == "" {
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
		// Only an entire read-only round can run concurrently. Collect before
		// emitting regions so Markdown, audit IDs and native results stay in
		// model call order regardless of completion order.
		parallel := len(t.calls) > 1
		for _, call := range t.calls {
			if !parallelTools[call.Name] || !allowedTool(call.Name, req.Tools) || tools.Match(call.Name, call.Input) != "" {
				parallel = false
				break
			}
		}
		results := make([]taskResult, len(t.calls))
		if parallel {
			var wg sync.WaitGroup
			limit := make(chan struct{}, maxConcurrentTasks)
			for i, call := range t.calls {
				wg.Add(1)
				limit <- struct{}{}
				go func(i int, call llm.ToolCall) {
					defer wg.Done()
					defer func() { <-limit }()
					tool, _ := tools.Get(call.Name)
					results[i] = runTool(tool, call)
				}(i, call)
			}
			wg.Wait()
		}
		for i, call := range t.calls {
			// Flush the session-visible call before publishing its audit event.
			// Both are frames on one channel, so the header is on the wire
			// before the tool_call event (and any tool_output that follows).
			pad()
			render.EmitToolHeader(out, call)
			// Audit trail (event frame): the full call before
			// it runs, the full result after. The Lua side appends these
			// to the session's audit log, which is what makes slimmed
			// headers and :YapClear lossless.
			wire.EmitEvent(map[string]any{"type": "tool_call", "id": call.ID, "name": call.Name, "args": safety.Scrub(string(call.Input))})
			var value taskResult
			if parallel {
				value = results[i]
			} else {
				value = pool.call(call, req.Tools)
			}
			result, ui := value.result, value.ui
			render.EmitToolResult(out, result, ui)
			wire.EmitEvent(map[string]any{"type": "tool_result", "id": call.ID, "name": call.Name, "bytes": len(result), "result": result})
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
		// Prose for this round already streamed live before the tool regions;
		// the tool regions self-terminate with a blank line (R-blank-lines), so nothing
		// more to emit here.
		out.Flush()
	}

	if totPrompt+totCompletion > 0 {
		// End the turn with a blank line; the turn_end audit event below is
		// the single carrier of usage, folded by the Lua side.
		m := usagePayload(totPrompt, totCompletion, lastPrompt)
		pad()
		out.Flush()
		// Audit: one turn journal line (audit log).
		m["type"] = "turn_end"
		m["model"] = model
		m["ms"] = time.Since(start).Milliseconds()
		wire.EmitEvent(m)
	}
	out.Flush()
	return nil
}
