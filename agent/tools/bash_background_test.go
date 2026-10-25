package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/wire"
)

func TestBackgroundBashAcrossTurns(t *testing.T) {
	defer closeBackgroundBash()
	result, _, err := run(t, "bash", `{"command":"sleep 0.2; echo result; exit 7","background":true}`)
	if err != nil || !strings.Contains(result, "Started bash-") {
		t.Fatalf("start: %q %v", result, err)
	}
	id := strings.TrimSuffix(strings.Fields(result)[1], ".")
	ctx, cancel := context.WithCancel(context.Background())
	wire.SetTurnContext(ctx)
	cancel() // a turn ending must not kill the background job
	wire.SetTurnContext(context.Background())
	args, _ := json.Marshal(bashOutputArgs{ID: id, Wait: true})
	out, _, err := run(t, "bash_output", string(args))
	if err != nil || !strings.Contains(out, "result") || !strings.Contains(out, "exit status 7") {
		t.Fatalf("output: %q %v", out, err)
	}
}

func TestBackgroundBashTimeout(t *testing.T) {
	defer closeBackgroundBash()
	result, _, err := run(t, "bash", `{"command":"sleep 60","background":true,"timeout":1}`)
	if err != nil {
		t.Fatal(err)
	}
	id := strings.TrimSuffix(strings.Fields(result)[1], ".")
	args, _ := json.Marshal(bashOutputArgs{ID: id, Wait: true})
	start := time.Now()
	out, _, err := run(t, "bash_output", string(args))
	if err != nil || !strings.Contains(out, "timed out") || time.Since(start) > 5*time.Second {
		t.Fatalf("output: %q %v", out, err)
	}
}

func TestBackgroundBashOutputIsTailed(t *testing.T) {
	defer closeBackgroundBash()
	result, _, err := run(t, "bash", `{"command":"seq 1 5000","background":true}`)
	if err != nil {
		t.Fatal(err)
	}
	id := strings.TrimSuffix(strings.Fields(result)[1], ".")
	args, _ := json.Marshal(bashOutputArgs{ID: id, Wait: true})
	out, _, err := run(t, "bash_output", string(args))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "truncated") || !strings.HasSuffix(out, "5000\n") && !strings.HasSuffix(out, "5000") {
		t.Fatalf("output: %q", out)
	}
	if len(out) > bgOutputMaxBytes+512 {
		t.Fatalf("output is %d bytes, want <= %d", len(out), bgOutputMaxBytes+512)
	}
}
