package utils

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"boers.email/yap/agent/decide"
)

// The alert gate is the pre-execution decision for a single tool call:
// should it run silently, run with an advisory, or pause the
// turn and ask the user to approve? It layers a cheap deterministic floor
// (regexes, per-tool checks) under one batched decision-model pass for the
// gray middle, so jev only pays a round-trip where a wrong call can hurt.
//
// It is deliberately NOT a security boundary — bash is unsandboxed by
// design (doc: R-compiled-tools) and any gate is steerable. It exists to make the common
// catastrophic mistake (an injected `rm -rf /`, an exfiltration curl) pause
// for a human, matching the "allow this" approval flow the deterministic
// regexes already provide.

// Tier classifies how much scrutiny a tool call gets before it runs.
type Tier int

const (
	TierSilent         Tier = iota // run without consulting the decision model
	TierAskJev                     // ask the decision model; approval/advisory/run
	TierAlwaysApproval             // always pause for approval (no model)
)

// Outcome is the gate's verdict for one tool call.
type Outcome int

const (
	OutcomeRun      Outcome = iota // run silently
	OutcomeAdvisory                // run, but surface an advisory
	OutcomeApproval                // pause and ask the user to approve (requires approval)
)

// AlertConfig tunes the decision thresholds. Zero values are replaced by
// DefaultAlertConfig; a value is "unset" when it is <= 0.
type AlertConfig struct {
	// ApprovalProb is the P(harmful) at or above which a non-destructive call
	// requires approval. Interruption is reserved for high probability or
	// high severity.
	ApprovalProb float64
	// AdvisoryProb is the low bar for an advisory ("lots of advisories").
	AdvisoryProb float64
	// MinConfidence is the calibration floor: below it an answer is treated
	// as "no signal" and escalates to at least a warning.
	MinConfidence float64
}

// DefaultAlertConfig is the conservative starting point: a low bar for an
// advisory (surfaces suspicious calls without interrupting), a high bar for
// approval (interruption reserved for high-probability or high-severity
// harm). Tuned from the audit log via the `alert` config block.
var DefaultAlertConfig = AlertConfig{
	ApprovalProb:  0.7,
	AdvisoryProb:  0.35,
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
	// SeverityProbabilities is the severity score's per-band distribution
	// (category index -> probability); nil when no model was consulted.
	SeverityProbabilities map[string]float64
}

// severity bands for the score question (legend index -> meaning).
const (
	sevDestructive = 2.0 // "destructive or data loss"
	approvalAtEven = 0.5 // destructive + at least even odds -> approval
)

// severityLabels is the severity score question's ordered level -> meaning
// (index 0 = benign, 3 = credential theft or exfiltration); severityShort is
// the compact form rendered in advisories. Keep the two tables in sync.
var severityLabels = []string{
	"benign",
	"reversible or inconvenient",
	"destructive or data loss",
	"credential theft or exfiltration",
}

var severityShort = []string{"benign", "reversible", "destructive", "exfiltration"}

// ShouldAlert decides the outcome for one tool call.
//
//	hardReason != ""            -> Approval (deterministic floor; never downgraded)
//	tier == TierAlwaysApproval  -> Approval (e.g. ssh)
//	tier == TierSilent          -> Run
//	tier == TierAskJev          -> the decision model decides (below)
//
// It never fails: a decision-model outage fail-closes to an advisory
// (OutcomeAdvisory) so a down backend warns loudly instead of either
// bricking the tool or running silently.
func ShouldAlert(ctx context.Context, dm decide.Model, cfg AlertConfig, tier Tier, hardReason string, state any) Decision {
	d := Decision{Outcome: OutcomeRun}
	if tier == TierSilent {
		return d
	}
	if hardReason != "" || tier == TierAlwaysApproval {
		d.Outcome = OutcomeApproval
		d.Reason = hardReason
		if d.Reason == "" {
			d.Reason = "requires approval"
		}
		return d
	}
	// tier == TierAskJev
	if dm == nil {
		d.Outcome = OutcomeAdvisory
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
				Criteria:     severityLabels,
			},
		},
	})
	if err != nil {
		d.Outcome = OutcomeAdvisory
		d.Reason = fmt.Sprintf("alert check failed (%v)", err)
		return d
	}

	harm, ok := resp.Answers["harmful"]
	if !ok || harm.Type != decide.Noul {
		d.Outcome = OutcomeAdvisory
		d.Reason = "alert check returned no answer"
		return d
	}
	sev, ok := resp.Answers["severity"]
	if !ok || sev.Type != decide.Score {
		d.Outcome = OutcomeAdvisory
		d.Reason = "alert check returned no severity answer"
		return d
	}
	d.PAlert = harm.Noul
	d.Confidence = harm.Confidence
	d.Severity = sev.Score
	d.SeverityProbabilities = sev.Probabilities

	d.Outcome, d.Reason = decideOutcome(harm.Noul, harm.Confidence, sev, cfg)
	return d
}

// decideOutcome maps the calibrated answer to a layered outcome and a plain
// human phrase. Precedence is top-down; the first matching case wins. The
// numbers are kept out of the reason and rendered separately (see Metrics,
// SeverityCategory) so the advisory line and approval dialog stay readable.
func decideOutcome(p, conf float64, severity decide.Answer, cfg AlertConfig) (Outcome, string) {
	sev := severity.Score

	switch {
	// Score is a weighted mean, not a category: a strong exfiltration
	// probability need not yield an exact score of 3 (or even 2.5).
	case severity.Probabilities["3"] >= 0.5 || sev >= 2.5:
		return OutcomeApproval, "possible credential theft or exfiltration"
	case sev >= sevDestructive && (p >= approvalAtEven || conf < cfg.MinConfidence):
		// Destructive and either at least even odds, or the model is
		// uncalibrated about it: no signal -> ask rather than act.
		return OutcomeApproval, "possible destructive operation"
	case sev >= sevDestructive:
		return OutcomeAdvisory, "possibly destructive, model unsure"
	case p >= cfg.ApprovalProb && sev >= 1:
		return OutcomeApproval, "likely harmful"
	case p >= cfg.AdvisoryProb:
		return OutcomeAdvisory, "suspicious tool call"
	case conf < cfg.MinConfidence && p >= cfg.AdvisoryProb/2:
		// Near 0.5 with low confidence is "no signal": conservative path is
		// to surface it rather than run silently.
		return OutcomeAdvisory, "decision model uncertain"
	default:
		return OutcomeRun, ""
	}
}

// SeverityCategory returns the dominant severity band's short label and its
// probability ("reversible", 0.97), or ("", 0) when no distribution is
// available (the model was not consulted or returned no per-band scores).
func (d Decision) SeverityCategory() (string, float64) {
	bestIdx, bestP := -1, -1.0
	for idx, p := range d.SeverityProbabilities {
		if p <= bestP {
			continue
		}
		bestP = p
		if i, err := strconv.Atoi(idx); err == nil && i >= 0 && i < len(severityShort) {
			bestIdx = i
		}
	}
	if bestIdx < 0 {
		return "", 0
	}
	return severityShort[bestIdx], bestP
}

// SeverityBreakdown renders the severity distribution as a compact
// "benign 2% · reversible 97% · destructive 1%" (non-zero bands, in order).
// Empty when no distribution is available.
func (d Decision) SeverityBreakdown() string {
	var parts []string
	for i, label := range severityShort {
		if p := d.SeverityProbabilities[strconv.Itoa(i)]; p > 0 {
			parts = append(parts, fmt.Sprintf("%s %.0f%%", label, p*100))
		}
	}
	return strings.Join(parts, " · ")
}

// Metrics renders the decision's numbers compactly for surfaces that show
// only a reason string (the approval dialog and the alerts picker). Empty
// when no model was consulted, so hard-block reasons stay as-is.
func (d Decision) Metrics() string {
	if d.PAlert == 0 && d.Severity == 0 && d.Confidence == 0 {
		return ""
	}
	sev := fmt.Sprintf("severity=%.2f", d.Severity)
	if cat, catP := d.SeverityCategory(); cat != "" {
		sev = fmt.Sprintf("%s %s (%.0f%%)", sev, cat, catP*100)
	}
	return fmt.Sprintf("P(harmful)=%.2f · %s · conf=%.2f", d.PAlert, sev, d.Confidence)
}
