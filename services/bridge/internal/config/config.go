package config

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

type Config struct {
	ListenAddr      string
	CoderURL        string // in-cluster URL used for API calls
	CoderPublicURL  string // external URL used to build user-facing workspace + chat links
	CoderToken      string // admin token; used for user/workspace lookups + minting per-user tokens
	WebhookSecret   string // GitLab → bridge shared secret (X-Gitlab-Token)
	LogLevel        string
	DefaultTemplate string // Coder template name to use when an issue triggers (project-level override TBD)
	GitLabAPIURL    string // e.g. https://gitlab.rhsummit.coderdemo.io/api/v4
	GitLabPAT       string // long-lived admin PAT used to post issue comments
}

func Load() (*Config, error) {
	c := &Config{
		ListenAddr:      getenv("BRIDGE_LISTEN_ADDR", ":8080"),
		CoderURL:        strings.TrimRight(os.Getenv("CODER_URL"), "/"),
		CoderPublicURL:  strings.TrimRight(os.Getenv("CODER_PUBLIC_URL"), "/"),
		CoderToken:      os.Getenv("CODER_TOKEN"),
		WebhookSecret:   os.Getenv("BRIDGE_WEBHOOK_SECRET"),
		LogLevel:        getenv("LOG_LEVEL", "info"),
		DefaultTemplate: getenv("DEFAULT_TEMPLATE", "ai-dev-ocp"),
		GitLabAPIURL:    strings.TrimRight(os.Getenv("GITLAB_API_URL"), "/"),
		GitLabPAT:       os.Getenv("GITLAB_BRIDGE_PAT"),
	}
	// Fall back to in-cluster URL if public not set — works for smoke tests
	// even if the response link isn't booth-clickable.
	if c.CoderPublicURL == "" {
		c.CoderPublicURL = c.CoderURL
	}

	var missing []string
	if c.CoderURL == "" {
		missing = append(missing, "CODER_URL")
	}
	if c.CoderToken == "" {
		missing = append(missing, "CODER_TOKEN")
	}
	if c.WebhookSecret == "" {
		missing = append(missing, "BRIDGE_WEBHOOK_SECRET")
	}
	if c.GitLabAPIURL == "" {
		missing = append(missing, "GITLAB_API_URL")
	}
	if c.GitLabPAT == "" {
		missing = append(missing, "GITLAB_BRIDGE_PAT")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("missing required env vars: %s", strings.Join(missing, ", "))
	}
	if !strings.HasPrefix(c.CoderURL, "http://") && !strings.HasPrefix(c.CoderURL, "https://") {
		return nil, errors.New("CODER_URL must include scheme (http:// or https://)")
	}
	return c, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
