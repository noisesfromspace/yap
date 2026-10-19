package config

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"boers.email/yap/agent/price"
	"boers.email/yap/agent/tools"
)

// models prints the provider/model combos available in the config, one per
// line, plus a `yap: <provider>: <err>` warning on stderr for every provider
// that does not answer. It is the model picker's source of truth and is also
// handed to the `models` tool (tools.SetModelLister), so the CLI, the picker
// and the tool cannot disagree.
func List() error {
	combos, warnings, err := ListCombos()
	if err != nil {
		return err
	}
	for _, w := range warnings {
		fmt.Fprintln(os.Stderr, "yap: "+w)
	}
	for _, c := range combos {
		fmt.Println(c.Name)
	}
	return nil
}

// listCombos discovers the combos in the config. GoAI has no model lister, so
// this small client handles the native providers' model endpoints and the
// common OpenAI-compatible shape: sorted "provider/model" pairs (with their
// price when known) and one warning per provider skipped, because one down
// provider must not block the picker. The requests are independent, so they
// run concurrently.
func ListCombos() ([]tools.ModelCombo, []string, error) {
	cfg, err := LoadConfig()
	if err != nil {
		return nil, nil, err
	}
	names := make([]string, 0, len(cfg.Providers))
	for name := range cfg.Providers {
		names = append(names, name)
	}
	sort.Strings(names)

	type result struct {
		lines []tools.ModelCombo
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
			ids, err := ListModels(ctx, name, strings.TrimRight(prov.BaseURL, "/"), os.Getenv(prov.APIKeyEnv))
			if err != nil {
				results[i].errs = append(results[i].errs, fmt.Sprintf("%s: %v", name, err))
				return
			}
			sort.Strings(ids)
			for _, id := range ids {
				results[i].lines = append(results[i].lines, ComboPrice(name, id))
			}
		}(i, name)
	}
	wg.Wait()

	var combos []tools.ModelCombo
	var warnings []string
	for _, r := range results {
		warnings = append(warnings, r.errs...)
		combos = append(combos, r.lines...)
	}
	return combos, warnings, nil
}

// comboPrice attaches the running price to a combo, mirroring the cost
// computation: the committed catalog is the single source of truth.
func ComboPrice(provider, model string) tools.ModelCombo {
	c := tools.ModelCombo{Name: provider + "/" + model}
	if info, ok := price.Lookup(provider, model); ok {
		c.Input, c.Output = info.Input, info.Output
	}
	return c
}

// listModels queries the provider's native model endpoint. Unknown providers
// use the conventional OpenAI-compatible GET base_url/models shape.
func ListModels(ctx context.Context, providerName, baseURL, apiKey string) ([]string, error) {
	var endpoint string
	switch providerName {
	case "openai":
		if baseURL == "" {
			baseURL = "https://api.openai.com/v1"
		}
		endpoint = baseURL + "/models"
	case "anthropic":
		if baseURL == "" {
			baseURL = "https://api.anthropic.com"
		}
		if strings.HasSuffix(baseURL, "/v1") {
			endpoint = baseURL + "/models"
		} else {
			endpoint = baseURL + "/v1/models"
		}
	case "google", "gemini":
		if baseURL == "" {
			baseURL = "https://generativelanguage.googleapis.com"
		}
		endpoint = baseURL + "/v1beta/models"
	case "deepseek":
		if baseURL == "" {
			baseURL = "https://api.deepseek.com"
		}
		endpoint = baseURL + "/models"
	default:
		if baseURL == "" {
			return nil, fmt.Errorf("no base_url")
		}
		endpoint = baseURL + "/models"
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "yap")
	switch providerName {
	case "anthropic":
		req.Header.Set("x-api-key", apiKey)
		req.Header.Set("anthropic-version", "2023-06-01")
	case "google", "gemini":
		req.Header.Set("x-goog-api-key", apiKey)
	default:
		if apiKey != "" {
			req.Header.Set("Authorization", "Bearer "+apiKey)
		}
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck // best-effort: close on read
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list models: HTTP %s", resp.Status)
	}

	if providerName == "google" || providerName == "gemini" {
		var out struct {
			Models []struct {
				Name string `json:"name"`
			} `json:"models"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil, fmt.Errorf("parse models: %w", err)
		}
		ids := make([]string, 0, len(out.Models))
		for _, m := range out.Models {
			id := strings.TrimPrefix(m.Name, "models/")
			if id != "" {
				ids = append(ids, id)
			}
		}
		return ids, nil
	}

	var out struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("parse models: %w", err)
	}
	ids := make([]string, 0, len(out.Data))
	for _, m := range out.Data {
		if m.ID != "" {
			ids = append(ids, m.ID)
		}
	}
	return ids, nil
}
