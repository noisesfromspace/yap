// Package decide defines Yap's decision-model surface: typed, calibrated
// answers (probabilities) to structured questions about a state. The decision
// tool speaks these types; only implementations (e.g. agent/decide/jev)
// know a wire protocol. Keeping this boundary means a decision backend can
// be swapped without touching the tool or the agent loop.
package decide

import "context"

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
}

// Model is the Yap-owned decision-model surface: one parallel pass over
// the questions, no chat, no tool loop. Implementations return typed,
// calibrated answers or an error; they never generate prose.
type Model interface {
	Decide(ctx context.Context, req Request) (Response, error)
}
