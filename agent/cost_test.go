package main

import (
	"context"
	"errors"
	"testing"

	"boers.email/yap/agent/decide"
)

// fakeDecider returns a fixed response with a backend-reported cost.
type fakeDecider struct {
	cost  float64
	calls int
}

func (f *fakeDecider) Decide(ctx context.Context, req decide.Request) (decide.Response, error) {
	f.calls++
	return decide.Response{Model: "fake", Cost: f.cost}, nil
}

func TestCostTrackingModelFoldsDecisionCost(t *testing.T) {
	var total costTotal
	fake := &fakeDecider{cost: 0.0042}
	m := &costTrackingModel{inner: fake, total: &total}
	if _, err := m.Decide(context.Background(), decide.Request{}); err != nil {
		t.Fatal(err)
	}
	if got := total.Load(); got != 0.0042 {
		t.Fatalf("total = %v, want 0.0042", got)
	}
	if fake.calls != 1 {
		t.Fatalf("inner calls = %d, want 1", fake.calls)
	}
}

// errDecider always fails; a failed decision round-trip must not change cost.
type errDecider struct{}

func (errDecider) Decide(ctx context.Context, req decide.Request) (decide.Response, error) {
	return decide.Response{}, errors.New("boom")
}

func TestCostTrackingModelIgnoresError(t *testing.T) {
	var total costTotal
	m := &costTrackingModel{inner: errDecider{}, total: &total}
	if _, err := m.Decide(context.Background(), decide.Request{}); err == nil {
		t.Fatal("expected error")
	}
	if got := total.Load(); got != 0 {
		t.Fatalf("total should stay 0 on error, got %v", got)
	}
}
