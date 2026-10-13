package tools

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/mxschmitt/playwright-go"

	"boers.email/yap/agent/utils"
)

// The playwright tool drives a real Chromium via playwright-go. It is the
// "browser agent" counterpart to fetch/curl: where those pull content, this
// one acts on it. The model works from Playwright's accessibility snapshot —
// every element carries a stable ref like [ref=e5] (generated with the "ai"
// snapshot mode), and the model clicks/fills by ref. No vision model and no
// DOM dumps; this is the same ref-based loop Playwright MCP/CLI and
// browser-use share.
//
// The browser lives in the serve process (like the SSH ControlMaster) and is
// backed by a persistent profile, so cookies/localStorage survive across
// calls and across backend restarts. Headed mode + handover give the paired
// human-takeover workflow: the human solves logins/Cloudflare/captcha in the
// live window and the model resumes with `snapshot`.

const pwMaxBytes = 50 * 1024

type playwrightArgs struct {
	Command  string `json:"command" jsonschema:"description=playwright command (see tool description for the full list)"`
	Session  string `json:"session,omitempty" jsonschema:"description=persistent browser profile name (default yap)"`
	Headed   bool   `json:"headed,omitempty" jsonschema:"description=open a visible browser window instead of headless"`
	Handover bool   `json:"handover,omitempty" jsonschema:"description=hand the browser window to the human (forces headed) and pause; resume later with command snapshot"`
}

func init() {
	Register("playwright",
		"Drive a real Chromium browser via Playwright and act on the page through accessibility refs "+
			"(no vision model needed). The browser persists across calls and keeps login state in a per-session profile. "+
			"Commands: goto <url> | snapshot [ref] | text | click <ref> | dblclick <ref> | fill <ref> <text> | "+
			"type <text> | press <key> | check <ref> | uncheck <ref> | select <ref> <value> | hover <ref> | "+
			"url | title | go-back | go-forward | reload | eval <js> | close. "+
			"After navigation and interactions the tool returns the page snapshot with [ref=..] handles; act on them by ref. "+
			"To hand control to the human (logins, Cloudflare/Turnstile, captcha), set handover=true; the window opens for manual use, then resume with command snapshot.",
		func(a *playwrightArgs) (string, string, error) { return runPW(a) }, ClosePlaywright)
	// A browser can act (and exfiltrate) on the user's behalf; gate it.
	Gate("playwright", utils.TierAskJev, nil)
}

type pwState struct {
	mu      sync.Mutex
	pw      *playwright.Playwright
	context playwright.BrowserContext
	page    playwright.Page
	session string
	headed  bool
}

var browser = &pwState{}

// ClosePlaywright tears the browser and driver down; called on backend exit.
func ClosePlaywright() { browser.reset() }

func runPW(a *playwrightArgs) (string, string, error) {
	cmd, args := splitPW(a.Command)
	handover := a.Handover || cmd == "handover"
	if cmd == "" && !handover {
		return "", "", fmt.Errorf("empty command")
	}
	headed := a.Headed || handover
	session := a.Session
	if session == "" {
		session = "yap"
	}
	if err := browser.ensure(session, headed); err != nil {
		return "", "", err
	}

	browser.mu.Lock()
	page := browser.page
	browser.mu.Unlock()

	if handover {
		return handoverMessage(page), "", nil
	}

	switch cmd {
	case "goto", "open":
		if len(args) == 0 {
			return "", "", fmt.Errorf("%s requires a URL", cmd)
		}
		return browser.navigate(page, args[0])
	case "snapshot":
		s, err := browser.snapshot(page, args)
		if err != nil {
			return "", "", err
		}
		return withChallenge(s), "", nil
	case "text":
		s, err := page.Locator("body").InnerText()
		if err != nil {
			return "", "", err
		}
		return withChallenge(capPW(s)), "", nil
	case "click", "dblclick", "check", "uncheck", "hover", "fill", "select":
		return browser.act(page, cmd, args)
	case "type":
		if len(args) == 0 {
			return "", "", fmt.Errorf("type requires text")
		}
		if err := page.Keyboard().Type(strings.Join(args, " ")); err != nil {
			return "", "", err
		}
		return withChallenge(browser.afterAction(page)), "", nil
	case "press":
		if len(args) == 0 {
			return "", "", fmt.Errorf("press requires a key")
		}
		if err := page.Keyboard().Press(args[0]); err != nil {
			return "", "", err
		}
		return withChallenge(browser.afterAction(page)), "", nil
	case "url":
		return page.URL(), "", nil
	case "title":
		t, err := page.Title()
		if err != nil {
			return "", "", err
		}
		return t, "", nil
	case "go-back":
		if _, err := page.GoBack(); err != nil {
			return "", "", err
		}
		return withChallenge(browser.afterAction(page)), "", nil
	case "go-forward":
		if _, err := page.GoForward(); err != nil {
			return "", "", err
		}
		return withChallenge(browser.afterAction(page)), "", nil
	case "reload":
		if _, err := page.Reload(); err != nil {
			return "", "", err
		}
		return withChallenge(browser.afterAction(page)), "", nil
	case "eval":
		expr := strings.TrimSpace(strings.TrimPrefix(a.Command, "eval"))
		if expr == "" {
			return "", "", fmt.Errorf("eval requires a JavaScript expression")
		}
		res, err := page.Evaluate(expr)
		if err != nil {
			return "", "", err
		}
		return capPW(formatEval(res)), "", nil
	case "close":
		browser.reset()
		return "browser closed", "", nil
	default:
		return "", "", fmt.Errorf("unknown playwright command %q", cmd)
	}
}

// ensure starts the driver if needed and (re)launches the persistent context
// for session/headed. Switching a session to headed (handover) restores the
// current URL so the human sees the page the model was stuck on.
func (b *pwState) ensure(session string, headed bool) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.pw == nil {
		p, err := startPW()
		if err != nil {
			return err
		}
		b.pw = p
	}
	if b.context != nil && b.session == session && b.headed == headed {
		return nil
	}

	restoreURL := ""
	if b.context != nil {
		if b.session == session && headed && !b.headed {
			restoreURL = b.page.URL()
		}
		_ = b.context.Close()
		b.context, b.page = nil, nil
	}

	ctx, page, err := launchPW(b.pw, session, headed)
	if err != nil {
		return err
	}
	b.context, b.page, b.session, b.headed = ctx, page, session, headed
	if restoreURL != "" {
		_, _ = page.Goto(restoreURL)
	}
	return nil
}

func (b *pwState) reset() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.context != nil {
		_ = b.context.Close()
	}
	if b.pw != nil {
		_ = b.pw.Stop()
	}
	b.pw, b.context, b.page, b.session, b.headed = nil, nil, nil, "", false
}

func (b *pwState) navigate(page playwright.Page, rawURL string) (string, string, error) {
	if !strings.HasPrefix(rawURL, "http://") && !strings.HasPrefix(rawURL, "https://") {
		return "", "", fmt.Errorf("only http(s) URLs supported")
	}
	resp, err := page.Goto(rawURL)
	if err != nil {
		return withChallenge(pageStatus(page)), "", fmt.Errorf("navigation: %w", err)
	}
	status := ""
	if resp != nil && resp.Status() >= 400 {
		status = fmt.Sprintf("http status: %d\n", resp.Status())
	}
	return withChallenge(status + b.afterAction(page)), "", nil
}

func (b *pwState) act(page playwright.Page, cmd string, args []string) (string, string, error) {
	if len(args) == 0 {
		return "", "", fmt.Errorf("%s requires a ref", cmd)
	}
	loc := page.Locator("aria-ref=" + args[0])
	var err error
	switch cmd {
	case "click":
		err = loc.Click()
	case "dblclick":
		err = loc.Dblclick()
	case "check":
		err = loc.Check()
	case "uncheck":
		err = loc.Uncheck()
	case "hover":
		err = loc.Hover()
	case "fill":
		if len(args) < 2 {
			return "", "", fmt.Errorf("fill requires a ref and text")
		}
		err = loc.Fill(strings.Join(args[1:], " "))
	case "select":
		if len(args) < 2 {
			return "", "", fmt.Errorf("select requires a ref and a value")
		}
		_, err = loc.SelectOption(playwright.SelectOptionValues{ValuesOrLabels: playwright.StringSlice(strings.Join(args[1:], " "))})
	}
	if err != nil {
		return "", "", err
	}
	return withChallenge(b.afterAction(page)), "", nil
}

func (b *pwState) snapshot(page playwright.Page, args []string) (string, error) {
	mode := playwright.AriaSnapshotModeAi
	if len(args) > 0 {
		s, err := page.Locator("aria-ref=" + args[0]).AriaSnapshot(playwright.LocatorAriaSnapshotOptions{Mode: mode})
		return capPW(s), err
	}
	s, err := page.AriaSnapshot(playwright.PageAriaSnapshotOptions{Mode: mode})
	return capPW(s), err
}

// afterAction returns title/url plus a fresh snapshot, so refs stay current.
func (b *pwState) afterAction(page playwright.Page) string {
	// Snapshot first: AriaSnapshot auto-waits for the post-action state, so the
	// status (URL/title) read afterwards reflects the settled page, not the
	// pre-action one.
	var sb strings.Builder
	if s, err := b.snapshot(page, nil); err == nil {
		sb.WriteString(s)
	} else {
		fmt.Fprintf(&sb, "[snapshot failed: %v]", err)
	}
	sb.WriteString("\n\n" + pageStatus(page))
	return sb.String()
}

func pageStatus(page playwright.Page) string {
	title, _ := page.Title()
	return fmt.Sprintf("url: %s\ntitle: %s", page.URL(), title)
}

func handoverMessage(page playwright.Page) string {
	return fmt.Sprintf("Browser handed to the human. The visible window (currently at %s) is now under manual control. "+
		"Stop issuing browser commands. When the human says they are done (e.g. solved a login or a Cloudflare/Turnstile challenge), "+
		"call playwright with command \"snapshot\" to re-read the page and confirm the new state.", page.URL())
}

// ─── driver / browser launch ────────────────────────────────────────────────

func startPW() (*playwright.Playwright, error) {
	ensureNodePath()
	p, err := playwright.Run()
	if err == nil {
		return p, nil
	}
	// Driver missing or stale: install the driver JS only (the browser binary
	// comes from the OS, so we never download Playwright's bundled browsers).
	if ierr := playwright.Install(&playwright.RunOptions{SkipInstallBrowsers: true}); ierr != nil {
		return nil, fmt.Errorf("%v (driver install failed: %v)", err, ierr)
	}
	return playwright.Run()
}

func launchPW(p *playwright.Playwright, session string, headed bool) (playwright.BrowserContext, playwright.Page, error) {
	headless := !headed
	ctx, err := p.Chromium.LaunchPersistentContext(profileDir(session), playwright.BrowserTypeLaunchPersistentContextOptions{
		Headless:       &headless,
		ExecutablePath: resolveChromium(),
	})
	if err != nil {
		return nil, nil, err
	}
	var page playwright.Page
	if pages := ctx.Pages(); len(pages) > 0 {
		page = pages[0]
	} else if page, err = ctx.NewPage(); err != nil {
		_ = ctx.Close()
		return nil, nil, err
	}
	return ctx, page, nil
}

// ensureNodePath points playwright-go at a working Node instead of the
// prebuilt binary it would otherwise download (which does not run on NixOS).
func ensureNodePath() {
	if os.Getenv("PLAYWRIGHT_NODEJS_PATH") != "" {
		return
	}
	if node, err := exec.LookPath("node"); err == nil {
		_ = os.Setenv("PLAYWRIGHT_NODEJS_PATH", node)
	}
}

// resolveChromium prefers an explicit env override, then a Chromium/Chrome
// found on PATH (nixpkgs chromium on NixOS). Nil lets Playwright use its own
// bundled browser on non-NixOS systems.
func resolveChromium() *string {
	if p := os.Getenv("PLAYWRIGHT_CHROMIUM_PATH"); p != "" {
		return &p
	}
	for _, name := range []string{"chromium", "chromium-browser", "google-chrome", "google-chrome-stable"} {
		if p, err := exec.LookPath(name); err == nil {
			return &p
		}
	}
	return nil
}

func profileDir(session string) string {
	base, err := os.UserCacheDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, "yap-playwright", session)
}

// ─── helpers ────────────────────────────────────────────────────────────────

var challengeIndicators = []string{
	"checking your browser",
	"verify you are human",
	"just a moment",
	"attention required",
	"cf-challenge",
	"challenge-platform",
	"turnstile",
	"captcha",
	"enable javascript and cookies",
	"enable cookies and javascript",
	"access denied",
}

// detectChallenge reports bot-challenge indicators; empty when none match.
func detectChallenge(s string) string {
	low := strings.ToLower(s)
	var hits []string
	for _, ind := range challengeIndicators {
		if strings.Contains(low, ind) {
			hits = append(hits, ind)
		}
	}
	if len(hits) == 0 {
		return ""
	}
	return fmt.Sprintf("[possible bot challenge detected: %s. Stop and hand over to the human with handover=true; do NOT retry or attempt to bypass]",
		strings.Join(hits, ", "))
}

func withChallenge(s string) string {
	if w := detectChallenge(s); w != "" {
		return w + "\n\n" + s
	}
	return s
}

func capPW(s string) string {
	if len(s) > pwMaxBytes {
		return s[:pwMaxBytes] + "\n[truncated at 50KB]"
	}
	return s
}

func formatEval(v any) string {
	if b, err := json.Marshal(v); err == nil {
		return string(b)
	}
	return fmt.Sprintf("%v", v)
}

// splitPW returns (command, args) with quote-aware word splitting, so
// `fill e7 "hello world"` keeps the text as one argument.
func splitPW(s string) (string, []string) {
	fields := shellWords(s)
	if len(fields) == 0 {
		return "", nil
	}
	return fields[0], fields[1:]
}

func shellWords(s string) []string {
	var out []string
	var cur strings.Builder
	var quote byte
	in := false
	flush := func() {
		if in {
			out = append(out, cur.String())
			cur.Reset()
			in = false
		}
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			} else {
				cur.WriteByte(c)
			}
		case c == '"' || c == '\'':
			quote = c
			in = true
		case c == ' ' || c == '\t' || c == '\n':
			flush()
		default:
			cur.WriteByte(c)
			in = true
		}
	}
	flush()
	return out
}
