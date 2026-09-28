package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// models lists the provider/model combos available in the config by
// querying each provider's OpenAI-compatible GET /models endpoint — one
// "provider/model" per line on stdout. Providers that fail are skipped
// with a warning on stderr: one down provider must not block the picker.
//
// The requests are independent, so they run concurrently — the picker's
// latency is one round-trip, not N, and a provider's 10s timeout no
// longer serializes every provider after it.
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
	client := &http.Client{Timeout: 10 * time.Second}

	type result struct {
		lines []string
		errs  []string
	}
	results := make([]result, len(names)) // one slot per goroutine, no shared state
	var wg sync.WaitGroup
	for i, name := range names {
		wg.Add(1)
		go func(i int, name string) {
			defer wg.Done()
			prov := cfg.Providers[name]
			req, err := http.NewRequest("GET", strings.TrimSuffix(prov.BaseURL, "/")+"/models", nil)
			if err != nil {
				results[i].errs = append(results[i].errs, fmt.Sprintf("pitel: %s: %v", name, err))
				return
			}
			if key := os.Getenv(prov.APIKeyEnv); key != "" {
				req.Header.Set("Authorization", "Bearer "+key)
			}
			resp, err := client.Do(req)
			if err != nil {
				results[i].errs = append(results[i].errs, fmt.Sprintf("pitel: %s: %v", name, err))
				return
			}
			var list struct {
				Data []struct {
					ID string `json:"id"`
				} `json:"data"`
			}
			derr := json.NewDecoder(resp.Body).Decode(&list)
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK || derr != nil {
				results[i].errs = append(results[i].errs, fmt.Sprintf("pitel: %s: GET /models: %s", name, resp.Status))
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

	// Emit in the original (sorted) provider order so output is
	// deterministic regardless of goroutine completion order.
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
