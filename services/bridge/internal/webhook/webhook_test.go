package webhook

import "testing"

func TestExtractMode(t *testing.T) {
	tests := []struct {
		name   string
		labels []Label
		want   Mode
	}{
		{"no labels", nil, ModeNone},
		{"unrelated", []Label{{Title: "bug"}, {Title: "priority:high"}}, ModeNone},
		{"hitl only", []Label{{Title: "coder-hitl"}}, ModeHITL},
		{"agent only", []Label{{Title: "coder-agent"}}, ModeAgent},
		{"both → agent wins", []Label{{Title: "coder-hitl"}, {Title: "coder-agent"}}, ModeAgent},
		{"trims whitespace", []Label{{Title: "  coder-agent  "}}, ModeAgent},
		{"prefix-only doesn't match", []Label{{Title: "coder-hitl-x"}}, ModeNone},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ExtractMode(tc.labels)
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
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
		username string
		iid      int
		want     string
	}{
		{"simple", "alice", 7, "alice-gl7"},
		{"uppercase lowered", "Alice", 12, "alice-gl12"},
		{"dots sanitized", "alice.smith", 3, "alice-smith-gl3"},
		{"long username truncated", "averyveryveryveryverylongusernameindeed", 42, "averyveryveryveryverylongusernam"},
		{"trailing dash trimmed after truncation", "abcdefghijabcdefghijabcdefghijx", 1, "abcdefghijabcdefghijabcdefghijx"},
		{"underscores sanitized", "user_one", 5, "user-one-gl5"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := WorkspaceName(tc.username, tc.iid)
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
			if len(got) > 32 {
				t.Errorf("name %q exceeds 32 chars", got)
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
