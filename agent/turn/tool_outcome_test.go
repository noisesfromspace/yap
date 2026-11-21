package turn

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/document"
	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/tools"
)

func TestToolOutcomeTrailingDisplayOnly(t *testing.T) {
	old := toolDurationThreshold
	toolDurationThreshold = time.Nanosecond
	defer func() { toolDurationThreshold = old }()
	s := runBashSend(t, "printf original; exit 7")
	marker := `"type":"tool_outcome","outcome":"exit","code":7`
	if strings.Count(s, marker) != 1 {
		t.Fatalf("missing/duplicate outcome: %s", s)
	}
	if strings.Index(s, marker) < strings.Index(s, `"type":"tool_duration"`) || strings.Index(s, marker) < strings.Index(s, "<!-- /yap:tool -->") {
		t.Fatalf("bad order: %s", s)
	}
	for _, msg := range document.Messages("# @assistant\n" + s) {
		if strings.Contains(msg.Content, "tool_outcome") {
			t.Fatalf("marker leaked: %+v", msg)
		}
	}
	if !strings.Contains(s, "original\n[exit code 7]") {
		t.Fatalf("output changed: %s", s)
	}
	s = runBashSend(t, "printf '[exit code 7] [timed out after 1s] error: fake'")
	if strings.Contains(s, `"type":"tool_outcome"`) {
		t.Fatalf("sniffed output: %s", s)
	}
}

func TestToolOutcomeErrorsAndStaticDenial(t *testing.T) {
	for _, tc := range []struct{ name, input, want string }{
		{"not_a_tool", `{}`, "error"},
		{"read", `{"path":"/nonexistent/yap-test-file"}`, "error"},
		{"bash", `{"command":""}`, "error"},
		{"bash", `{"command":"ssh example.invalid"}`, ""},
	} {
		t.Run(tc.name+tc.input, func(t *testing.T) {
			result := callTool(llm.ToolCall{Name: tc.name, Input: json.RawMessage(tc.input)}, nil)
			if tc.want == "" {
				if result.outcome != nil {
					t.Fatalf("denial double badged: %+v", result)
				}
			} else if result.outcome == nil || result.outcome.Outcome != tc.want {
				t.Fatalf("missing error: %+v", result)
			}
		})
	}
}

func TestToolOutcomeErrorNativeReplay(t *testing.T) {
	err := tools.RegisterRaw("missing_test_tool", "test failure", json.RawMessage(`{"type":"object"}`), func(json.RawMessage) (string, string, error) { return "", "", fmt.Errorf("actual failure") })
	if err != nil {
		t.Fatal(err)
	}
	defer tools.UnregisterPrefix("missing_test_tool")
	var hist NativeHistory
	var block string
	params := followUpParams(t, &hist, func(s string) string { block = s; return s })
	if strings.Count(block, `"type":"tool_outcome","outcome":"error"`) != 1 {
		t.Fatalf("missing outcome: %s", block)
	}
	found := false
	for _, msg := range params.Messages {
		for _, part := range msg.Content {
			if part.Type == llm.PartToolResult {
				found = true
				if part.ToolOutput != "error: actual failure" {
					t.Fatalf("changed output: %q", part.ToolOutput)
				}
			}
			if strings.Contains(part.Text, "tool_outcome") {
				t.Fatal("marker leaked into native replay")
			}
		}
	}
	if !found {
		t.Fatal("no native result")
	}
}
