package webhook

import (
	"crypto/subtle"
	"errors"
	"regexp"
	"strconv"
	"strings"
)

// Payload mirrors the subset of GitLab's Issue Hook payload that we use.
// Full schema: https://docs.gitlab.com/ee/user/project/integrations/webhook_events.html#issue-events
type Payload struct {
	ObjectKind string `json:"object_kind"`
	// User is the actor who triggered the webhook (top-level field per GitLab docs).
	// We use this as the workspace owner since GitLab usernames == Coder usernames via Keycloak.
	User struct {
		Username string `json:"username"`
	} `json:"user"`
	Project struct {
		PathWithNamespace string `json:"path_with_namespace"`
	} `json:"project"`
	ObjectAttributes struct {
		IID    int    `json:"iid"`
		Action string `json:"action"`
		Title  string `json:"title"`
		State  string `json:"state"`
	} `json:"object_attributes"`
	// Labels appear at top-level and under object_attributes; we use top-level since
	// it's the canonical list per docs.
	Labels []Label `json:"labels"`
}

type Label struct {
	Title string `json:"title"`
}

var templateLabelRE = regexp.MustCompile(`^template:(.+)$`)

// ExtractTemplate returns the template name from the first matching label, or "" if none.
func ExtractTemplate(labels []Label) string {
	for _, l := range labels {
		m := templateLabelRE.FindStringSubmatch(strings.TrimSpace(l.Title))
		if len(m) == 2 {
			return strings.TrimSpace(m[1])
		}
	}
	return ""
}

var allowedActions = map[string]bool{
	"open":   true,
	"update": true,
	"reopen": true,
}

// IsActionable reports whether the payload should trigger workspace logic.
// Returns the reason for skipping if not actionable.
func (p *Payload) IsActionable() (ok bool, reason string) {
	if p.ObjectKind != "issue" {
		return false, "not an issue event"
	}
	if !allowedActions[p.ObjectAttributes.Action] {
		return false, "action not in {open,update,reopen}"
	}
	return true, ""
}

// VerifyToken does a constant-time compare of the GitLab webhook token.
// GitLab sends the configured secret verbatim in X-Gitlab-Token (no HMAC).
func VerifyToken(got, want string) error {
	if want == "" {
		return errors.New("server webhook secret not configured")
	}
	if subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
		return errors.New("invalid webhook token")
	}
	return nil
}

var nameSanitizeRE = regexp.MustCompile(`[^a-z0-9-]+`)

// WorkspaceName derives a deterministic Coder workspace name from a username and issue IID.
// Coder enforces a 32-char limit and [a-z0-9-] charset; we truncate after sanitization.
func WorkspaceName(username string, iid int) string {
	base := strings.ToLower(username) + "-gl" + strconv.Itoa(iid)
	base = nameSanitizeRE.ReplaceAllString(base, "-")
	base = strings.Trim(base, "-")
	if len(base) > 32 {
		base = base[:32]
		base = strings.TrimRight(base, "-")
	}
	return base
}
