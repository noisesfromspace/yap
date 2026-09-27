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
	"strings"

	"pitel/tools"
)

// Bound on tool-call iterations per send (gptel has none; runaway loops
// burn tokens silently).
const maxToolIterations = 8

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
}

// streamCompletion performs one streaming chat completion, writing text and
// thinking markers to out as they arrive, and returns what the model said.
func streamCompletion(req chatRequest, url, apiKey string, out *bufio.Writer) (*turn, error) {
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
					out.WriteString("<!-- pitel:thinking\n")
					inThinking = true
				}
				out.WriteString(c.Delta.ReasoningContent)
				out.Flush()
			}
			if c.Delta.Content != "" {
				if inThinking {
					out.WriteString("\n-->\n\n")
					inThinking = false
				}
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
		out.WriteString("\n-->\n")
	}
	for i := 0; i < len(callArgs); i++ {
		if tc, ok := callArgs[i]; ok {
			tc.Type = "function"
			t.calls = append(t.calls, *tc)
		}
	}
	return t, nil
}

// emitToolBlock writes a completed pitel:tool region (header = full call,
// result text, optional display-only ui section) to the stream.
func emitToolBlock(out *bufio.Writer, call ToolCall, result, ui string) {
	var args any
	if err := json.Unmarshal([]byte(call.Function.Arguments), &args); err != nil {
		args = call.Function.Arguments // malformed/truncated JSON: keep raw
	}
	header, _ := json.Marshal(map[string]any{
		"id":        call.ID,
		"name":      call.Function.Name,
		"arguments": args,
	})
	fmt.Fprintf(out, "\n\n<!-- pitel:tool %s -->\n%s\n", header, result)
	if ui != "" {
		fmt.Fprintf(out, "<!-- pitel:ui\n%s\n-->\n", ui)
	}
	out.WriteString("<!-- /pitel:tool -->\n")
	out.Flush()
}

func send(providerName, model string) error {
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
	if err := json.NewDecoder(os.Stdin).Decode(&req); err != nil {
		return fmt.Errorf("read request from stdin: %w", err)
	}
	if len(req.Messages) == 0 {
		return errors.New("request contains no messages")
	}

	url := strings.TrimRight(prov.BaseURL, "/") + "/chat/completions"
	out := bufio.NewWriter(os.Stdout)
	messages := req.Messages
	var totPrompt, totCompletion int

	for iter := 0; ; iter++ {
		t, err := streamCompletion(chatRequest{
			Model:    model,
			Messages: messages,
			Stream:   true,
			Tools:    toolDefs(),
			StreamOptions: &struct {
				IncludeUsage bool `json:"include_usage"`
			}{IncludeUsage: true},
		}, url, apiKey, out)
		if err != nil {
			return err
		}
		totPrompt += t.prompt
		totCompletion += t.completion

		if len(t.calls) == 0 {
			if strings.TrimSpace(t.text) == "" {
				// An empty completion is always an anomaly (provider hiccup,
				// token budget eaten by reasoning, model expected tools that
				// are not compiled in). Never fail silently.
				reason := t.finishReason
				if reason == "" {
					reason = "unknown"
				}
				fmt.Fprintf(out, "\n\n<!-- pitel:error\nmodel returned an empty completion (finish_reason: %s)\n-->", reason)
			}
			break // final answer streamed; turn complete
		}
		if iter+1 >= maxToolIterations {
			fmt.Fprintf(out, "\n\n<!-- pitel:error\nmax tool iterations (%d) reached\n-->\n", maxToolIterations)
			break
		}

		// Append the assistant turn with its calls to the request-local
		// history, execute each call, and emit one pitel:tool region per
		// call+result pair (R12) — both to the buffer and to the history.
		messages = append(messages, Message{Role: "assistant", Content: t.text, ToolCalls: t.calls})
		for _, call := range t.calls {
			tool, ok := tools.Get(call.Function.Name)
			var result, ui string
			if !ok {
				result = "error: unknown tool " + call.Function.Name
			} else {
				var err error
				result, ui, err = tool.Run(json.RawMessage(call.Function.Arguments))
				if err != nil {
					result = "error: " + err.Error()
					ui = ""
				}
			}
			emitToolBlock(out, call, result, ui)
			messages = append(messages, Message{Role: "tool", ToolCallID: call.ID, Content: result})
		}
		out.WriteString("\n")
	}

	if totPrompt+totCompletion > 0 {
		// Reported as a parse-excluded marker; the Lua side folds it into
		// the session frontmatter and removes the line.
		m := map[string]any{"prompt": totPrompt, "completion": totCompletion}
		if p, ok := cfg.Pricing[model]; ok {
			m["cost"] = float64(totPrompt)/1e6*p.Input + float64(totCompletion)/1e6*p.Output
		}
		b, _ := json.Marshal(m)
		fmt.Fprintf(out, "\n<!-- pitel:usage %s -->\n", b)
	}
	out.Flush()
	return nil
}
