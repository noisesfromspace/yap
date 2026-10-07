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
	return map[string]decide.Answer{
		"harmful":  {Name: "harmful", Type: decide.Noul, Noul: p, Confidence: conf},
		"severity": {Name: "severity", Type: decide.Score, Score: sev},
	}
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
	if d := gate(t, nil, TierAskJev, "recursive deletion"); d.Outcome != OutcomeApproval {
		t.Fatalf("hard reason with no model: %+v", d)
	}
	if d := gate(t, fakeModel{answers: fakeAnswer(0.0, 0.9, 0)}, TierAskJev, "sudo"); d.Outcome != OutcomeApproval {
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
		if d := gate(t, fakeModel{answers: fakeAnswer(0.1, 0.9, sev)}, TierAskJev, ""); d.Outcome != OutcomeApproval {
			t.Fatalf("exfil at score %.2f should require approval: %+v", sev, d)
		}
	}
	// A majority on exfil also requires approval when the other mass pulls the mean
	// below 2.5.
	answers := fakeAnswer(0.1, 0.9, 1.8)
	s := answers["severity"]
	s.Probabilities = map[string]float64{"0": 0.4, "3": 0.6}
	answers["severity"] = s
	if d := gate(t, fakeModel{answers: answers}, TierAskJev, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("majority exfil should require approval: %+v", d)
	}
}

func TestMissingSeverityAdvisory(t *testing.T) {
	answers := fakeAnswer(0.1, 0.9, 0)
	delete(answers, "severity")
	if d := gate(t, fakeModel{answers: answers}, TierAskJev, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("missing severity must not silently run: %+v", d)
	}
}

func TestDestructiveRequiresApprovalWhenConfident(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.6, 0.9, 2)}, TierAskJev, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("destructive + even odds: %+v", d)
	}
	// Destructive + low confidence = no signal -> approval.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.4, 0.2, 2)}, TierAskJev, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("destructive + low confidence should require approval: %+v", d)
	}
	// Destructive + low P + calibrated = advisory (warn, don't interrupt).
	if d := gate(t, fakeModel{answers: fakeAnswer(0.2, 0.9, 2)}, TierAskJev, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("destructive + low P + calibrated should warn (advisory): %+v", d)
	}
}

func TestLikelyHarmfulRequiresApproval(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.8, 0.9, 1)}, TierAskJev, ""); d.Outcome != OutcomeApproval {
		t.Fatalf("high P + non-trivial severity should require approval: %+v", d)
	}
}

func TestSuspiciousAdvisory(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.5, 0.9, 1)}, TierAskJev, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("mid P should warn (advisory): %+v", d)
	}
	if d := gate(t, fakeModel{answers: fakeAnswer(0.4, 0.9, 0)}, TierAskJev, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("P above advisory bar should warn (advisory) even at severity 0: %+v", d)
	}
}

func TestUncertainAdvisory(t *testing.T) {
	// Low confidence near the advisory bar is "no signal" -> at least an advisory.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.25, 0.3, 0)}, TierAskJev, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("low confidence near 0.5 should warn (advisory): %+v", d)
	}
}

func TestBenignRuns(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.1, 0.9, 0)}, TierAskJev, ""); d.Outcome != OutcomeRun {
		t.Fatalf("benign call should run: %+v", d)
	}
}

func TestModelFailureFailClosesToAdvisory(t *testing.T) {
	dm := fakeModel{err: context.DeadlineExceeded}
	if d := gate(t, dm, TierAskJev, ""); d.Outcome != OutcomeAdvisory {
		t.Fatalf("model failure should warn (advisory), not run or require approval: %+v", d)
	}
}

func TestNoModelAdvisory(t *testing.T) {
	if d := gate(t, nil, TierAskJev, ""); d.Outcome != OutcomeAdvisory {
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
	// No model consulted: metrics must stay empty so hard-block reasons read cleanly.
	if m := (Decision{Reason: "recursive deletion"}).Metrics(); m != "" {
		t.Fatalf("Metrics on a hard-block decision should be empty: %q", m)
	}
}
