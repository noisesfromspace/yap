package tools

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHeadBufferKeepsRuneBoundary(t *testing.T) {
	var b headBuffer
	body := strings.Repeat("x", readMaxBytes-1) + "日" + "tail"
	if _, err := b.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	got := b.String()
	if !b.Truncated() || got != strings.Repeat("x", readMaxBytes-1) {
		t.Fatalf("curl body split a rune at the byte cap: %q", got[len(got)-min(5, len(got)):])
	}
}

func TestCurl(t *testing.T) {
	var gotMethod, gotPath, gotBody, gotUA, gotAccept string
	var gotHeaders http.Header

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotUA = r.Header.Get("User-Agent")
		gotAccept = r.Header.Get("Accept")
		gotHeaders = r.Header
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		io.WriteString(w, "<html><body>hello</body></html>")
	}))
	defer srv.Close()

	// GET: browser UA and Accept by default, status line appended.
	r, _, err := run(t, "curl", `{"url":"`+srv.URL+`/a"}`)
	if err != nil {
		t.Fatalf("curl: %v", err)
	}
	if gotMethod != "GET" || gotPath != "/a" || gotBody != "" {
		t.Fatalf("request: %s %s body=%q", gotMethod, gotPath, gotBody)
	}
	if gotUA != curlDefaultUA {
		t.Fatalf("default UA: %q", gotUA)
	}
	if !strings.Contains(gotAccept, "text/html") {
		t.Fatalf("default Accept: %q", gotAccept)
	}
	for _, want := range []string{"<html><body>hello</body></html>", "[yap curl: HTTP 200"} {
		if !strings.Contains(r, want) {
			t.Fatalf("missing %q in %q", want, r)
		}
	}

	// method + headers + data: explicit values win over defaults.
	_, _, err = run(t, "curl", `{"url":"`+srv.URL+`/b","method":"POST","headers":{"Accept":"application/json","X-Test":"yes"},"userAgent":"custom/1.0","data":"{\"n\":1}"}`)
	if err != nil {
		t.Fatalf("curl POST: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/b" || gotBody != `{"n":1}` {
		t.Fatalf("POST request: %s %s body=%q", gotMethod, gotPath, gotBody)
	}
	if gotUA != "custom/1.0" {
		t.Fatalf("custom UA: %q", gotUA)
	}
	if gotAccept != "application/json" {
		t.Fatalf("custom Accept: %q", gotAccept)
	}
	if gotHeaders.Get("X-Test") != "yes" {
		t.Fatalf("custom header: %q", gotHeaders.Get("X-Test"))
	}

	// data with a leading @ must stay literal, not be read as a file.
	run(t, "curl", `{"url":"`+srv.URL+`/c","data":"@not-a-file"}`)
	if gotMethod != "POST" || gotBody != "@not-a-file" {
		t.Fatalf("@-in-data: %s %q", gotMethod, gotBody)
	}

	// non-http(s) URLs are rejected before curl runs.
	if _, _, err := run(t, "curl", `{"url":"file:///etc/passwd"}`); err == nil || !strings.Contains(err.Error(), "http(s)") {
		t.Fatalf("scheme check: %v", err)
	}
}

func TestCurlSchemaDescription(t *testing.T) {
	// jsonschema tags are comma-separated key=value pairs: a comma inside a
	// description value silently truncates it. Guard the flags description.
	tl, _ := Get("curl")
	if !strings.Contains(string(tl.Schema), "values with spaces") {
		t.Fatalf("flags description truncated: %s", tl.Schema)
	}
}

func TestCurlRedirectsAndFlags(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/start", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/end", http.StatusFound)
	})
	var endHits int
	mux.HandleFunc("/end", func(w http.ResponseWriter, r *http.Request) {
		endHits++
		fmt.Fprintf(w, "end:%s", r.Header.Get("X-Extra"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	// redirects are followed by default.
	r, _, err := run(t, "curl", `{"url":"`+srv.URL+`/start"}`)
	if err != nil || endHits != 1 || !strings.Contains(r, "end:") {
		t.Fatalf("follow redirect: %q %v (hits=%d)", r, err, endHits)
	}

	// followRedirects=false reports the 302 and does not hit /end.
	r, _, err = run(t, "curl", `{"url":"`+srv.URL+`/start","followRedirects":false}`)
	if err != nil || endHits != 1 || !strings.Contains(r, "HTTP 302") {
		t.Fatalf("no-follow: %q %v (hits=%d)", r, err, endHits)
	}

	// extra flags are passed through verbatim (values with spaces go in
	// the headers field instead — Flags is split on spaces).
	r, _, err = run(t, "curl", `{"url":"`+srv.URL+`/end","flags":"-H X-Extra:from-flags"}`)
	if err != nil || !strings.Contains(r, "end:from-flags") {
		t.Fatalf("flags: %q %v", r, err)
	}

	// a cluster with no denied letter still passes through
	r, _, err = run(t, "curl", `{"url":"`+srv.URL+`/end","flags":"-sS --http1.1"}`)
	if err != nil || !strings.Contains(r, "end:") {
		t.Fatalf("benign flags: %q %v", r, err)
	}

	// malformed flag is a curl error, reported with the exit code, not a panic.
	r, _, err = run(t, "curl", `{"url":"`+srv.URL+`/end","flags":"--definitely-not-a-flag"}`)
	if err != nil || !strings.Contains(r, "[curl exit code") {
		t.Fatalf("bad flag: %q %v", r, err)
	}
}

func TestCurlFlagSplit(t *testing.T) {
	// SSRF / protocol-smuggling flags are hard-refused: they change where
	// curl connects and would bypass the per-hop host check.
	for _, flag := range []string{
		"--unix-socket /var/run/docker.sock",
		"--abstract-unix-socket yap",
		"--location",
		"--location-trusted",
		"-L",
		"-Lk",
		"-sSL", // clustered -L
		"--url http://169.254.169.254/",
		"--next",
		"--proxy http://127.0.0.1:8080",
		"--preproxy http://127.0.0.1:8080",
		"-x http://127.0.0.1:8080",
		"--socks4 localhost",
		"--socks5 localhost",
		"--socks5-hostname localhost",
		"--proto-redir =http,https",
		"--interface eth0",
		"--config /tmp/c",
		"-K /tmp/c",
		"-K/tmp/c",
		"--resolve example.com:80:127.0.0.1",
		"--connect-to example.com:80:127.0.0.1:80",
	} {
		if err := rejectCurlFlags(flag); err == nil || !strings.Contains(err.Error(), "not allowed") {
			t.Fatalf("flag %q should be hard-refused: %v", flag, err)
		}
		if flagsTouchLocalFiles(flag) {
			t.Fatalf("flag %q should not be approval-gated (it is hard-refused)", flag)
		}
	}

	// Local-file flags are approval-gated, not refused: the tool runs, but
	// the guard pauses for a Run/Deny first.
	for _, flag := range []string{
		"-o /tmp/out",
		"-ofile",
		"-O",
		"--output /tmp/out",
		"--remote-name",
		"--remote-name-all",
		"--remote-header-name",
		"--dump-header /tmp/h",
		"--trace-ascii /tmp/t",
		"-so /tmp/out", // clustered -o
		"-So/tmp/out",
		"-H @/etc/hostname",
		"-d @/etc/hostname",
		"--data @/etc/hostname",
		"-d@/etc/hostname",
		"-T /etc/hostname",
		"--upload-file /etc/hostname",
		"-c /tmp/jar",
		"--netrc-file /tmp/n",
		"--write-out @/etc/hostname",
		"--cert /etc/hostname",
		"--key /tmp/k",
		"--cacert /tmp/ca",
		"--capath /tmp/capath",
		"--crlfile /tmp/crl",
		"--pubkey /tmp/pub",
		"--proxy-cert /tmp/c",
		"--proxy-key /tmp/k",
		"--proxy-cacert /tmp/ca",
		"--proxy-capath /tmp/capath",
		"--proxy-crlfile /tmp/crl",
		"--alt-svc /tmp/alt",
		"--etag-save /tmp/etag",
		"--libcurl /tmp/out.c",
		"--hsts /tmp/hsts",
	} {
		if err := rejectCurlFlags(flag); err != nil {
			t.Fatalf("flag %q should not be hard-refused: %v", flag, err)
		}
		if !flagsTouchLocalFiles(flag) {
			t.Fatalf("flag %q should be approval-gated", flag)
		}
	}

	// A benign flag touches neither list.
	if rejectCurlFlags("--http1.1") != nil || flagsTouchLocalFiles("--http1.1") {
		t.Fatalf("benign flag should pass both checks")
	}
}

func TestCurlRedirectToPrivateIP(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/start", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://169.254.169.254/latest/meta-data/", http.StatusFound)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	_, _, err := run(t, "curl", `{"url":"`+srv.URL+`/start"}`)
	if err == nil || !strings.Contains(err.Error(), "private/link-local") {
		t.Fatalf("redirect to metadata IP should be blocked: %v", err)
	}
}
