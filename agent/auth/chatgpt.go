// ChatGPT plan login ("Sign in with ChatGPT", or SIWC): a ChatGPT Plus/Pro
// plan pays for requests Yap sends to the public Responses API, so no
// pay-per-token key is involved. The flow is the documented open-source one:
// PKCE + a loopback callback, dynamic client registration on first sign-in (no
// client secret, no partner approval), and a rotating refresh token kept under
// the user's config dir.
//
// See https://developers.openai.com/siwc/token-sharing-open-source.
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	authorizeURL    = "https://auth.openai.com/api/accounts/authorize"
	tokenURL        = "https://auth.openai.com/api/accounts/oauth/token"
	resource        = "https://api.openai.com/v1"
	callbackPath    = "/auth/callback"
	callbackPort    = "1455"
	appName         = "yap"
	dynamicClientID = "dynamic_agent_client"
	loginTimeout    = 5 * time.Minute
	// scope asks for identity, an offline (refresh) grant, and ChatGPT plan
	// usage on the public Responses API.
	scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
	// refreshMargin renews a token this long before it expires, so a turn that
	// starts just under the wire does not die mid-request.
	refreshMargin = 5 * time.Minute
)

// Creds is the stored credential record for one ChatGPT account registration.
type Creds struct {
	Email        string    `json:"email,omitempty"`
	Subject      string    `json:"subject,omitempty"`
	ClientID     string    `json:"client_id"`
	HostID       string    `json:"ext_agent_host_id"`
	IDToken      string    `json:"id_token,omitempty"`
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	Expiry       time.Time `json:"expiry"`
	Scopes       []string  `json:"scopes,omitempty"`
}

// Path is the credential file: $XDG_CONFIG_HOME/yap/chatgpt.json, or
// ~/.config/yap/chatgpt.json.
func Path() string {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "yap", "chatgpt.json")
}

// Load reads the stored credentials. A missing file is reported as "not signed
// in" so the caller can surface a single actionable message.
func Load() (*Creds, error) {
	data, err := os.ReadFile(Path())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("not signed in to ChatGPT (run `yap login`)")
		}
		return nil, fmt.Errorf("read %s: %w", Path(), err)
	}
	var c Creds
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", Path(), err)
	}
	if c.RefreshToken == "" || c.ClientID == "" {
		return nil, fmt.Errorf("%s is incomplete (run `yap login`)", Path())
	}
	return &c, nil
}

// save writes the record atomically with owner-only permissions, so a crash
// mid-write cannot leave a truncated credential file behind.
func save(c *Creds) error {
	p := Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// token returns a valid access token, refreshing it when it is within
// refreshMargin of expiry.
func token(ctx context.Context) (string, error) {
	c, err := Load()
	if err != nil {
		return "", err
	}
	if !needsRefresh(c) {
		return c.AccessToken, nil
	}
	next, err := refresh(ctx, c)
	if err != nil {
		return "", err
	}
	if err := save(next); err != nil {
		return "", err
	}
	return next.AccessToken, nil
}

func needsRefresh(c *Creds) bool {
	return c.AccessToken == "" || time.Now().Add(refreshMargin).After(c.Expiry)
}

// login runs the browser sign-in and stores the resulting credentials. out
// receives the authorization URL and progress lines; the browser must be
// opened by the user (Yap runs in a terminal, possibly over ssh).
func login(ctx context.Context, out io.Writer) error {
	prev, _ := Load() // a re-login reuses the issued client id and host id

	clientID, hostID := dynamicClientID, ""
	var idHint, emailHint string
	if prev != nil {
		hostID = prev.HostID
		if prev.ClientID != "" && prev.ClientID != dynamicClientID {
			clientID, idHint, emailHint = prev.ClientID, prev.IDToken, prev.Email
		}
	}
	if hostID == "" {
		var err error
		if hostID, err = newHostID(); err != nil {
			return err
		}
	}

	verifier, err := randomToken(32)
	if err != nil {
		return err
	}
	sum := sha256.Sum256([]byte(verifier))
	state, err := randomToken(16)
	if err != nil {
		return err
	}
	nonce, err := randomToken(16)
	if err != nil {
		return err
	}

	ln, err := listen()
	if err != nil {
		return err
	}
	defer ln.Close() //nolint:errcheck // best-effort
	redirectURI := fmt.Sprintf("http://127.0.0.1:%d%s", ln.Addr().(*net.TCPAddr).Port, callbackPath)

	q := url.Values{
		"client_id":             {clientID},
		"ext_agent_host_id":     {hostID},
		"response_type":         {"code"},
		"redirect_uri":          {redirectURI},
		"scope":                 {scope},
		"resource":              {resource},
		"state":                 {state},
		"nonce":                 {nonce},
		"code_challenge_method": {"S256"},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(sum[:])},
	}
	// agent_name_hint is a first-registration hint only; a reauthorization
	// carries the retained identity instead.
	if clientID == dynamicClientID {
		q.Set("agent_name_hint", appName)
	} else {
		if idHint != "" {
			q.Set("id_token_hint", idHint)
		}
		if emailHint != "" {
			q.Set("login_hint", emailHint)
		}
	}

	fmt.Fprintf(out, "Open this URL in your browser and approve access:\n\n  %s?%s\n\n", authorizeURL, q.Encode())
	fmt.Fprintf(out, "Waiting for the callback on %s ...\n", redirectURI)

	cb, err := waitForCallback(ctx, ln, state)
	if err != nil {
		return err
	}
	if cb.IssuedClientID != "" && cb.IssuedClientID != dynamicClientID {
		clientID = cb.IssuedClientID
	}
	if clientID == dynamicClientID {
		return errors.New("registration did not return a client id; run `yap login` again")
	}

	creds, err := exchange(ctx, url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {clientID},
		"code":          {cb.Code},
		"code_verifier": {verifier},
		"redirect_uri":  {redirectURI},
		"resource":      {resource},
	})
	if err != nil {
		return err
	}
	claims, err := idTokenClaims(creds.IDToken, clientID, nonce)
	if err != nil {
		return err
	}
	creds.ClientID, creds.HostID = clientID, hostID
	creds.Subject, creds.Email = claims.Sub, claims.Email
	if err := save(creds); err != nil {
		return err
	}
	fmt.Fprintf(out, "Signed in as %s (ChatGPT plan usage enabled).\n", creds.Email)
	return nil
}

// Listen on the documented port, falling back to any free port: only the port
// may vary, the scheme/host/path are fixed.
func listen() (net.Listener, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:"+callbackPort)
	if err == nil {
		return ln, nil
	}
	return net.Listen("tcp", "127.0.0.1:0")
}

type callback struct {
	Code           string
	IssuedClientID string
}

// waitForCallback serves exactly one authorization callback and validates the
// state it echoes back.
func waitForCallback(ctx context.Context, ln net.Listener, state string) (*callback, error) {
	type result struct {
		cb  callback
		err error
	}
	ch := make(chan result, 1)

	mux := http.NewServeMux()
	mux.HandleFunc(callbackPath, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		var res result
		switch {
		case q.Get("error") != "":
			res.err = fmt.Errorf("authorization denied: %s %s", q.Get("error"), q.Get("error_description"))
		case q.Get("state") != state:
			res.err = errors.New("authorization callback state mismatch")
		case q.Get("code") == "":
			res.err = errors.New("authorization callback carried no code")
		default:
			res.cb = callback{Code: q.Get("code"), IssuedClientID: q.Get("client_id")}
		}
		select {
		case ch <- res:
		default: // a duplicate callback (page reload): the first one counts
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		msg := "<p>Signed in to yap. You can close this tab."
		if res.err != nil {
			msg = "<p>Sign-in failed. Return to the terminal for the reason."
		}
		_, _ = io.WriteString(w, "<!doctype html><title>yap</title>"+msg)
	})

	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			select {
			case ch <- result{err: err}:
			default:
			}
		}
	}()
	defer func() {
		// Shutdown (not Close) so the browser still receives the confirmation
		// page from the handler above.
		shut, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shut)
	}()

	ctx, cancel := context.WithTimeout(ctx, loginTimeout)
	defer cancel()
	select {
	case <-ctx.Done():
		return nil, fmt.Errorf("sign-in timed out: %w", ctx.Err())
	case res := <-ch:
		if res.err != nil {
			return nil, res.err
		}
		return &res.cb, nil
	}
}

// tokenEndpointError retains the server diagnostic and its OAuth error code.
type tokenEndpointError struct {
	status string
	body   string
	code   string
}

func (e *tokenEndpointError) Error() string {
	return fmt.Sprintf("token endpoint: HTTP %s: %s", e.status, e.body)
}

// exchange swaps an authorization code (or, later, a refresh token) for tokens.
func exchange(ctx context.Context, form url.Values) (*Creds, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck // best-effort: close on read
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		var oauthError struct {
			Error json.RawMessage `json:"error"`
		}
		var code string
		if json.Unmarshal(body, &oauthError) == nil {
			if json.Unmarshal(oauthError.Error, &code) != nil {
				var detail struct {
					Code string `json:"code"`
				}
				if json.Unmarshal(oauthError.Error, &detail) == nil {
					code = detail.Code
				}
			}
		}
		return nil, &tokenEndpointError{status: resp.Status, body: strings.TrimSpace(string(body)), code: code}
	}
	var tok struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		IDToken      string `json:"id_token"`
		ExpiresIn    int    `json:"expires_in"`
		Scope        string `json:"scope"`
	}
	if err := json.Unmarshal(body, &tok); err != nil {
		return nil, fmt.Errorf("parse token response: %w", err)
	}
	if tok.AccessToken == "" || tok.RefreshToken == "" {
		return nil, errors.New("token endpoint returned no access/refresh token")
	}
	if tok.ExpiresIn <= 0 {
		tok.ExpiresIn = 3600 // documented access-token lifetime
	}
	return &Creds{
		AccessToken:  tok.AccessToken,
		RefreshToken: tok.RefreshToken,
		IDToken:      tok.IDToken,
		Expiry:       time.Now().Add(time.Duration(tok.ExpiresIn) * time.Second),
		Scopes:       strings.Fields(tok.Scope),
	}, nil
}

// refresh replaces an expired token set. The refresh token rotates on every
// use, so the caller must persist the returned record.
func refresh(ctx context.Context, old *Creds) (*Creds, error) {
	next, err := exchange(ctx, url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {old.ClientID},
		"refresh_token": {old.RefreshToken},
		"resource":      {resource},
	})
	if err != nil {
		var endpoint *tokenEndpointError
		if errors.As(err, &endpoint) {
			switch endpoint.code {
			case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused":
				return nil, fmt.Errorf("ChatGPT session is no longer renewable; run `yap login chatgpt`: %w", err)
			}
		}
		return nil, err
	}
	next.ClientID, next.HostID = old.ClientID, old.HostID
	next.Subject, next.Email = old.Subject, old.Email
	next.IDToken = old.IDToken // the refresh response carries no new id_token
	if len(next.Scopes) == 0 {
		next.Scopes = old.Scopes // refresh omits scope unless the grant narrowed
	}
	return next, nil
}

type claims struct {
	Sub   string          `json:"sub"`
	Email string          `json:"email"`
	Nonce string          `json:"nonce"`
	Iss   string          `json:"iss"`
	Aud   json.RawMessage `json:"aud"`
}

// idTokenClaims decodes the ID token payload and binds it to this sign-in
// attempt. The signature is not verified: this token arrived over TLS directly
// from the token endpoint in response to our own code exchange with our PKCE
// verifier, so a JWKS check would only re-assert transport security. The nonce,
// issuer and audience checks are what tie the token to this attempt.
func idTokenClaims(idToken, clientID, nonce string) (*claims, error) {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return nil, errors.New("ID token is not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("decode ID token: %w", err)
	}
	var c claims
	if err := json.Unmarshal(payload, &c); err != nil {
		return nil, fmt.Errorf("parse ID token claims: %w", err)
	}
	if c.Iss != "https://auth.openai.com" {
		return nil, fmt.Errorf("ID token issuer %q is not auth.openai.com", c.Iss)
	}
	if c.Nonce != nonce {
		return nil, errors.New("ID token nonce does not match this sign-in")
	}
	var aud []string
	if err := json.Unmarshal(c.Aud, &aud); err != nil {
		var single string
		if jerr := json.Unmarshal(c.Aud, &single); jerr != nil {
			return nil, fmt.Errorf("ID token audience is unreadable: %w", err)
		}
		aud = []string{single}
	}
	ok := false
	for _, a := range aud {
		if a == clientID {
			ok = true
		}
	}
	if !ok {
		return nil, fmt.Errorf("ID token audience %v does not include the issued client id", aud)
	}
	if c.Sub == "" {
		return nil, errors.New("ID token has no subject")
	}
	return &c, nil
}

// newHostID returns the stable per-installation agent host id: a UUIDv4 in the
// documented urn:uuid: form. It is an identifier, not a credential.
func newHostID() (string, error) {
	b, err := randomBytes(16)
	if err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("urn:uuid:%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

func randomToken(n int) (string, error) {
	b, err := randomBytes(n)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("read random bytes: %w", err)
	}
	return b, nil
}

// chatGPT is the Sign in with ChatGPT login: a ChatGPT Plus/Pro plan pays for
// requests to the public Responses API. That route keeps no server-side state,
// so every request must set store=false, which ProviderOptions reports to the
// adapter.
type chatGPT struct{}

func (chatGPT) Name() string { return "chatgpt" }

func (chatGPT) Login(ctx context.Context, out io.Writer) error { return login(ctx, out) }

func (chatGPT) Token(ctx context.Context) (string, error) { return token(ctx) }

func (chatGPT) ProviderOptions() map[string]any { return map[string]any{"store": false} }

func init() { Register(chatGPT{}) }
