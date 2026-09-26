// pitel — LLM backend for the pitel Neovim plugin.
//
// The Neovim buffer is the conversation; this binary is just a provider
// client. It reads a JSON request on stdin and streams the assistant reply
// to stdout as plain text. Errors go to stderr with exit code 1.
//
// Usage:
//
//	pitel send --provider NAME --model MODEL < request.json
//
// request.json: {"messages":[{"role":"system|user|assistant","content":"..."}]}
//
// Providers are configured in ~/.config/pitel/config.json:
//
//	{
//	  "providers": {
//	    "moonshot": {
//	      "base_url": "https://api.moonshot.ai/v1",
//	      "api_key_env": "MOONSHOT_API_KEY"
//	    }
//	  }
//	}
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
	"path/filepath"
	"strings"
)

// ─── Config ─────────────────────────────────────────────────────────────────

type Provider struct {
	BaseURL   string `json:"base_url"`
	APIKeyEnv string `json:"api_key_env"`
}

type Config struct {
	Providers map[string]Provider `json:"providers"`
}

func configPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "pitel", "config.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "pitel", "config.json")
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

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type Request struct {
	Messages []Message `json:"messages"`
}

type chatRequest struct {
	Model    string    `json:"model"`
	Messages []Message `json:"messages"`
	Stream   bool      `json:"stream"`
}

type streamChunk struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
			// ReasoningContent is the OpenAI-compatible thinking field
			// (DeepSeek, Moonshot/Kimi). Streamed wrapped in a
			// <!-- pitel:thinking --> marker, which parse_buffer excludes
			// from the message array on the next send.
			ReasoningContent string `json:"reasoning_content"`
		} `json:"delta"`
	} `json:"choices"`
}

type apiError struct {
	Error struct {
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error"`
}

// ─── Send ────────────────────────────────────────────────────────────────────

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

	body, err := json.Marshal(chatRequest{Model: model, Messages: req.Messages, Stream: true})
	if err != nil {
		return err
	}

	url := strings.TrimRight(prov.BaseURL, "/") + "/chat/completions"
	httpReq, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+apiKey)
	httpReq.Header.Set("Accept", "text/event-stream")

	client := &http.Client{Timeout: 0} // no total timeout; streams can be long
	resp, err := client.Do(httpReq)
	if err != nil {
		return fmt.Errorf("POST %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		var ae apiError
		if json.Unmarshal(errBody, &ae) == nil && ae.Error.Message != "" {
			return fmt.Errorf("%s: %s", resp.Status, ae.Error.Message)
		}
		return fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(errBody)))
	}

	// SSE stream: lines of "data: {json}", terminated by "data: [DONE]".
	// Thinking (reasoning_content) arrives before content; it is wrapped in
	// an HTML comment marker that the Lua side strips on parse.
	out := bufio.NewWriter(os.Stdout)
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
		for _, c := range chunk.Choices {
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
				out.Flush()
			}
		}
	}
	if inThinking {
		// Stream ended mid-thinking (or the model emitted nothing else):
		// close the marker so the block stays parseable.
		out.WriteString("\n-->\n")
	}
	out.Flush()
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("reading stream: %w", err)
	}
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
