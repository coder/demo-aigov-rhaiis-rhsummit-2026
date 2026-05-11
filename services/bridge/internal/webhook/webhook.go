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
	// User is the actor who triggered the webhook. Not necessarily the
	// assignee — issue authors are often PMs. We do NOT use this as the
	// workspace owner; we use the assignee instead.
	User struct {
		Username string `json:"username"`
	} `json:"user"`
	Project struct {
		ID                int    `json:"id"`
		PathWithNamespace string `json:"path_with_namespace"`
		WebURL            string `json:"web_url"`
	} `json:"project"`
	ObjectAttributes struct {
		IID    int    `json:"iid"`
		Action string `json:"action"`
		Title  string `json:"title"`
		State  string `json:"state"`
		URL    string `json:"url"`
	} `json:"object_attributes"`
	// Top-level assignees list. GitLab issues can have multiple
	// assignees; we use the first one as the workspace owner.
	Assignees []Assignee `json:"assignees"`
	// Labels appear at top-level and under object_attributes; we use top-level since
	// it's the canonical list per docs.
	Labels []Label `json:"labels"`
}

type Assignee struct {
	Username string `json:"username"`
	Name     string `json:"name"`
}

type Label struct {
	Title string `json:"title"`
}

// Mode is the action the bridge should take for an issue.
type Mode string

const (
	ModeNone  Mode = ""
	ModeHITL  Mode = "coder-hitl"  // create workspace, owner opens it
	ModeAgent Mode = "coder-agent" // create workspace + autonomous chat
)

// agentLabelRE matches the `coder-agent` label with an optional `:<slug>`
// suffix selecting which model the bridge should pin the chat to.
//   coder-agent              → ("coder-agent", "")
//   coder-agent:llama        → ("coder-agent", "llama")
//   coder-agent:sonnet       → ("coder-agent", "sonnet")
// Unknown slugs are surfaced by the handler at chat-creation time.
var agentLabelRE = regexp.MustCompile(`^coder-agent(?::([a-z0-9._-]+))?$`)

// ExtractMode scans labels for coder-hitl or coder-agent(:slug). If both
// modes are present, agent wins. Returns the mode and an optional model
// slug (empty when no slug was supplied or in HITL mode).
func ExtractMode(labels []Label) (Mode, string) {
	var hitl bool
	for _, l := range labels {
		t := strings.TrimSpace(l.Title)
		if m := agentLabelRE.FindStringSubmatch(t); m != nil {
			return ModeAgent, strings.ToLower(strings.TrimSpace(m[1]))
		}
		if t == string(ModeHITL) {
			hitl = true
		}
	}
	if hitl {
		return ModeHITL, ""
	}
	return ModeNone, ""
}

// FirstAssignee returns the username of the first assignee, or "" if none.
func (p *Payload) FirstAssignee() string {
	if len(p.Assignees) == 0 {
		return ""
	}
	return strings.TrimSpace(p.Assignees[0].Username)
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
