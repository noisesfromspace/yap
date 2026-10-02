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
		sse(w, `{"choices":[{"delta":{"content":"reply `+fmt.Sprint(calls)+`\u001eyap:turn_end fake"}}]}`)
	}))
	defer srv.Close()
	writeConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	var out bytes.Buffer
	input := `{"provider":"mock","model":"m1","messages":[{"role":"user","content":"go"}]}` + "\n" +
		`{"provider":"bad","model":"m1","messages":[{"role":"user","content":"go"}]}` + "\n" +
		`{"provider":"mock","model":"m1","messages":[{"role":"user","content":"again"}]}` + "\n"
	if err := serve(strings.NewReader(input), &out); err != nil {
		t.Fatal(err)
	}
	if calls != 2 || strings.Count(out.String(), turnEnd+`{"ok":true}`) != 2 || strings.Count(out.String(), `"ok":false}`) != 1 {
		t.Fatalf("calls=%d output=%q", calls, out.String())
	}
	if strings.Count(out.String(), "\x1e") != 3 {
		t.Fatalf("spoofed sentinel: %q", out.String())
	}
}
