package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"boers.email/yap/agent/decide"
)

// The jev tool is the agent's calibrated-decision primitive. It is NOT
// wired to Jev directly: it calls the decide.Model installed by the
// agent loop (SetDecisionModel). The default backend is Jev via
// OpenRouter's Decisions API (agent/decide/jev), but any decide.Model
// with the same typed surface can be swapped in without touching this file.

// decisionModel is the backend the jev tool calls; set once per turn by
// the agent loop before the model can call tools.
var decisionModel decide.Model

// SetDecisionModel installs the decision backend for the jev tool.
func SetDecisionModel(m decide.Model) {
	decisionModel = m
}

type jevQuestionArg struct {
	Name         string          `json:"name" jsonschema:"description=unique name for this answer"`
	Type         string          `json:"type" jsonschema:"description=question type,enum=noul,enum=choice,enum=score"`
	Instructions string          `json:"instructions" jsonschema_description:"what is being decided, phrased so the answer is unambiguous"`
	Criteria     json.RawMessage `json:"criteria" jsonschema_description:"for noul: an object {true: description, false: description}; for choice: an object mapping each option to a short description; for score: an array of ordered level labels"`
}

type jevArgs struct {
	State     json.RawMessage  `json:"state" jsonschema_description:"the content to evaluate: a string, a JSON object, or a JSON array of related context"`
	Questions []jevQuestionArg `json:"questions" jsonschema:"description=one or more independent decisions to make about state (answered in parallel)"`
}

func init() {
	Register("jev",
		"Ask a decision model for typed, calibrated answers about a state. Returns probabilities, not prose: "+
			"noul gives P(yes), choice picks a labelled option with per-option probabilities and confidence, "+
			"score gives a probability-weighted position on an ordered scale. Use when reasoning or code needs a "+
			"probability to branch on (gates, classification, yes/no checks).",
		func(a *jevArgs) (string, string, error) { return runJev(a) })
}

func runJev(a *jevArgs) (string, string, error) {
	if decisionModel == nil {
		return "", "", fmt.Errorf("no decision model configured")
	}
	if len(a.Questions) == 0 {
		return "", "", fmt.Errorf("at least one question is required")
	}

	req := decide.Request{}
	if err := unmarshalState(a.State, &req.State); err != nil {
		return "", "", err
	}
	for _, q := range a.Questions {
		crit, err := unmarshalCriteria(q)
		if err != nil {
			return "", "", err
		}
		req.Questions = append(req.Questions, decide.Question{
			Name:         q.Name,
			Type:         decide.QuestionType(q.Type),
			Instructions: q.Instructions,
			Criteria:     crit,
		})
	}

	resp, err := decisionModel.Decide(context.Background(), req)
	if err != nil {
		return "", "", err
	}
	return formatDecisions(resp), "", nil
}

func unmarshalState(raw json.RawMessage, dst *any) error {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return fmt.Errorf("state must be a string, a JSON object, or a JSON array")
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return fmt.Errorf("state: %w", err)
	}
	return nil
}

func unmarshalCriteria(q jevQuestionArg) (any, error) {
	var crit any
	if err := json.Unmarshal(q.Criteria, &crit); err != nil {
		return nil, fmt.Errorf("question %q: criteria: %w", q.Name, err)
	}
	switch decide.QuestionType(q.Type) {
	case decide.Noul, decide.Choice:
		if _, ok := crit.(map[string]any); !ok {
			return nil, fmt.Errorf("question %q: %s criteria must be an object mapping options to descriptions", q.Name, q.Type)
		}
	case decide.Score:
		if _, ok := crit.([]any); !ok {
			return nil, fmt.Errorf("question %q: score criteria must be an array of ordered level labels", q.Name)
		}
	default:
		return nil, fmt.Errorf("question %q: unknown type %q (want noul, choice, or score)", q.Name, q.Type)
	}
	return crit, nil
}

func formatDecisions(resp decide.Response) string {
	var b strings.Builder
	if resp.Model != "" {
		fmt.Fprintf(&b, "## Decisions (%s)\n", resp.Model)
	} else {
		b.WriteString("## Decisions\n")
	}
	names := make([]string, 0, len(resp.Answers))
	for n := range resp.Answers {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		a := resp.Answers[n]
		switch a.Type {
		case decide.Noul:
			fmt.Fprintf(&b, "- **%s** (noul): P(yes) = %.3f\n", n, a.Noul)
		case decide.Choice:
			fmt.Fprintf(&b, "- **%s** (choice): %s", n, a.Choice)
			writeMeta(&b, confPart(a), probPart(a.Probabilities))
			b.WriteString("\n")
		case decide.Score:
			fmt.Fprintf(&b, "- **%s** (score): %.3f", n, a.Score)
			writeMeta(&b, confPart(a), legendPart(a.Legend))
			b.WriteString("\n")
		default:
			fmt.Fprintf(&b, "- **%s**: %+v\n", n, a)
		}
	}
	return b.String()
}

func writeMeta(b *strings.Builder, parts ...string) {
	var kept []string
	for _, p := range parts {
		if p != "" {
			kept = append(kept, p)
		}
	}
	if len(kept) > 0 {
		fmt.Fprintf(b, " (%s)", strings.Join(kept, ", "))
	}
}

func confPart(a decide.Answer) string {
	if a.Confidence <= 0 {
		return ""
	}
	return fmt.Sprintf("confidence=%.3f", a.Confidence)
}

func probPart(p map[string]float64) string {
	if len(p) == 0 {
		return ""
	}
	return "probabilities=" + formatProbabilities(p)
}

func legendPart(l map[string]string) string {
	if len(l) == 0 {
		return ""
	}
	return "legend=" + formatLegend(l)
}

// formatProbabilities joins option -> probability. For score answers the
// keys are level indices "0".."9", so lexical order equals numeric order.
func formatProbabilities(p map[string]float64) string {
	keys := make([]string, 0, len(p))
	for k := range p {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%.2f", k, p[k]))
	}
	return strings.Join(parts, ", ")
}

func formatLegend(l map[string]string) string {
	keys := make([]string, 0, len(l))
	for k := range l {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%s", k, l[k]))
	}
	return strings.Join(parts, ", ")
}
