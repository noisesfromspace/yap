// Package decide defines Yap's decision-model surface: typed, calibrated
// answers (probabilities) to structured questions about a state. The decision
// tool speaks these types; only implementations (e.g. agent/decide/jev)
// know a wire protocol. Keeping this boundary means a decision backend can
// be swapped without touching the tool or the agent loop.
package decide

import (
	"context"
	"fmt"
)

// QuestionType names the three decision primitives a model can answer.
type QuestionType string

const (
	Noul   QuestionType = "noul"   // yes/no -> P(yes)
	Choice QuestionType = "choice" // pick one of several labelled options
	Score  QuestionType = "score"  // place the answer on an ordered scale
)

// Question is one decision to make about Request.State. Criteria is a
// map[string]string (noul, choice: option -> description) or a
// []string (score: ordered level labels, index 0 = first).
type Question struct {
	Name         string
	Type         QuestionType
	Instructions string
	Criteria     any
}

// Answer is one typed answer. Exactly one of Noul, Choice, Score is
// populated, matching Type.
type Answer struct {
	Name          string
	Type          QuestionType
	Noul          float64            // P(yes), in [0,1]
	Choice        string             // the selected option
	Score         float64            // probability-weighted position on the scale
	Confidence    float64            // concentration of Probabilities (calibration signal)
	Probabilities map[string]float64 // option -> probability (choice); level index -> probability (score)
	Legend        map[string]string  // score only: level index -> label
}

type Request struct {
	// State is the content to evaluate: a plain string, or a JSON object
	// or array of related context.
	State     any
	Questions []Question
}

type Response struct {
	Answers map[string]Answer
	Model   string
	// Cost is the backend-reported USD cost of the decision pass (0 when the
	// backend does not report one). The agent folds it into the turn total.
	Cost float64
}

// Model is the Yap-owned decision-model surface: one parallel pass over
// the questions, no chat, no tool loop. Implementations return typed,
// calibrated answers or an error; they never generate prose.
type Model interface {
	Decide(ctx context.Context, req Request) (Response, error)
}

// Config is the provider-facing subset of the `decision` config block. It
// carries the options shared by every decision backend; the agent loop
// resolves APIKey from the named env var before invoking a factory. A
// backend with provider-specific options can read them from the environment
// directly.
type Config struct {
	BaseURL string
	APIKey  string
	Model   string
}

// Provider is a decision-backend factory: it builds a Model from the common
// config. Backends self-register via RegisterProvider from their package's
// init(), mirroring websearch providers (agent/tools).
type Provider func(cfg Config) (Model, error)

var providers = map[string]Provider{}

// RegisterProvider adds a decision backend; called from a provider package's
// init().
func RegisterProvider(name string, p Provider) {
	providers[name] = p
}

// DefaultProvider is the fallback when config names none.
const DefaultProvider = "jev"

// New builds the named decision backend (DefaultProvider when name is empty).
// It fails loudly on an unknown provider so a config typo surfaces instead of
// silently degrading to "no decision model" advisories.
func New(name string, cfg Config) (Model, error) {
	if name == "" {
		name = DefaultProvider
	}
	p, ok := providers[name]
	if !ok {
		return nil, fmt.Errorf("decision provider %q is not registered", name)
	}
	return p(cfg)
}
