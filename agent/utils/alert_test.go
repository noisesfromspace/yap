package utils

import (
	"context"
	"testing"

	"boers.email/yap/agent/decision"
)

// fakeModel returns canned answers so the gate's decision mapping is tested
// without a network round-trip.
type fakeModel struct {
	answers map[string]decision.Answer
	err     error
}

func (f fakeModel) Decide(_ context.Context, req decision.Request) (decision.Response, error) {
	if f.err != nil {
		return decision.Response{}, f.err
	}
	return decision.Response{Answers: f.answers}, nil
}

func fakeAnswer(p, conf, sev float64) map[string]decision.Answer {
	return map[string]decision.Answer{
		"harmful":  {Name: "harmful", Type: decision.Noul, Noul: p, Confidence: conf},
		"severity": {Name: "severity", Type: decision.Score, Score: sev},
	}
}

func gate(t *testing.T, dm decision.Model, tier Tier, hardReason string) Decision {
	t.Helper()
	return ShouldAlert(context.Background(), dm, DefaultAlertConfig, tier, hardReason, "state")
}

func TestSilentTierRuns(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.99, 0.9, 3)}, TierSilent, ""); d.Outcome != OutcomeRun {
		t.Fatalf("silent tier: %+v", d)
	}
}

func TestHardReasonBlocksWithoutModel(t *testing.T) {
	// Deterministic floor must block even when no decision model is present.
	if d := gate(t, nil, TierAskJev, "recursive deletion"); d.Outcome != OutcomeBlock {
		t.Fatalf("hard reason with no model: %+v", d)
	}
	if d := gate(t, fakeModel{answers: fakeAnswer(0.0, 0.9, 0)}, TierAskJev, "sudo"); d.Outcome != OutcomeBlock {
		t.Fatalf("hard reason overrides a benign model verdict: %+v", d)
	}
}

func TestAlwaysBlockTier(t *testing.T) {
	if d := gate(t, nil, TierAlwaysBlock, ""); d.Outcome != OutcomeBlock {
		t.Fatalf("always-block tier: %+v", d)
	}
}

func TestExfiltrationBlocks(t *testing.T) {
	// Score is a weighted mean: almost certain exfiltration is below 3.
	for _, sev := range []float64{3, 2.99} {
		if d := gate(t, fakeModel{answers: fakeAnswer(0.1, 0.9, sev)}, TierAskJev, ""); d.Outcome != OutcomeBlock {
			t.Fatalf("exfil at score %.2f should block: %+v", sev, d)
		}
	}
	// A majority on exfil also blocks when the other mass pulls the mean
	// below 2.5.
	answers := fakeAnswer(0.1, 0.9, 1.8)
	s := answers["severity"]
	s.Probabilities = map[string]float64{"0": 0.4, "3": 0.6}
	answers["severity"] = s
	if d := gate(t, fakeModel{answers: answers}, TierAskJev, ""); d.Outcome != OutcomeBlock {
		t.Fatalf("majority exfil should block: %+v", d)
	}
}

func TestMissingSeverityAdvises(t *testing.T) {
	answers := fakeAnswer(0.1, 0.9, 0)
	delete(answers, "severity")
	if d := gate(t, fakeModel{answers: answers}, TierAskJev, ""); d.Outcome != OutcomeAdvise {
		t.Fatalf("missing severity must not silently run: %+v", d)
	}
}

func TestDestructiveBlocksWhenConfident(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.6, 0.9, 2)}, TierAskJev, ""); d.Outcome != OutcomeBlock {
		t.Fatalf("destructive + even odds: %+v", d)
	}
	// Destructive + low confidence = no signal -> block.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.4, 0.2, 2)}, TierAskJev, ""); d.Outcome != OutcomeBlock {
		t.Fatalf("destructive + low confidence should block: %+v", d)
	}
	// Destructive + low P + calibrated = advise (warn, don't interrupt).
	if d := gate(t, fakeModel{answers: fakeAnswer(0.2, 0.9, 2)}, TierAskJev, ""); d.Outcome != OutcomeAdvise {
		t.Fatalf("destructive + low P + calibrated should advise: %+v", d)
	}
}

func TestLikelyHarmfulBlocks(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.8, 0.9, 1)}, TierAskJev, ""); d.Outcome != OutcomeBlock {
		t.Fatalf("high P + non-trivial severity should block: %+v", d)
	}
}

func TestSuspiciousAdvises(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.5, 0.9, 1)}, TierAskJev, ""); d.Outcome != OutcomeAdvise {
		t.Fatalf("mid P should advise: %+v", d)
	}
	if d := gate(t, fakeModel{answers: fakeAnswer(0.4, 0.9, 0)}, TierAskJev, ""); d.Outcome != OutcomeAdvise {
		t.Fatalf("P above advise bar should advise even at severity 0: %+v", d)
	}
}

func TestUncertainAdvises(t *testing.T) {
	// Low confidence near the advise bar is "no signal" -> at least advise.
	if d := gate(t, fakeModel{answers: fakeAnswer(0.25, 0.3, 0)}, TierAskJev, ""); d.Outcome != OutcomeAdvise {
		t.Fatalf("low confidence near 0.5 should advise: %+v", d)
	}
}

func TestBenignRuns(t *testing.T) {
	if d := gate(t, fakeModel{answers: fakeAnswer(0.1, 0.9, 0)}, TierAskJev, ""); d.Outcome != OutcomeRun {
		t.Fatalf("benign call should run: %+v", d)
	}
}

func TestModelFailureFailClosesToAdvise(t *testing.T) {
	dm := fakeModel{err: context.DeadlineExceeded}
	if d := gate(t, dm, TierAskJev, ""); d.Outcome != OutcomeAdvise {
		t.Fatalf("model failure should advise, not run or block: %+v", d)
	}
}

func TestNoModelAdvises(t *testing.T) {
	if d := gate(t, nil, TierAskJev, ""); d.Outcome != OutcomeAdvise {
		t.Fatalf("missing model should advise, not run silently: %+v", d)
	}
}
