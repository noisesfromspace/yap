package utils

import (
	"context"
	"fmt"

	"boers.email/yap/agent/decide"
)

// The alert gate is the pre-execution decision for a single tool call:
// should it run silently, run with a non-blocking warning, or pause the
// turn and ask the user to approve? It layers a cheap deterministic floor
// (regexes, per-tool checks) under one batched decision-model pass for the
// gray middle, so jev only pays a round-trip where a wrong call can hurt.
//
// It is deliberately NOT a security boundary — bash is unsandboxed by
// design (doc: R15) and any gate is steerable. It exists to make the common
// catastrophic mistake (an injected `rm -rf /`, an exfiltration curl) pause
// for a human, matching the "allow this" approval flow the deterministic
// regexes already provide.

// Tier classifies how much scrutiny a tool call gets before it runs.
type Tier int

const (
	TierSilent      Tier = iota // run without consulting the decision model
	TierAskJev                  // ask the decision model; block/advise/run
	TierAlwaysBlock             // always pause for approval (no model)
)

// Outcome is the gate's verdict for one tool call.
type Outcome int

const (
	OutcomeRun    Outcome = iota // run silently
	OutcomeAdvise                // run, but surface a non-blocking warning
	OutcomeBlock                 // pause and ask the user to approve
)

// AlertConfig tunes the decision thresholds. Zero values are replaced by
// DefaultAlertConfig; a value is "unset" when it is <= 0.
type AlertConfig struct {
	// BlockProb is the P(harmful) at or above which a non-destructive call
	// blocks. Interruption is reserved for high probability or high severity.
	BlockProb float64
	// AdviseProb is the low bar for a non-blocking warning ("lots of alerts").
	AdviseProb float64
	// MinConfidence is the calibration floor: below it an answer is treated
	// as "no signal" and escalates to at least a warning.
	MinConfidence float64
}

// DefaultAlertConfig is the conservative starting point: a low bar to advise
// (surfaces suspicious calls without interrupting), a high bar to block
// (interruption reserved for high-probability or high-severity harm). Tuned
// from the audit log via the `alert` config block.
var DefaultAlertConfig = AlertConfig{
	BlockProb:     0.7,
	AdviseProb:    0.35,
	MinConfidence: 0.6,
}

// Decision records why the gate chose its outcome, so the transcript can
// self-document the call. PAlert, Severity and Confidence are the decision
// model's calibrated numbers; they are zero when no model was consulted.
type Decision struct {
	Outcome    Outcome
	Reason     string  // human-readable, shown in the approval dialog / notice
	PAlert     float64 // P(harmful)
	Severity   float64 // worst-case harm score (0..3)
	Confidence float64
}

// severity bands for the score question (legend index -> meaning).
const (
	sevDestructive = 2.0 // "destructive or data loss"
	blockAtEven    = 0.5 // destructive + at least even odds -> block
)

// ShouldAlert decides the outcome for one tool call.
//
//	hardReason != ""            -> Block (deterministic floor; never downgraded)
//	tier == TierAlwaysBlock     -> Block (e.g. ssh)
//	tier == TierSilent          -> Run
//	tier == TierAskJev          -> the decision model decides (below)
//
// It never fails: a decision-model outage fail-closes to a non-blocking
// warning (OutcomeAdvise) so a down backend warns loudly instead of either
// bricking the tool or running silently.
func ShouldAlert(ctx context.Context, dm decide.Model, cfg AlertConfig, tier Tier, hardReason string, state any) Decision {
	d := Decision{Outcome: OutcomeRun}
	if tier == TierSilent {
		return d
	}
	if hardReason != "" || tier == TierAlwaysBlock {
		d.Outcome = OutcomeBlock
		d.Reason = hardReason
		if d.Reason == "" {
			d.Reason = "requires approval"
		}
		return d
	}
	// tier == TierAskJev
	if dm == nil {
		d.Outcome = OutcomeAdvise
		d.Reason = "no decision model configured; alert check skipped"
		return d
	}

	resp, err := dm.Decide(ctx, decide.Request{
		State: state,
		Questions: []decide.Question{
			{
				Name:         "harmful",
				Type:         decide.Noul,
				Instructions: "Could running this tool call without asking the user first cause meaningful harm (data loss, credential theft or exfiltration, or an irreversible or expensive change)?",
				Criteria:     map[string]string{"true": "potentially harmful", "false": "benign or low-stakes"},
			},
			{
				Name:         "severity",
				Type:         decide.Score,
				Instructions: "What is the worst plausible harm if this tool call runs unapproved?",
				Criteria:     []string{"benign", "reversible or inconvenient", "destructive or data loss", "credential theft or exfiltration"},
			},
		},
	})
	if err != nil {
		d.Outcome = OutcomeAdvise
		d.Reason = fmt.Sprintf("alert check failed (%v)", err)
		return d
	}

	harm, ok := resp.Answers["harmful"]
	if !ok || harm.Type != decide.Noul {
		d.Outcome = OutcomeAdvise
		d.Reason = "alert check returned no answer"
		return d
	}
	sev, ok := resp.Answers["severity"]
	if !ok || sev.Type != decide.Score {
		d.Outcome = OutcomeAdvise
		d.Reason = "alert check returned no severity answer"
		return d
	}
	d.PAlert = harm.Noul
	d.Confidence = harm.Confidence
	d.Severity = sev.Score

	d.Outcome, d.Reason = decideOutcome(harm.Noul, harm.Confidence, sev, cfg)
	return d
}

// decideOutcome maps the calibrated answer to a layered outcome. Precedence is
// top-down; the first matching case wins.
func decideOutcome(p, conf float64, severity decide.Answer, cfg AlertConfig) (Outcome, string) {
	sev := severity.Score
	nums := fmt.Sprintf("P(harmful)=%.2f severity=%.2f", p, sev)

	switch {
	// Score is a weighted mean, not a category: a strong exfiltration
	// probability need not yield an exact score of 3 (or even 2.5).
	case severity.Probabilities["3"] >= 0.5 || sev >= 2.5:
		return OutcomeBlock, "possible credential theft or exfiltration (" + nums + ")"
	case sev >= sevDestructive && (p >= blockAtEven || conf < cfg.MinConfidence):
		// Destructive and either at least even odds, or the model is
		// uncalibrated about it: no signal -> ask rather than act.
		return OutcomeBlock, "possible destructive operation (" + nums + ")"
	case sev >= sevDestructive:
		return OutcomeAdvise, "possibly destructive, model unsure (" + nums + ")"
	case p >= cfg.BlockProb && sev >= 1:
		return OutcomeBlock, "likely harmful (" + nums + ")"
	case p >= cfg.AdviseProb:
		return OutcomeAdvise, "suspicious tool call (" + nums + ")"
	case conf < cfg.MinConfidence && p >= cfg.AdviseProb/2:
		// Near 0.5 with low confidence is "no signal": conservative path is
		// to surface it rather than run silently.
		return OutcomeAdvise, "decision model uncertain (" + nums + ")"
	default:
		return OutcomeRun, ""
	}
}
