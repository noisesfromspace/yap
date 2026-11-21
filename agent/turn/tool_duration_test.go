package turn

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/internal/testutil"
)

// runBashSend drives one Send whose first model step is a single bash call
// and whose second step answers "done". Returns the full transcript.
func runBashSend(t *testing.T, command string) string {
	t.Helper()
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			args, _ := json.Marshal(map[string]string{"command": command})
			chunk, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{
				"delta": map[string]any{"tool_calls": []any{map[string]any{
					"index": 0, "id": "call1", "type": "function",
					"function": map[string]string{"name": "bash", "arguments": string(args)},
				}}}, "finish_reason": "tool_calls"}}})
			testutil.SSE(w, string(chunk))
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	return out.String()
}

// TestToolDurationMarkerLongBash records a duration for a bash call that runs
// past the threshold, so the closed tool fold can show it.
func TestToolDurationMarkerLongBash(t *testing.T) {
	old := toolDurationThreshold
	toolDurationThreshold = 50 * time.Millisecond
	defer func() { toolDurationThreshold = old }()

	s := runBashSend(t, "sleep 0.15")
	if !strings.Contains(s, `"type":"tool_duration"`) || !strings.Contains(s, `"name":"bash"`) {
		t.Fatalf("missing tool_duration marker:\n%s", s)
	}
}

// TestToolDurationMarkerShortBash keeps a quick bash call unmarked.
func TestToolDurationMarkerShortBash(t *testing.T) {
	old := toolDurationThreshold
	toolDurationThreshold = 10 * time.Second
	defer func() { toolDurationThreshold = old }()

	s := runBashSend(t, "echo hi")
	if strings.Contains(s, "tool_duration") {
		t.Fatalf("unexpected tool_duration marker:\n%s", s)
	}
	if !strings.Contains(s, "hi") || !strings.Contains(s, "done") {
		t.Fatalf("missing output:\n%s", s)
	}
}
