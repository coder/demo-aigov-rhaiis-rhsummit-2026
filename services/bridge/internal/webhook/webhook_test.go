package webhook

import "testing"

func TestExtractTemplate(t *testing.T) {
	tests := []struct {
		name   string
		labels []Label
		want   string
	}{
		{"no labels", nil, ""},
		{"no template label", []Label{{Title: "bug"}, {Title: "priority:high"}}, ""},
		{"basic match", []Label{{Title: "template:python-data"}}, "python-data"},
		{"first match wins", []Label{{Title: "template:rust"}, {Title: "template:go"}}, "rust"},
		{"trims whitespace", []Label{{Title: "  template:web  "}}, "web"},
		{"case sensitive prefix", []Label{{Title: "Template:foo"}}, ""},
		{"empty capture", []Label{{Title: "template:"}}, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ExtractTemplate(tc.labels)
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
		})
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
