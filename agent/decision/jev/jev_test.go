package jev

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"boers.email/yap/agent/decision"
)

func TestDecide(t *testing.T) {
	var gotAuth string
	var body map[string]any

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{
			"model":"typesafe/jev-1.13-20260917",
			"answers":{
				"is_bug":{"type":"noul","noul":0.96},
				"team":{"type":"choice","choice":"payments","confidence":0.67,"probabilities":{"account":0,"frontend":0.22,"payments":0.78}},
				"urgency":{"type":"score","score":1.99,"confidence":0.99,"probabilities":{"0":0,"1":0,"2":1},"legend":{"0":"Can wait","1":"This week","2":"Blocking"}}
			},
			"usage":{"input_tokens":476,"output_tokens":70,"cost":0.000019992}
		}`)
	}))
	defer srv.Close()

	m := New(Config{BaseURL: srv.URL, APIKey: "sekret", Model: "typesafe/jev-1.13"})
	resp, err := m.Decide(context.Background(), decision.Request{
		State: map[string]any{"ticket": "blank checkout"},
		Questions: []decision.Question{
			{Name: "is_bug", Type: decision.Noul, Instructions: "Is this a bug?", Criteria: map[string]string{"true": "broken", "false": "feature"}},
			{Name: "team", Type: decision.Choice, Instructions: "Which team?", Criteria: map[string]string{"payments": "checkout"}},
			{Name: "urgency", Type: decision.Score, Instructions: "How urgent?", Criteria: []string{"Can wait", "This week", "Blocking"}},
		},
	})
	if err != nil {
		t.Fatalf("decide: %v", err)
	}

	// request shape: auth header, model, state, parallel questions
	if gotAuth != "Bearer sekret" {
		t.Fatalf("auth: %q", gotAuth)
	}
	if body["model"] != "typesafe/jev-1.13" {
		t.Fatalf("model: %v", body["model"])
	}
	if body["state"].(map[string]any)["ticket"] != "blank checkout" {
		t.Fatalf("state: %v", body["state"])
	}
	qs := body["questions"].(map[string]any)
	if len(qs) != 3 {
		t.Fatalf("questions: %v", qs)
	}
	if crit := qs["urgency"].(map[string]any)["criteria"]; crit == nil {
		t.Fatalf("urgency criteria missing: %v", qs["urgency"])
	}

	// response decoding: one typed answer per question
	if resp.Model != "typesafe/jev-1.13-20260917" {
		t.Fatalf("resp model: %q", resp.Model)
	}
	if a := resp.Answers["is_bug"]; a.Type != decision.Noul || a.Noul != 0.96 {
		t.Fatalf("noul answer: %+v", a)
	}
	if a := resp.Answers["team"]; a.Choice != "payments" || a.Probabilities["payments"] != 0.78 {
		t.Fatalf("choice answer: %+v", a)
	}
	if a := resp.Answers["urgency"]; a.Score != 1.99 || a.Legend["2"] != "Blocking" {
		t.Fatalf("score answer: %+v", a)
	}
}

func TestDecideError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"message":"state too large"}}`)
	}))
	defer srv.Close()

	_, err := New(Config{BaseURL: srv.URL}).Decide(context.Background(), decision.Request{
		State:     "x",
		Questions: []decision.Question{{Name: "q", Type: decision.Noul, Criteria: map[string]string{"true": "y", "false": "n"}}},
	})
	if err == nil || !strings.Contains(err.Error(), "state too large") {
		t.Fatalf("error: %v", err)
	}
}

func TestDecideDefaults(t *testing.T) {
	var gotModel string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		gotModel, _ = body["model"].(string)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"model":"typesafe/jev-1.13-20260917","answers":{},"usage":{}}`)
	}))
	defer srv.Close()

	m := New(Config{BaseURL: srv.URL})
	if _, err := m.Decide(context.Background(), decision.Request{
		State:     "x",
		Questions: []decision.Question{{Name: "q", Type: decision.Noul, Criteria: map[string]string{"true": "y", "false": "n"}}},
	}); err != nil {
		t.Fatalf("decide: %v", err)
	}
	if gotModel != DefaultModel {
		t.Fatalf("default model: %q", gotModel)
	}
}
