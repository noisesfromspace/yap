package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

// models lists the provider/model combos available in the config by
// querying each provider's OpenAI-compatible GET /models endpoint — one
// "provider/model" per line on stdout. Providers that fail are skipped
// with a warning on stderr: one down provider must not block the picker.
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
	for _, name := range names {
		prov := cfg.Providers[name]
		req, err := http.NewRequest("GET", strings.TrimSuffix(prov.BaseURL, "/")+"/models", nil)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pitel: %s: %v\n", name, err)
			continue
		}
		if key := os.Getenv(prov.APIKeyEnv); key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		resp, err := client.Do(req)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pitel: %s: %v\n", name, err)
			continue
		}
		var list struct {
			Data []struct {
				ID string `json:"id"`
			} `json:"data"`
		}
		derr := json.NewDecoder(resp.Body).Decode(&list)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK || derr != nil {
			fmt.Fprintf(os.Stderr, "pitel: %s: GET /models: %s\n", name, resp.Status)
			continue
		}
		ids := make([]string, 0, len(list.Data))
		for _, m := range list.Data {
			ids = append(ids, m.ID)
		}
		sort.Strings(ids)
		for _, id := range ids {
			fmt.Println(name + "/" + id)
		}
	}
	return nil
}
