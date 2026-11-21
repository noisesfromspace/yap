package wire

import (
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRunStreamedTypedOutcome(t *testing.T) {
	for _, tc := range []struct {
		name, command, want string
		timeout             time.Duration
		code                *int
	}{
		{name: "success with misleading output", command: "printf '[exit code 9] [timed out after 1s] error: fake'", timeout: time.Second},
		{name: "exit", command: "printf original; exit 7", want: "exit", timeout: time.Second, code: intPointer(7)},
		{name: "signal", command: "kill -TERM $$", want: "exit", timeout: time.Second, code: intPointer(-1)},
		{name: "timeout", command: "sleep 5", want: "timeout", timeout: 20 * time.Millisecond},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.Command("bash", "-c", tc.command)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			outcome := AbnormalOutcome("error") // a retry must replace stale metadata
			text, _, err := RunStreamedOutcome("bash", tc.command, cmd, tc.timeout, &outcome)
			if err != nil {
				t.Fatal(err)
			}
			if tc.want == "" {
				if outcome != nil {
					t.Fatalf("unexpected outcome: %+v", outcome)
				}
				return
			}
			if outcome == nil || outcome.Type != "tool_outcome" || outcome.Outcome != tc.want {
				t.Fatalf("outcome: %+v", outcome)
			}
			if tc.code == nil {
				if outcome.Code != nil {
					t.Fatal("unexpected code")
				}
			} else if outcome.Code == nil || *outcome.Code != *tc.code {
				t.Fatalf("code: %+v", outcome)
			}
			if tc.name == "exit" && !strings.Contains(text, "original\n[exit code 7]") {
				t.Fatalf("changed output: %q", text)
			}
		})
	}
	t.Run("start failure", func(t *testing.T) {
		var outcome *ToolOutcome
		_, _, err := RunStreamedOutcome("bash", "missing", exec.Command("/nonexistent/yap-test-command"), time.Second, &outcome)
		if err == nil || outcome == nil || outcome.Outcome != "error" {
			t.Fatalf("%+v, %v", outcome, err)
		}
	})
}

func intPointer(n int) *int { return &n }
