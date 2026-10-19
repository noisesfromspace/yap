package main

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestServeMultipleTurnsAndFailure(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		sse(w, `{"choices":[{"delta":{"content":"reply `+fmt.Sprint(calls)+`"}}]}`)
	}))
	defer srv.Close()
	writeConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	var out bytes.Buffer
	input := `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"go"}]}` + "\n" +
		`{"type":"turn","v":1,"provider":"bad","model":"m1","messages":[{"role":"user","content":"go"}]}` + "\n" +
		`{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"again"}]}` + "\n"
	if err := serve(strings.NewReader(input), &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	if calls != 2 {
		t.Fatalf("calls=%d output=%q", calls, s)
	}
	if strings.Count(s, `"type":"turn_complete"`) != 3 {
		t.Fatalf("expected 3 turn_complete frames: %q", s)
	}
	if strings.Count(s, `"ok":true`) != 2 || strings.Count(s, `"ok":false`) != 1 {
		t.Fatalf("ok/error counts wrong: %q", s)
	}
	// The unknown-provider turn must surface a structured error (-32602
	// invalid params), not a bare string.
	if !strings.Contains(s, `"code":-32602`) || !strings.Contains(s, "unknown provider") {
		t.Fatalf("missing structured error: %q", s)
	}
	// Text arrives in text frames; the failed turn produces none.
	if !strings.Contains(s, "reply 1") || !strings.Contains(s, "reply 2") || strings.Contains(s, "reply 3") {
		t.Fatalf("text frames wrong: %q", s)
	}
}
