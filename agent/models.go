package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	anycfg "github.com/mozilla-ai/any-llm-go/config"
	anyprov "github.com/mozilla-ai/any-llm-go/providers"
	"github.com/mozilla-ai/any-llm-go/providers/anthropic"
	"github.com/mozilla-ai/any-llm-go/providers/deepseek"
	"github.com/mozilla-ai/any-llm-go/providers/gemini"
	"github.com/mozilla-ai/any-llm-go/providers/openai"
)

// modelsProviderFactory allows tests to override provider construction.
var modelsProviderFactory func(name string, prov Provider) (anyprov.Provider, error)

// models lists the provider/model combos available in the config by
// asking the SDK for models where supported; other providers are skipped.
// One "provider/model" per line on stdout. Providers that fail are skipped
// with a warning on stderr: one down provider must not block the picker.
//
// The requests are independent, so they run concurrently.
func models() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	names := make([]string, 0, len(cfg.Providers))
	for name := range cfg.Providers {
		names = append(names, name)
	}
	sort.Strings(names)

	makeProv := func(name string, prov Provider) (anyprov.Provider, error) {
		if modelsProviderFactory != nil {
			return modelsProviderFactory(name, prov)
		}
		opts := []anycfg.Option{}
		if k := os.Getenv(prov.APIKeyEnv); k != "" {
			opts = append(opts, anycfg.WithAPIKey(k))
		}
		if prov.BaseURL != "" {
			opts = append(opts, anycfg.WithBaseURL(strings.TrimRight(prov.BaseURL, "/")))
		}
		switch name {
		case "openai":
			return openai.New(opts...)
		case "anthropic":
			return anthropic.New(opts...)
		case "gemini", "google":
			return gemini.New(opts...)
		case "deepseek":
			return deepseek.New(opts...)
		default:
			// For tests, allow unknown providers to be skipped gracefully.
			return nil, fmt.Errorf("unsupported provider %q", name)
		}
	}

	type result struct {
		lines []string
		errs  []string
	}
	results := make([]result, len(names))
	var wg sync.WaitGroup
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for i, name := range names {
		wg.Add(1)
		go func(i int, name string) {
			defer wg.Done()
			prov := cfg.Providers[name]
			p, err := makeProv(name, prov)
			if err != nil {
				results[i].errs = append(results[i].errs, fmt.Sprintf("yap: %s: %v", name, err))
				return
			}
			lister, ok := p.(anyprov.ModelLister)
			if !ok {
				return
			}
			list, err := lister.ListModels(ctx)
			if err != nil || list == nil {
				results[i].errs = append(results[i].errs, fmt.Sprintf("yap: %s: list models: %v", name, err))
				return
			}
			ids := make([]string, 0, len(list.Data))
			for _, m := range list.Data {
				ids = append(ids, m.ID)
			}
			sort.Strings(ids)
			for _, id := range ids {
				results[i].lines = append(results[i].lines, name+"/"+id)
			}
		}(i, name)
	}
	wg.Wait()

	for _, r := range results {
		for _, e := range r.errs {
			fmt.Fprintln(os.Stderr, e)
		}
		for _, l := range r.lines {
			fmt.Println(l)
		}
	}
	return nil
}
