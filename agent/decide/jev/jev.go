// Package jev adapts TypeSafe's Jev decision model to Yap's decision
// surface. Jev is a System One decision model, not a language model: it takes
// a state plus typed questions and returns calibrated probabilities in one
// parallel pass. It is reached through OpenRouter's Decisions API (alpha),
// authenticated by a plain OpenRouter API key.
package jev

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"boers.email/yap/agent/decide"
)

const (
	// DefaultBaseURL is OpenRouter's Decisions API endpoint.
	DefaultBaseURL = "https://openrouter.ai/api/alpha/decisions"
	// DefaultModel is the pinned Jev release. Pin this (not
	// ~typesafe/jev-latest) when thresholds are tuned against a version.
	DefaultModel = "typesafe/jev-1.13"
)

// Config builds a Jev-backed decide.Model. Zero values fall back to
// OpenRouter's Decisions endpoint and the pinned Jev release.
type Config struct {
	BaseURL string
	APIKey  string
	Model   string
}

type client struct {
	baseURL string
	apiKey  string
	model   string
	http    *http.Client
}

// New returns a decide.Model backed by Jev via the OpenRouter Decisions API.
func New(cfg Config) decide.Model {
	if cfg.BaseURL == "" {
		cfg.BaseURL = DefaultBaseURL
	}
	if cfg.Model == "" {
		cfg.Model = DefaultModel
	}
	return &client{
		baseURL: cfg.BaseURL,
		apiKey:  cfg.APIKey,
		model:   cfg.Model,
		http:    &http.Client{Timeout: 30 * time.Second},
	}
}

// questionJSON is the Decisions API wire shape of one question.
type questionJSON struct {
	Type         string          `json:"type"`
	Instructions string          `json:"instructions"`
	Criteria     json.RawMessage `json:"criteria"`
}

func (c *client) Decide(ctx context.Context, req decide.Request) (decide.Response, error) {
	if len(req.Questions) == 0 {
		return decide.Response{}, fmt.Errorf("jev: at least one question is required")
	}
	questions := make(map[string]questionJSON, len(req.Questions))
	for _, q := range req.Questions {
		crit, err := json.Marshal(q.Criteria)
		if err != nil {
			return decide.Response{}, fmt.Errorf("jev: question %q: criteria: %w", q.Name, err)
		}
		questions[q.Name] = questionJSON{
			Type:         string(q.Type),
			Instructions: q.Instructions,
			Criteria:     crit,
		}
	}
	body, err := json.Marshal(map[string]any{
		"model":     c.model,
		"state":     req.State,
		"questions": questions,
	})
	if err != nil {
		return decide.Response{}, fmt.Errorf("jev: marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL, bytes.NewReader(body))
	if err != nil {
		return decide.Response{}, fmt.Errorf("jev: build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.apiKey != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return decide.Response{}, fmt.Errorf("jev: %w", err)
	}
	defer resp.Body.Close() //nolint:errcheck // best-effort: close on read

	if resp.StatusCode != http.StatusOK {
		return decide.Response{}, decodeError(resp)
	}

	var wire struct {
		Model   string                `json:"model"`
		Answers map[string]answerJSON `json:"answers"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wire); err != nil {
		return decide.Response{}, fmt.Errorf("jev: decode response: %w", err)
	}

	out := decide.Response{
		Answers: make(map[string]decide.Answer, len(wire.Answers)),
		Model:   wire.Model,
	}
	for name, a := range wire.Answers {
		ans, err := a.toAnswer(name)
		if err != nil {
			return decide.Response{}, err
		}
		out.Answers[name] = ans
	}
	return out, nil
}

type answerJSON struct {
	Type          string             `json:"type"`
	Noul          *float64           `json:"noul"`
	Choice        *string            `json:"choice"`
	Score         *float64           `json:"score"`
	Confidence    *float64           `json:"confidence"`
	Probabilities map[string]float64 `json:"probabilities"`
	Legend        map[string]string  `json:"legend"`
}

func (a answerJSON) toAnswer(name string) (decide.Answer, error) {
	ans := decide.Answer{
		Name:          name,
		Type:          decide.QuestionType(a.Type),
		Probabilities: a.Probabilities,
		Legend:        a.Legend,
	}
	switch a.Type {
	case "noul":
		if a.Noul == nil {
			return ans, fmt.Errorf("jev: answer %q: missing noul value", name)
		}
		ans.Noul = *a.Noul
	case "choice":
		if a.Choice == nil {
			return ans, fmt.Errorf("jev: answer %q: missing choice value", name)
		}
		ans.Choice = *a.Choice
	case "score":
		if a.Score == nil {
			return ans, fmt.Errorf("jev: answer %q: missing score value", name)
		}
		ans.Score = *a.Score
	default:
		return ans, fmt.Errorf("jev: answer %q: unknown type %q", name, a.Type)
	}
	if a.Confidence != nil {
		ans.Confidence = *a.Confidence
	}
	return ans, nil
}

func decodeError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var e struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
		Message string `json:"message"`
	}
	_ = json.Unmarshal(body, &e)
	msg := strings.TrimSpace(strings.TrimSpace(e.Error.Message) + " " + strings.TrimSpace(e.Message))
	if msg == "" {
		msg = strings.TrimSpace(string(body))
	}
	if msg == "" {
		msg = resp.Status
	}
	return fmt.Errorf("decisions API %s: %s", resp.Status, msg)
}
