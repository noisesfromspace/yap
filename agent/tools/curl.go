package tools

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// curl shell-outs to the system curl binary — the most versatile way to
// fetch a URL without pulling curl's protocol matrix into Go. Its focus is
// websearch follow-ups: sites that return 403s to Go's default client
// (fetch) or need a browser-looking request. curl does not run JavaScript,
// so JS-heavy pages still need websearch's contentMode=text (Exa renders).
const (
	curlDefaultTimeout = 30 * time.Second
	// A current browser UA; the main defense against agent-blocking sites.
	curlDefaultUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
	// curl's default Accept is */*, which bot checks flag; a browser-like
	// Accept is only added when the caller did not supply its own.
	curlDefaultAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
)

type curlArgs struct {
	URL             string            `json:"url" jsonschema:"description=http(s) URL to request"`
	Method          string            `json:"method,omitempty" jsonschema:"description=HTTP method (default GET; data forces POST unless method is set)"`
	Headers         map[string]string `json:"headers,omitempty" jsonschema:"description=extra request headers (name: value)"`
	UserAgent       string            `json:"userAgent,omitempty" jsonschema:"description=User-Agent header (default: a current Chrome UA)"`
	Data            string            `json:"data,omitempty" jsonschema:"description=exact request body (e.g. JSON for POST/PUT)"`
	FollowRedirects *bool             `json:"followRedirects,omitempty" jsonschema:"description=follow HTTP redirects (default true)"`
	Timeout         int               `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 30)"`
	Flags           string            `json:"flags,omitempty" jsonschema:"description=space-separated extra curl flags (e.g. --http1.1); values with spaces (like header values) belong in headers"`
	Safety          bool              `json:"safety,omitempty" jsonschema:"description=when true, run a jev prompt-injection check on the result before returning it; flagged content is annotated with a warning (costs one extra decision-model call, so use only for untrusted content)"`
}

func init() {
	Register("curl",
		"Fetch a URL with curl. Returns the response body plus a status line. "+
			"Versatile: set method, headers, user-agent, request body, redirects, timeout, or pass extra curl flags. "+
			"Sends a browser User-Agent by default to get past agent blocks. Returns the raw response body "+
			"(curl does not execute JavaScript) — for JS-heavy pages prefer websearch with contentMode=text.",
		func(a *curlArgs) (string, string, error) { return runCurl(a) })
}

func runCurl(a *curlArgs) (string, string, error) {
	if !strings.HasPrefix(a.URL, "http://") && !strings.HasPrefix(a.URL, "https://") {
		return "", "", fmt.Errorf("only http(s) URLs supported")
	}

	u, perr := url.Parse(a.URL)
	if perr != nil {
		return "", "", fmt.Errorf("invalid URL: %w", perr)
	}
	if err := checkURLHost(u); err != nil {
		return "", "", err
	}

	// -sS: silent, but show errors. --compressed: send Accept-Encoding and
	// auto-decompress. -w prints the status line to STDERR (via %{stderr})
	// so a 50KB-truncated body cannot swallow it.
	args := []string{"-sS", "--compressed", "-w", "%{stderr}[yap curl: HTTP %{http_code} | %{size_download} bytes | %{time_total}s]\n"}
	if a.FollowRedirects == nil || *a.FollowRedirects {
		args = append(args, "-L")
	}
	if a.Method != "" {
		args = append(args, "-X", a.Method)
	}

	ua := a.UserAgent
	if ua == "" {
		ua = curlDefaultUA
	}
	args = append(args, "-A", ua)

	// Sort header keys so identical requests produce identical audit logs.
	keys := make([]string, 0, len(a.Headers))
	for k := range a.Headers {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	hasAccept := false
	for _, k := range keys {
		if strings.EqualFold(k, "Accept") {
			hasAccept = true
		}
		args = append(args, "-H", k+": "+a.Headers[k])
	}
	if !hasAccept {
		args = append(args, "-H", "Accept: "+curlDefaultAccept)
	}

	timeout := curlDefaultTimeout
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}
	args = append(args, "--max-time", fmt.Sprintf("%.0f", timeout.Seconds()))
	if a.Flags != "" {
		args = append(args, strings.Fields(a.Flags)...)
	}
	if a.Data != "" {
		// @- reads the body from stdin: exact bytes, and a leading @ in the
		// data cannot be mistaken for a filename.
		args = append(args, "--data-binary", "@-")
	}
	args = append(args, a.URL)

	// curl's --max-time bounds the transfer; the Go context is only a
	// backstop (5s later) so curl's own "operation timed out" message wins.
	ctx, cancel := context.WithTimeout(context.Background(), timeout+5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "curl", args...)
	if a.Data != "" {
		cmd.Stdin = strings.NewReader(a.Data)
	}

	var body headBuffer
	var stderr bytes.Buffer
	cmd.Stdout = &body
	cmd.Stderr = &stderr
	err := cmd.Run()

	text := body.String()
	if body.Truncated() {
		text += "\n[truncated at 50KB]"
	}
	if s := strings.TrimSpace(stderr.String()); s != "" {
		text += "\n" + s
	}
	if err != nil {
		if ctx.Err() != nil {
			return "", "", fmt.Errorf("curl killed: %v", ctx.Err())
		}
		if ee, ok := err.(*exec.ExitError); ok {
			text += fmt.Sprintf("\n[curl exit code %d]", ee.ExitCode())
		} else {
			return "", "", fmt.Errorf("curl: %w", err)
		}
	}
	return safetyGuarded(a.Safety, text), "", nil
}

// headBuffer keeps the first readMaxBytes (50KB) of the response body,
// discarding the rest without buffering it in memory.
type headBuffer struct {
	buf   []byte
	total int64
}

func (b *headBuffer) Write(p []byte) (int, error) {
	b.total += int64(len(p))
	if room := readMaxBytes - len(b.buf); room > 0 {
		n := len(p)
		if n > room {
			n = room
		}
		b.buf = append(b.buf, p[:n]...)
	}
	return len(p), nil
}

func (b *headBuffer) String() string { return string(b.buf) }

func (b *headBuffer) Truncated() bool { return b.total > int64(len(b.buf)) }
