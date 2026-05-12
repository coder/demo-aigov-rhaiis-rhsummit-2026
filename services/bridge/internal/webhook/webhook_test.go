package webhook

import "testing"

func TestExtractMode(t *testing.T) {
	tests := []struct {
		name     string
		labels   []Label
		wantMode Mode
		wantSlug string
	}{
		{"no labels", nil, ModeNone, ""},
		{"unrelated", []Label{{Title: "bug"}, {Title: "priority:high"}}, ModeNone, ""},
		{"workspace only", []Label{{Title: "coder-workspace"}}, ModeWorkspace, ""},
		{"workspace with slug", []Label{{Title: "coder-workspace:artemis-sim-dev-ocp"}}, ModeWorkspace, "artemis-sim-dev-ocp"},
		{"workspace slug invalid suffix", []Label{{Title: "coder-workspace:foo bar"}}, ModeNone, ""},
		{"workspace slug uppercase rejected", []Label{{Title: "coder-workspace:AI-Dev-OCP"}}, ModeNone, ""},
		{"agent no slug", []Label{{Title: "coder-agent"}}, ModeAgent, ""},
		{"agent llama slug", []Label{{Title: "coder-agent:llama"}}, ModeAgent, "llama"},
		{"agent sonnet slug", []Label{{Title: "coder-agent:sonnet"}}, ModeAgent, "sonnet"},
		{"agent uppercase slug rejected", []Label{{Title: "coder-agent:Llama"}}, ModeNone, ""},
		{"both → agent wins", []Label{{Title: "coder-workspace"}, {Title: "coder-agent:opus"}}, ModeAgent, "opus"},
		{"both with slugs → agent wins", []Label{{Title: "coder-workspace:ai-dev-ocp"}, {Title: "coder-agent:opus"}}, ModeAgent, "opus"},
		{"trims whitespace", []Label{{Title: "  coder-agent  "}}, ModeAgent, ""},
		{"workspace prefix-only doesn't match", []Label{{Title: "coder-workspace-x"}}, ModeNone, ""},
		{"agent with invalid suffix char doesn't match agent", []Label{{Title: "coder-agent:foo bar"}}, ModeNone, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mode, slug := ExtractMode(tc.labels)
			if mode != tc.wantMode || slug != tc.wantSlug {
				t.Errorf("got (%q,%q) want (%q,%q)", mode, slug, tc.wantMode, tc.wantSlug)
			}
		})
	}
}

func TestFirstAssignee(t *testing.T) {
	var empty Payload
	if got := empty.FirstAssignee(); got != "" {
		t.Errorf("empty assignees should return empty string, got %q", got)
	}
	p := Payload{Assignees: []Assignee{{Username: "alice"}, {Username: "bob"}}}
	if got := p.FirstAssignee(); got != "alice" {
		t.Errorf("first assignee should win, got %q", got)
	}
}

func TestWorkspaceName(t *testing.T) {
	tests := []struct {
		name     string
		repoPath string
		iid      int
		want     string
	}{
		{"simple", "alice/artemis-sim", 7, "artemis-sim-issue-7"},
		{"uppercase lowered", "Demo/ProjectName", 12, "projectname-issue-12"},
		{"dots sanitized to dashes", "group/sub-group/repo.with.dots", 3, "repo-with-dots-issue-3"},
		{"underscores sanitized", "alice/user_one", 5, "user-one-issue-5"},
		{"long repo truncated, suffix preserved", "group/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 99, "aaaaaaaaaaaaaaaaaaaaaaa-issue-99"},
		{"long repo, large iid, suffix preserved", "group/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 12345, "aaaaaaaaaaaaaaaaaaaa-issue-12345"},
		{"no namespace, just repo", "artemis-sim", 8, "artemis-sim-issue-8"},
		{"empty path → just issue suffix", "", 4, "issue-4"},
		{"trailing dash trimmed after truncation", "ns/aaaaaaaaaaaaaaaaaaaaaaa-bbbbb", 1, "aaaaaaaaaaaaaaaaaaaaaaa-issue-1"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := WorkspaceName(tc.repoPath, tc.iid)
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
			if len(got) > 32 {
				t.Errorf("name %q exceeds 32 chars (len=%d)", got, len(got))
			}
		})
	}
}

func TestVerifyToken(t *testing.T) {
	if err := VerifyToken("secret", "secret"); err != nil {
		t.Errorf("matching tokens should pass: %v", err)
	}
	if err := VerifyToken("wrong", "secret"); err == nil {
		t.Error("mismatched tokens should fail")
	}
	if err := VerifyToken("anything", ""); err == nil {
		t.Error("empty server secret should fail")
	}
	if err := VerifyToken("", "secret"); err == nil {
		t.Error("empty client token should fail")
	}
}

func TestIsActionable(t *testing.T) {
	tests := []struct {
		kind   string
		action string
		want   bool
	}{
		{"issue", "open", true},
		{"issue", "update", true},
		{"issue", "reopen", true},
		{"issue", "close", false},
		{"merge_request", "open", false},
		{"issue", "", false},
	}
	for _, tc := range tests {
		var p Payload
		p.ObjectKind = tc.kind
		p.ObjectAttributes.Action = tc.action
		got, _ := p.IsActionable()
		if got != tc.want {
			t.Errorf("kind=%q action=%q got %v want %v", tc.kind, tc.action, got, tc.want)
		}
	}
}
