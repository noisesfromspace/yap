// Package auth manages the interactive logins a provider can use instead of
// an API key — today Sign in with ChatGPT, later whatever subscription or plan
// logins providers add. Each login method self-registers (see chatgpt.go),
// is selected by a provider's `auth` field in settings.json, and is driven by
// `yap login <method>`. The turn loop and the model picker resolve a
// refreshable token through Token, so adding a method only needs a new file in
// this package — config, turn and main stay untouched.
package auth

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Method is one interactive login. A provider opts in with "auth": "<name>";
// `yap login <name>` runs the browser flow once, and every request
// authenticates with the token Token returns.
type Method interface {
	// Name is the method id in settings.json and `yap login` (e.g. "chatgpt").
	Name() string
	// Login runs the interactive sign-in and stores a credential locally.
	Login(ctx context.Context, out io.Writer) error
	// Token returns a valid credential token, refreshing it as needed. It
	// errors with a "run yap login" hint when nothing is stored yet.
	Token(ctx context.Context) (string, error)
	// ProviderOptions returns the request options this route requires (nil
	// when none); they are merged into every inference request.
	ProviderOptions() map[string]any
}

var methods = map[string]Method{}

// Register adds a login method. Call it from a method file's init.
func Register(m Method) {
	if _, dup := methods[m.Name()]; dup {
		panic("auth: duplicate method " + m.Name())
	}
	methods[m.Name()] = m
}

// Methods returns the registered method names, sorted.
func Methods() []string {
	names := make([]string, 0, len(methods))
	for n := range methods {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

func lookup(name string) (Method, error) {
	m, ok := methods[name]
	if !ok {
		return nil, fmt.Errorf("unknown auth method %q (available: %s)", name, strings.Join(Methods(), ", "))
	}
	return m, nil
}

// Validate reports whether name is a registered login method.
func Validate(name string) error {
	_, err := lookup(name)
	return err
}

// Login runs the named method's interactive sign-in.
func Login(ctx context.Context, name string, out io.Writer) error {
	m, err := lookup(name)
	if err != nil {
		return err
	}
	return m.Login(ctx, out)
}

// Token resolves a token for the named method.
func Token(ctx context.Context, name string) (string, error) {
	m, err := lookup(name)
	if err != nil {
		return "", err
	}
	return m.Token(ctx)
}

// ProviderOptions returns the named method's required request options.
func ProviderOptions(name string) map[string]any {
	m, err := lookup(name)
	if err != nil {
		return nil
	}
	return m.ProviderOptions()
}
