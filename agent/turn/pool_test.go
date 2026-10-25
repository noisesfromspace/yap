package turn

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"boers.email/yap/agent/internal/testutil"
)

func TestReadOnlyCallsRunTogether(t *testing.T) {
	var arrivals atomic.Int32
	release := make(chan struct{})
	pages := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if arrivals.Add(1) == 2 {
			close(release)
		}
		select {
		case <-release:
			fmt.Fprint(w, "ok")
		case <-time.After(3 * time.Second):
			fmt.Fprint(w, "timed out")
		}
	}))
	defer pages.Close()
	calls := 0
	chat := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			testutil.ToolRound(w, testutil.TaskCall("c1", "fetch", map[string]any{"url": pages.URL + "/one"}), testutil.TaskCall("c2", "fetch", map[string]any{"url": pages.URL + "/two"}))
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"finished"}}]}`)
	}))
	defer chat.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+chat.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"fetch both"}]}`), &out); err != nil {
		t.Fatal(err)
	}
	if arrivals.Load() != 2 || strings.Contains(out.String(), "timed out") {
		t.Fatalf("not concurrent: %s", out.String())
	}
}
