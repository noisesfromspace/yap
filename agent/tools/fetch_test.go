package tools

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFetchExtractsMarkdown(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, `<!doctype html><html><head><title>Test Post</title></head><body>
<nav><a href="/">Home</a><a href="/about">About</a></nav>
<article>
<h1>Test Post</h1>
<p>This is the first paragraph of the article body with enough words to score well.</p>
<p>This is the second paragraph with a <a href="/link">link</a> and <strong>bold</strong> text.</p>
<pre><code>fmt.Println("hi")</code></pre>
</article>
<aside>Sidebar noise that should be stripped</aside>
</body></html>`)
	}))
	defer srv.Close()

	r, _, err := run(t, "fetch", `{"url":"`+srv.URL+`/post"}`)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	for _, want := range []string{"# Test Post", "first paragraph", "second paragraph", "fmt.Println"} {
		if !strings.Contains(r, want) {
			t.Fatalf("missing %q in %q", want, r)
		}
	}
	for _, dont := range []string{"Sidebar noise", "<nav>", "<html>"} {
		if strings.Contains(r, dont) {
			t.Fatalf("unexpected %q in %q", dont, r)
		}
	}
}

func TestFetchNonHTML(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"a":1}`)
	}))
	defer srv.Close()

	r, _, err := run(t, "fetch", `{"url":"`+srv.URL+`/data"}`)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if r != `{"a":1}` {
		t.Fatalf("non-HTML body changed: %q", r)
	}
}

func TestFetchSchemeCheck(t *testing.T) {
	if _, _, err := run(t, "fetch", `{"url":"file:///etc/passwd"}`); err == nil || !strings.Contains(err.Error(), "http(s)") {
		t.Fatalf("scheme check: %v", err)
	}
}

func TestFetchRejectsPrivateIP(t *testing.T) {
	_, _, err := run(t, "fetch", `{"url":"http://169.254.169.254/latest/meta-data/"}`)
	if err == nil || !strings.Contains(err.Error(), "private/link-local") {
		t.Fatalf("fetch private IP: %v", err)
	}
}
