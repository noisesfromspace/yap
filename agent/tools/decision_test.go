package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"boers.email/yap/agent/decide"
)

type fakeDecision struct {
	resp decide.Response
	err  error
	req  decide.Request
}

func (f *fakeDecision) Decide(_ context.Context, req decide.Request) (decide.Response, error) {
	f.req = req
	return f.resp, f.err
}

func TestDecision(t *testing.T) {
	old := decisionModel
	defer func() { decisionModel = old }()

	f := &fakeDecision{resp: decide.Response{
		Model: "typesafe/jev-1.13-20260917",
		Answers: map[string]decide.Answer{
			"team": {
				Name: "team", Type: decide.Choice, Choice: "payments", Confidence: 0.67,
				Probabilities: map[string]float64{"account": 0, "frontend": 0.22, "payments": 0.78},
			},
			"is_bug": {Name: "is_bug", Type: decide.Noul, Noul: 0.96},
			"urgency": {Name: "urgency", Type: decide.Score, Score: 1.99, Confidence: 0.99,
				Legend: map[string]string{"0": "Can wait", "1": "This week", "2": "Blocking"}},
		},
	}}
	decisionModel = f

	r, _, err := run(t, "decision", `{"state":"checkout page blank after Pay","questions":[
		{"name":"is_bug","type":"noul","instructions":"Is this a bug?","criteria":{"true":"broken","false":"feature"}},
		{"name":"team","type":"choice","instructions":"Which team?","criteria":{"payments":"checkout"}},
		{"name":"urgency","type":"score","instructions":"How urgent?","criteria":["Can wait","This week","Blocking"]}
	]}`)
	if err != nil {
		t.Fatalf("decision: %v", err)
	}

	// answers render sorted by name, with the typed values the model needs
	for _, want := range []string{
		"## Decisions (typesafe/jev-1.13-20260917)",
		"- **is_bug** (noul): P(yes) = 0.960",
		"- **team** (choice): payments",
		"confidence=0.670",
		"probabilities=account=0.00, frontend=0.22, payments=0.78",
		"- **urgency** (score): 1.990",
		"legend=0=Can wait, 1=This week, 2=Blocking",
	} {
		if !strings.Contains(r, want) {
			t.Fatalf("missing %q in:\n%s", want, r)
		}
	}

	// the tool converts args to the decide.Request surface
	if f.req.State != "checkout page blank after Pay" {
		t.Fatalf("state: %#v", f.req.State)
	}
	if len(f.req.Questions) != 3 {
		t.Fatalf("questions: %d", len(f.req.Questions))
	}
	if q := f.req.Questions[0]; q.Name != "is_bug" || q.Type != decide.Noul {
		t.Fatalf("question 0: %+v", q)
	}
	if q := f.req.Questions[2]; q.Type != decide.Score {
		t.Fatalf("question 2: %+v", q)
	}
	if crit, ok := f.req.Questions[2].Criteria.([]any); !ok || len(crit) != 3 {
		t.Fatalf("score criteria: %#v", f.req.Questions[2].Criteria)
	}
}

func TestDecisionValidation(t *testing.T) {
	old := decisionModel
	defer func() { decisionModel = old }()

	// no backend configured
	decisionModel = nil
	if _, _, err := run(t, "decision", `{"state":"x","questions":[{"name":"q","type":"noul","instructions":"?","criteria":{"true":"y","false":"n"}}]}`); err == nil || !strings.Contains(err.Error(), "no decision model") {
		t.Fatalf("no model: %v", err)
	}
	decisionModel = &fakeDecision{}

	cases := []struct{ args, want string }{
		{`{"state":"x","questions":[]}`, "at least one question"},
		{`{"state":null,"questions":[{"name":"q","type":"noul","instructions":"?","criteria":{"true":"y","false":"n"}}]}`, "state must be"},
		{`{"state":"x","questions":[{"name":"q","type":"noul","instructions":"?","criteria":["y","n"]}]}`, "must be an object"},
		{`{"state":"x","questions":[{"name":"q","type":"score","instructions":"?","criteria":{"a":"b"}}]}`, "array of ordered"},
		{`{"state":"x","questions":[{"name":"q","type":"bogus","instructions":"?","criteria":{"a":"b"}}]}`, "value must be one of"},
		{`{"state":"x","questions":[{"name":"q","type":"noul","instructions":"?","criteria":null}]}`, "must be an object"},
	}
	for _, c := range cases {
		if _, _, err := run(t, "decision", c.args); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Fatalf("case %q: got %v, want %q", c.args, err, c.want)
		}
	}

	// backend errors propagate
	decisionModel = &fakeDecision{err: context.DeadlineExceeded}
	if _, _, err := run(t, "decision", `{"state":"x","questions":[{"name":"q","type":"noul","instructions":"?","criteria":{"true":"y","false":"n"}}]}`); err == nil {
		t.Fatal("expected backend error to propagate")
	}
}

// TestDecisionSchemaDescriptionsIntact guards against comma-truncation in
// jsonschema tags: descriptions must be carried verbatim via the
// jsonschema_description tag, not split on commas inside description=...
func TestDecisionSchemaDescriptionsIntact(t *testing.T) {
	tl, ok := Get("decision")
	if !ok {
		t.Fatal("decision not registered")
	}
	var doc map[string]any
	if err := json.Unmarshal(tl.Schema, &doc); err != nil {
		t.Fatalf("parse schema: %v", err)
	}
	props := doc["properties"].(map[string]any)
	state := props["state"].(map[string]any)
	if d := state["description"].(string); !strings.Contains(d, "a JSON array of related context") {
		t.Fatalf("state description truncated: %q", d)
	}
	q := props["questions"].(map[string]any)["items"].(map[string]any)["properties"].(map[string]any)
	for field, want := range map[string]string{
		"instructions": "phrased so the answer is unambiguous",
		"criteria":     "for score: an array of ordered level labels",
	} {
		if d := q[field].(map[string]any)["description"].(string); !strings.Contains(d, want) {
			t.Fatalf("%s description truncated: %q", field, d)
		}
	}
}
