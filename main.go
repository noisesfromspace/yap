// pitel — LLM backend for the pitel Neovim plugin.
//
// The Neovim buffer is the conversation; this binary is the provider
// client and agent loop. It reads a JSON request on stdin and streams the
// assistant reply to stdout as plain text, interleaved with pitel:tool
// blocks when the model calls tools. Errors go to stderr with exit 1.
//
// Usage:
//
//	pitel send --provider NAME --model MODEL < request.json
//
// request.json: {"messages":[{"role":"system|user|assistant|tool", ...}]}
//
// ~/.pitel/config.json:
//
//	{
//	  "providers": {"moonshot": {"base_url": "...", "api_key_env": "..."}},
//	  "pricing":   {"kimi-k3": {"input": 0.6, "output": 2.5}},
//	  "max_tool_iterations": 8,
//	  "tools": {
//	    "fetch": {
//	      "description": "Fetch a URL and return its text",
//	      "schema": {"type": "object", "properties": {...}},
//	      "command": ["pitel-tool-fetch"]
//	    }
//	  }
//	  }
//	}
//
// Tools are subprocesses: the call arguments (JSON) go to stdin; stdout is
// the result sent back to the model. If stdout parses as
// {"result": "...", "ui": "..."}, "ui" becomes a display-only pitel:ui
// section in the buffer. Exit != 0 turns stderr into an error result.
//
// Any OpenAI-compatible /chat/completions endpoint works (OpenAI, DeepSeek,
// Moonshot/Kimi, OpenRouter, z.ai, local servers, ...).
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ─── Config ─────────────────────────────────────────────────────────────────

type Provider struct {
	BaseURL   string `json:"base_url"`
	APIKeyEnv string `json:"api_key_env"`
}

type Tool struct {
	Description string          `json:"description"`
	Schema      json.RawMessage `json:"schema"`
	Command     []string        `json:"command"`
}

type Config struct {
	Providers map[string]Provider `json:"providers"`
	// Optional per-model pricing in USD per 1M tokens; used to compute the
	// cost field in the pitel:usage marker.
	Pricing map[string]Pricing `json:"pricing"`
	// Tools the model may call (see package docs). Empty = no tool use.
	Tools map[string]Tool `json:"tools"`
	// Agent loop bound; defaults to 8.
	MaxToolIterations int `json:"max_tool_iterations"`
}

type Pricing struct {
	Input  float64 `json:"input"`
	Output float64 `json:"output"`
}

func configPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".pitel", "config.json")
}

func loadConfig() (*Config, error) {
	data, err := os.ReadFile(configPath())
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", configPath(), err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", configPath(), err)
	}
	return &cfg, nil
}

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

type toolDef struct {
	Type     string `json:"type"`
	Function struct {
		Name        string          `json:"name"`
		Description string          `json:"description"`
		Parameters  json.RawMessage `json:"parameters"`
	} `json:"function"`
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
			ReasoningContent string         `json:"reasoning_content"`
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

// ─── Tools ───────────────────────────────────────────────────────────────────

func toolDefs(cfg *Config) []toolDef {
	if len(cfg.Tools) == 0 {
		return nil
	}
	defs := make([]toolDef, 0, len(cfg.Tools))
	for name, t := range cfg.Tools {
		var d toolDef
		d.Type = "function"
		d.Function.Name = name
		d.Function.Description = t.Description
		d.Function.Parameters = t.Schema
		defs = append(defs, d)
	}
	return defs
}

// executeTool runs a tool subprocess: arguments JSON on stdin, result on
// stdout. Returns (result, ui); ui is the optional display-only payload.
func executeTool(t Tool, arguments string) (string, string) {
	if len(t.Command) == 0 {
		return "error: tool has no command configured", ""
	}
	cmd := exec.Command(t.Command[0], t.Command[1:]...)
	cmd.Stdin = strings.NewReader(arguments)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return "error: " + msg, ""
	}
	out := stdout.Bytes()
	// Rich protocol: {"result": "...", "ui": "..."}; anything else is a
	// plain-text result.
	var rich struct {
		Result string `json:"result"`
		UI     string `json:"ui"`
	}
	if json.Unmarshal(out, &rich) == nil && rich.Result != "" {
		return rich.Result, rich.UI
	}
	return strings.TrimRight(string(out), "\n"), ""
}

// ─── Send (agent loop) ───────────────────────────────────────────────────────

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
	defs := toolDefs(cfg)
	maxIter := cfg.MaxToolIterations
	if maxIter <= 0 {
		maxIter = 8
	}
	out := bufio.NewWriter(os.Stdout)
	messages := req.Messages
	var totPrompt, totCompletion int

	for iter := 0; ; iter++ {
		t, err := streamCompletion(chatRequest{
			Model:    model,
			Messages: messages,
			Stream:   true,
			Tools:    defs,
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
				// are not configured). Never fail silently.
				reason := t.finishReason
				if reason == "" {
					reason = "unknown"
				}
				fmt.Fprintf(out, "\n\n<!-- pitel:error\nmodel returned an empty completion (finish_reason: %s)\n-->", reason)
			}
			break // final answer streamed; turn complete
		}
		if iter+1 >= maxIter {
			fmt.Fprintf(out, "\n\n<!-- pitel:error\nmax tool iterations (%d) reached\n-->\n", maxIter)
			break
		}

		// Append the assistant turn with its calls to the request-local
		// history, execute each call, and emit one pitel:tool region per
		// call+result pair (R12) — both to the buffer and to the history.
		messages = append(messages, Message{Role: "assistant", Content: t.text, ToolCalls: t.calls})
		for _, call := range t.calls {
			tool, ok := cfg.Tools[call.Function.Name]
			var result, ui string
			if !ok {
				result = "error: unknown tool " + call.Function.Name
			} else {
				result, ui = executeTool(tool, call.Function.Arguments)
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

// ─── Main ────────────────────────────────────────────────────────────────────

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: pitel send --provider NAME --model MODEL < request.json")
		os.Exit(2)
	}

	switch os.Args[1] {
	case "send":
		fs := flag.NewFlagSet("send", flag.ExitOnError)
		provider := fs.String("provider", "", "provider name from config.json")
		model := fs.String("model", "", "model name")
		fs.Parse(os.Args[2:])
		if *provider == "" || *model == "" {
			fmt.Fprintln(os.Stderr, "send: --provider and --model are required")
			os.Exit(2)
		}
		if err := send(*provider, *model); err != nil {
			fmt.Fprintln(os.Stderr, "pitel:", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}
