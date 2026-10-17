package utils

import (
	"context"
	"testing"

	"boers.email/yap/agent/decide"
)

// fakeModel returns canned answers so the gate's decision mapping is tested
// without a network round-trip.
type fakeModel struct {
	answers map[string]decide.Answer
	err     error
}

func (f fakeModel) Decide(_ context.Context, req decide.Request) (decide.Response, error) {
	if f.err != nil {
		return decide.Response{}, f.err
	}
	return decide.Response{Answers: f.answers}, nil
}

func fakeAnswer(p, conf, sev float64) map[string]decide.Answer {
	return fakeAnswerSecret(p, conf, sev, 0)
}

// fakeAnswerSecret adds an optional reveals_secret answer (noul). 0 means the
// backend returned no answer for it, matching real Jev behavior for absent
// questions.
func fakeAnswerSecret(p, conf, sev, reveals float64) map[string]decide.Answer {
	a := map[string]decide.Answer{
		// The real Decisions API reports confidence on the score answer only;
		// the noul answer has none.
		"harmful":  {Name: "harmful", Type: decide.Noul, Noul: p},
		"severity": {Name: "severity", Type: decide.Score, Score: sev, Confidence: conf},
	}
	if reveals > 0 {
		a["reveals_secret"] = decide.Answer{Name: "reveals_secret", Type: decide.Noul, Noul: reveals}
	}
	return a
}

func gate(t *testing.T, dm decide.Model, tier Tier, hardReason string) Decision {
	t.Helper()
	return ShouldAlert(context.Background(), dm, DefaultAlertConfig, tier, hardReason, "state")
}

func TestSilentTierRuns(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.99, 0.9, 3)}, TierSilent, ""); d.Outcome != OutcomeRun {
		t.Fatalf("silent tier: %+v", d)
	}
}

func TestHardReasonRequiresApprovalWithoutModel(t *testing.T) {
	// Deterministic floor must require approval even when no decision model is present.
	if d := gate(t, nil, TierAskModel, "recursive deletion"); d.Outcome != OutcomeApproval {
		t.Fatalf("hard reason with no model: %+v", d)
	}
	if d := gate(t, fakeModel{answers: fakeAnswer(0.0, 0.9, 0)}, TierAskModel, "sudo"); d.Outcome != OutcomeApproval {
		t.Fatalf("hard reason overrides a benign model verdict: %+v", d)
	}
}

func TestAlwaysApprovalTier(t *testing.T) {
	if d := gate(t, nil, TierAlwaysApproval, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("always-approval tier: %+v", d)
	}
}

func TestExfiltrationRequiresApproval(t *testing.T) {
	// Score is a weighted mean: almost certain exfiltration is below 3.
	for _, sev := range []float64{3, 2.99} {
		if d := gate(t, fakeModel{answers: fakeAnswer(0.1, 0.9, sev)}, TierAskModel, ""); d.Outcome != OutcomeApproval {
			t.Fatalf("exfil at score %.2f should require approval: %+v", sev, d)
		}
	}
	// A majority on exfil also requires approval when the other mass pulls the mean
	// below 2.5.
	answers := fakeAnswer(0.1, 0.9, 1.8)
	s := answers["severity"]
	s.Probabilities = map[string]float64{"0": 0.4, "3": 0.6}
	answers["severity"] = s
	if d := gate(t, fakeModel{answers: answers}, TierAskModel, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("majority exfil should require approval: %+v", d)
	}
}

func TestMissingSeverityAdvisory(t *testing.T) {
	answers := fakeAnswer(0.1, 0.9, 0)
	delete(answers, "severity")
	if d := gate(t, fakeModel{answers: answers}, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("missing severity must not silently run: %+v", d)
	}
}

func TestDestructiveRequiresApprovalWhenConfident(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.6, 0.9, 2)}, TierAskModel, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("destructive + even odds: %+v", d)
	}
	// Destructive + low confidence = no signal -> approval.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.4, 0.2, 2)}, TierAskModel, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("destructive + low confidence should require approval: %+v", d)
	}
	// Destructive + low P + calibrated = advisory (warn, don't interrupt).
	if d := gate(t, fakeModel{answers: fakeAnswer(0.2, 0.9, 2)}, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("destructive + low P + calibrated should warn (advisory): %+v", d)
	}
}

func TestLikelyHarmfulRequiresApproval(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.8, 0.9, 1)}, TierAskModel, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("high P + non-trivial severity should require approval: %+v", d)
	}
}

func TestSuspiciousAdvisory(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.5, 0.9, 1)}, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("mid P should warn (advisory): %+v", d)
	}
	if d := gate(t, fakeModel{answers: fakeAnswer(0.4, 0.9, 0)}, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("P above advisory bar should warn (advisory) even at severity 0: %+v", d)
	}
}

func TestUncertainAdvisory(t *testing.T) {
	// Low confidence near the advisory bar is "no signal" -> at least an advisory.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.25, 0.3, 0)}, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("low confidence near 0.5 should warn (advisory): %+v", d)
	}
}

func TestConfidenceReadFromSeverity(t *testing.T) {
	// The real Decisions API puts confidence on the score answer, not noul:
	// a calibrated low-P call must run silently, not trip the
	// low-confidence "uncertain" path that treats confidence 0 as no signal.
	answers := map[string]decide.Answer{
		"harmful":  {Name: "harmful", Type: decide.Noul, Noul: 0.2},
		"severity": {Name: "severity", Type: decide.Score, Score: 1, Confidence: 0.9},
	}
	d := gate(t, fakeModel{answers: answers}, TierAskModel, "")
	if d.Confidence != 0.9 {
		t.Fatalf("confidence should come from the severity answer: %+v", d)
	}
	if d.Outcome != OutcomeRun {
		t.Fatalf("calibrated low-P call should run silently, got %v", d.Outcome)
	}
}

func TestBenignRuns(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.1, 0.9, 0)}, TierAskModel, ""); d.Outcome != OutcomeRun {
		t.Fatalf("benign call should run: %+v", d)
	}
}

func TestRevealsSecretRequiresApproval(t *testing.T) {
	// A live secret about to reach the transcript pauses for a human even when
	// the general harm/severity read is benign — the exact deny pattern in the
	// audit logs (decrypt-and-print, grep for keys).
	d := gate(t, fakeModel{answers: fakeAnswerSecret(0.1, 0.9, 0.2, 0.6)}, TierAskModel, "")
	if d.Outcome != OutcomeApproval {
		t.Fatalf("reveals_secret above threshold should require approval: %+v", d)
	}
	if d.Reason != "would reveal a secret or credential value" {
		t.Fatalf("reveals_secret reason: %q", d.Reason)
	}
	// Below threshold falls through to the normal severity mapping.
	if d := gate(t, fakeModel{answers: fakeAnswerSecret(0.1, 0.9, 0.2, 0.4)}, TierAskModel, ""); d.Outcome != OutcomeRun {
		t.Fatalf("reveals_secret below threshold should run: %+v", d)
	}
}

func TestAbsentConfidenceDoesNotEscalate(t *testing.T) {
	// Confidence 0 means "the backend did not report it", not "uncalibrated".
	// Treating it as low confidence is what produced the wall of "decision
	// model uncertain" advisories (222 of 272 in real audit logs).
	if d := gate(t, fakeModel{answers: fakeAnswer(0.15, 0, 0)}, TierAskModel, ""); d.Outcome != OutcomeRun {
		t.Fatalf("absent confidence below the advisory bar should run silently: %+v", d)
	}
	// Same probability with reported low confidence still warns.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.15, 0.3, 0)}, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("reported low confidence should still warn: %+v", d)
	}
}

func TestDestructiveAbsentConfidenceIsAdvisory(t *testing.T) {
	// Destructive severity with absent confidence and low P must warn, not
	// hard-block: the old code escalated every sev>=2 call to approval because
	// conf<MinConfidence was always true when confidence was unset.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.2, 0, 2)}, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("destructive + absent confidence + low P should warn: %+v", d)
	}
}

func TestModelFailureFailClosesToAdvisory(t *testing.T) {
	dm := fakeModel{err: context.DeadlineExceeded}
	if d := gate(t, dm, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("model failure should warn (advisory), not run or require approval: %+v", d)
	}
}

func TestNoModelAdvisory(t *testing.T) {
	if d := gate(t, nil, TierAskModel, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("missing model should warn (advisory), not run silently: %+v", d)
	}
}

func TestSeverityCategorization(t *testing.T) {
	d := Decision{
		PAlert: 0.23, Severity: 0.99, Confidence: 0.55,
		SeverityProbabilities: map[string]float64{"0": 0.02, "1": 0.97, "2": 0.01},
	}
	cat, catP := d.SeverityCategory()
	if cat != "reversible" || catP < 0.96 || catP > 0.98 {
		t.Fatalf("SeverityCategory: %q %.2f", cat, catP)
	}
	if b := d.SeverityBreakdown(); b != "benign 2% · reversible 97% · destructive 1%" {
		t.Fatalf("SeverityBreakdown: %q", b)
	}
	if m := d.Metrics(); m != "P(harmful)=0.23 · severity=0.99 reversible (97%) · conf=0.55" {
		t.Fatalf("Metrics: %q", m)
	}
	if r := d.Risk(); r != "moderate — likely reversible" {
		t.Fatalf("Risk: %q", r)
	}
	// A live secret exposure overrides the severity band in the risk phrase.
	if r := (Decision{RevealsSecret: 0.6}).Risk(); r != "critical — possible secret exposure" {
		t.Fatalf("Risk with reveals_secret: %q", r)
	}
	// No model consulted: metrics must stay empty so hard-block reasons read cleanly.
	if m := (Decision{Reason: "recursive deletion"}).Metrics(); m != "" {
		t.Fatalf("Metrics on a hard-block decision should be empty: %q", m)
	}
}
