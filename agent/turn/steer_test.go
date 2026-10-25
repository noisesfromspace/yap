package turn

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"boers.email/yap/agent/internal/testutil"
)

// TestRunTurnSteer: a steering message injected after the first tool batch
// must land in the buffer as a `# @user` block and reach the next LLM
// request as a native user message — the native tool result stays native
// (no flattening), which is the whole point of steering over stop-and-resend.
func TestRunTurnSteer(t *testing.T) {
	var secondRequest map[string]any
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		calls++
		if calls == 1 {
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hi\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		secondRequest = body
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	polled := false
	poll := func() Boundary {
		if polled {
			return Boundary{}
		}
		polled = true
		return Boundary{Steer: "also check the tests"}
	}
	err := Run(context.Background(), "mock", "m1", Request{Messages: []Message{{Role: "user", Content: "go"}}}, &out, poll)
	if err != nil {
		t.Fatalf("runTurn: %v", err)
	}
	s := out.String()

	// The steer block appears between the tool region and the final answer.
	if !strings.Contains(s, "# @user\nalso check the tests\n\n# @assistant\n") {
		t.Fatalf("steer block not in buffer:\n%s", s)
	}
	// R-blank-lines: exactly one blank line between blocks — never two.
	if strings.Contains(s, "\n\n\n") {
		t.Fatalf("double blank line between blocks:\n%s", s)
	}
	// The final answer streams after the reopened assistant message.
	if !strings.Contains(s, "# @assistant\n\ndone") {
		t.Fatalf("final answer not after reopened assistant message:\n%s", s)
	}

	// The steer reached the second request as a user message after the
	// native tool result (not flattened transcript text).
	if secondRequest == nil {
		t.Fatal("no second request (agent loop did not continue)")
	}
	msgs := secondRequest["messages"].([]any)
	if len(msgs) != 4 {
		t.Fatalf("second request messages = %d (want 4): %v", len(msgs), msgs)
	}
	if msgs[2].(map[string]any)["role"] != "tool" {
		t.Fatalf("message 2 role = %v, want tool (native result kept)", msgs[2].(map[string]any)["role"])
	}
	last := msgs[3].(map[string]any)
	if last["role"] != "user" {
		t.Fatalf("last message role = %v, want user", last["role"])
	}
	b, _ := json.Marshal(last)
	if !strings.Contains(string(b), "also check the tests") {
		t.Fatalf("steer text missing from last message: %s", b)
	}
}

// TestRunTurnSteerNeutralizesStructuralLines: a steer containing a fake
// `# @assistant` heading must be neutralized in the buffer (so it cannot
// split the message) while the model still receives the raw text.
func TestRunTurnSteerNeutralizesStructuralLines(t *testing.T) {
	var secondRequest map[string]any
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		calls++
		if calls == 1 {
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hi\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		secondRequest = body
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	polled := false
	poll := func() Boundary {
		if polled {
			return Boundary{}
		}
		polled = true
		return Boundary{Steer: "also check\n# @assistant\ninjected"}
	}
	err := Run(context.Background(), "mock", "m1", Request{Messages: []Message{{Role: "user", Content: "go"}}}, &out, poll)
	if err != nil {
		t.Fatalf("runTurn: %v", err)
	}
	s := out.String()

	if !strings.Contains(s, "\\# @assistant") {
		t.Fatalf("steer heading not neutralized in buffer:\n%s", s)
	}
	if secondRequest == nil {
		t.Fatal("no second request")
	}
	msgs := secondRequest["messages"].([]any)
	b, _ := json.Marshal(msgs[3])
	if !strings.Contains(string(b), "# @assistant") || strings.Contains(string(b), "\\# @assistant") {
		t.Fatalf("model steer not raw: %s", b)
	}
}

// TestRunTurnModelSwitch: a provider/model switch injected after the first
// tool batch must rebuild the generation model in place — the second request
// goes out under the new combo while the native tool result stays native
// (no flattening) — and leave a visible `<!-- yap:model ... -->` marker.
func TestRunTurnModelSwitch(t *testing.T) {
	var secondModel string
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		calls++
		if calls == 1 {
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hi\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		secondModel, _ = body["model"].(string)
		testutil.SSE(w, `{"choices":[{"delta":{"content":"switched"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"},"other":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	polled := false
	poll := func() Boundary {
		if polled {
			return Boundary{}
		}
		polled = true
		return Boundary{Provider: "other", Model: "m2"}
	}
	err := Run(context.Background(), "mock", "m1", Request{Messages: []Message{{Role: "user", Content: "go"}}}, &out, poll)
	if err != nil {
		t.Fatalf("runTurn: %v", err)
	}
	s := out.String()

	if !strings.Contains(s, `<!-- yap:model {"from":"mock/m1","to":"other/m2"} -->`) {
		t.Fatalf("model marker missing:\n%s", s)
	}
	if secondModel != "m2" {
		t.Fatalf("second request model = %q, want m2", secondModel)
	}
	if !strings.Contains(s, "switched") {
		t.Fatalf("final answer missing:\n%s", s)
	}
}

// TestRunTurnCancelKeepsQueuedSteer: Ctrl-C during a tool call means stop
// now. The turn must not reach the next model boundary and inject a queued
// steer — that would consume the frontend's draft and bury the instruction
// in a cancelled turn. Cancelling wins; the steer stays undelivered so the
// frontend keeps it as a draft.
func TestRunTurnCancelKeepsQueuedSteer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// The pages handler runs inside the fetch tool call, so cancelling there
	// is a deterministic "cancel mid tool call" (no timing).
	pages := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cancel()
		fmt.Fprint(w, "page")
	}))
	defer pages.Close()
	toolArgs, _ := json.Marshal(map[string]any{"url": pages.URL})
	fetchCall := fmt.Sprintf(`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fetch","arguments":%s}}]}}]}`,
		strconv.Quote(string(toolArgs)))
	calls := 0
	chat := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			testutil.SSE(w, fetchCall, `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`)
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer chat.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+chat.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	polled := false
	poll := func() Boundary {
		polled = true
		return Boundary{Steer: "keep me"}
	}
	err := Run(ctx, "mock", "m1", Request{Messages: []Message{{Role: "user", Content: "go"}}}, &out, poll)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if polled {
		t.Error("cancelled turn polled for injections and ate the queued steer")
	}
	if s := out.String(); strings.Contains(s, "# @user\nkeep me") {
		t.Fatalf("cancelled turn injected the queued steer:\n%s", s)
	}
}
