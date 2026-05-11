package handler

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/coder"
	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/config"
	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/gitlab"
	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/webhook"
)

type Handler struct {
	cfg    *config.Config
	coder  *coder.Client
	gitlab *gitlab.Client
	logger *slog.Logger
}

func New(cfg *config.Config, c *coder.Client, gl *gitlab.Client, logger *slog.Logger) *Handler {
	return &Handler{cfg: cfg, coder: c, gitlab: gl, logger: logger}
}

func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("/webhook", h.handleWebhook)
	mux.HandleFunc("/healthz", h.handleHealth)
	mux.HandleFunc("/readyz", h.handleReady)
}

func (h *Handler) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *Handler) handleReady(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := h.coder.Ping(ctx); err != nil {
		h.logger.Warn("readyz: coder unreachable", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (h *Handler) handleWebhook(w http.ResponseWriter, r *http.Request) {
	reqID := newRequestID()
	log := h.logger.With("request_id", reqID)

	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
		return
	}

	if err := webhook.VerifyToken(r.Header.Get("X-Gitlab-Token"), h.cfg.WebhookSecret); err != nil {
		log.Warn("webhook auth failed", "err", err, "remote", r.RemoteAddr)
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "unauthorized"})
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		log.Warn("read body failed", "err", err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "read body"})
		return
	}

	var p webhook.Payload
	if err := json.Unmarshal(body, &p); err != nil {
		log.Warn("decode payload failed", "err", err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid json"})
		return
	}

	log = log.With(
		"object_kind", p.ObjectKind,
		"action", p.ObjectAttributes.Action,
		"iid", p.ObjectAttributes.IID,
		"project", p.Project.PathWithNamespace,
		"actor", p.User.Username,
	)

	if ok, reason := p.IsActionable(); !ok {
		log.Info("noop: not actionable", "reason", reason)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "action": "noop", "reason": reason})
		return
	}

	// Both conditions must be true for spawn: a coder-* label AND an
	// assignee. Either alone is a noop — order doesn't matter, whichever
	// webhook event satisfies both conditions triggers the spawn. Repeat
	// events after that hit the workspace-exists idempotency check below.
	mode, modelSlug := webhook.ExtractMode(p.Labels)
	if mode == webhook.ModeNone {
		log.Info("noop: no coder-{hitl,agent} label")
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "action": "noop",
			"reason": "no coder-{hitl,agent} label",
		})
		return
	}
	assignee := p.FirstAssignee()
	if assignee == "" {
		log.Info("noop: no assignee (author is typically a PM, not the worker)")
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "action": "noop",
			"reason": "no assignee — assign the issue to trigger spawn",
		})
		return
	}
	log = log.With("mode", string(mode), "assignee", assignee, "model_slug", modelSlug)

	wsName := webhook.WorkspaceName(assignee, p.ObjectAttributes.IID)
	log = log.With("workspace", wsName)

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	// 1. Confirm the assignee exists in Coder.
	user, err := h.coder.GetUser(ctx, assignee)
	if err != nil {
		if errors.Is(err, coder.ErrNotFound) {
			log.Warn("coder user not found")
			writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
				"ok":    false,
				"error": "coder user not found: " + assignee + " — sign in to Coder via Keycloak first",
			})
			return
		}
		h.forwardCoderError(w, log, "lookup user", err)
		return
	}

	// 2. Already-created idempotency check.
	if existing, err := h.coder.GetWorkspaceByName(ctx, assignee, wsName); err == nil {
		log.Info("workspace exists, no-op", "workspace_id", existing.ID)
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":             true,
			"action":         "noop",
			"reason":         "workspace exists",
			"workspace_name": existing.Name,
		})
		return
	} else if !errors.Is(err, coder.ErrNotFound) {
		h.forwardCoderError(w, log, "lookup workspace", err)
		return
	}

	// 3. Resolve the template. Default to cfg.DefaultTemplate; project-
	// level override (GitLab CI variable / .coder file) is a TODO.
	templates, err := h.coder.ListTemplates(ctx)
	if err != nil {
		h.forwardCoderError(w, log, "list templates", err)
		return
	}
	var tmpl *coder.Template
	for i := range templates {
		if templates[i].Name == h.cfg.DefaultTemplate {
			tmpl = &templates[i]
			break
		}
	}
	if tmpl == nil {
		log.Warn("default template not found", "template", h.cfg.DefaultTemplate)
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"ok":    false,
			"error": "default template not found in coder: " + h.cfg.DefaultTemplate,
		})
		return
	}

	// 4. Create the workspace.
	created, err := h.coder.CreateWorkspace(ctx, assignee, coder.CreateWorkspaceRequest{
		TemplateID: tmpl.ID,
		Name:       wsName,
	})
	if err != nil {
		h.forwardCoderError(w, log, "create workspace", err)
		return
	}
	wsURL := h.cfg.CoderPublicURL + "/@" + assignee + "/" + created.Name
	log = log.With("workspace_id", created.ID)
	log.Info("workspace created")

	// 5. Compose the issue URL — prefer the payload-provided one, fall
	// back to constructed.
	issueURL := p.ObjectAttributes.URL
	if issueURL == "" {
		issueURL = gitlab.IssueURL(p.Project.WebURL, p.ObjectAttributes.IID)
	}

	resp := map[string]any{
		"ok":             true,
		"action":         "created",
		"mode":           string(mode),
		"workspace_name": created.Name,
		"workspace_url":  wsURL,
	}

	// 6. For coder-agent, resolve the model slug then create a chat
	// owned by the assignee.
	if mode == webhook.ModeAgent {
		modelID, slugErr := h.resolveModelSlug(ctx, modelSlug)
		if slugErr != nil {
			log.Warn("unknown model slug", "slug", modelSlug, "err", slugErr)
			resp["chat_error"] = slugErr.Error()
		} else {
			chatURL, chatErr := h.spawnAgentChat(ctx, assignee, created.OrganizationID, created.ID, modelID, issueURL, log)
			if chatErr != nil {
				log.Error("chat creation failed", "err", chatErr)
				resp["chat_error"] = chatErr.Error()
			} else {
				resp["chat_url"] = chatURL
				if modelID != "" {
					resp["model_config_id"] = modelID
				}
			}
		}
	}

	// 7. Comment back on the GitLab issue.
	go h.commentBack(p.Project.ID, p.ObjectAttributes.IID, mode, wsURL, resp["chat_url"], resp["chat_error"], log)

	_ = user // keep the user lookup result for future use (display name in comments, etc.)
	writeJSON(w, http.StatusCreated, resp)
}

// resolveModelSlug maps a label-supplied slug ("llama", "sonnet", ...) to
// the UUID of a chatd model config. Empty slug → empty UUID, which makes
// chatd use the deployment default. Unknown slug → error so the handler
// can surface it to the operator without spawning a chat on the wrong
// model.
func (h *Handler) resolveModelSlug(ctx context.Context, slug string) (string, error) {
	if slug == "" {
		return "", nil
	}
	mcs, err := h.coder.ListModelConfigs(ctx)
	if err != nil {
		return "", fmt.Errorf("list model configs: %w", err)
	}
	// Case-insensitive substring match against display_name. First
	// matching enabled config wins. Allows aliases like "llama" to
	// hit "Llama 3.3 70B Instruct INT4 (RHAIIS sovereign)" without
	// requiring an exact mapping table.
	needle := strings.ToLower(slug)
	for _, m := range mcs {
		if !m.Enabled {
			continue
		}
		if strings.Contains(strings.ToLower(m.DisplayName), needle) {
			return m.ID, nil
		}
	}
	return "", fmt.Errorf("unknown model slug %q (no enabled chatd model has %q in its display name)", slug, slug)
}

// spawnAgentChat mints a per-user token for the assignee (admin token can't
// create chats with a different owner — chatd hardcodes owner_id from the
// caller), then POSTs the chat with the issue-URL seed prompt. modelID is
// optional ("" leaves it to chatd's deployment default).
func (h *Handler) spawnAgentChat(ctx context.Context, username, orgID, workspaceID, modelID, issueURL string, log *slog.Logger) (string, error) {
	userToken, err := h.coder.MintUserToken(ctx, username, 3600) // 1h plenty for chat create
	if err != nil {
		return "", fmt.Errorf("mint user token: %w", err)
	}
	chat, err := h.coder.CreateChat(ctx, userToken, coder.CreateChatRequest{
		OrganizationID: orgID,
		WorkspaceID:    workspaceID,
		ModelConfigID:  modelID,
		Content: []coder.ChatInputPart{{
			Type: "text",
			Text: "Go work on this GitLab issue: " + issueURL +
				". Investigate the request, make the needed changes in the workspace's repo, " +
				"and when you're done push a branch and open a Merge Request.",
		}},
	})
	if err != nil {
		return "", fmt.Errorf("create chat: %w", err)
	}
	log.Info("chat created", "chat_id", chat.ID)
	return h.cfg.CoderPublicURL + "/agents/chats/" + chat.ID, nil
}

// commentBack posts a comment back on the GitLab issue. Best-effort, fires
// in a goroutine; logs failures but doesn't surface them in the HTTP response.
func (h *Handler) commentBack(projectID, iid int, mode webhook.Mode, wsURL string, chatURL, chatErr any, log *slog.Logger) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	var body string
	switch mode {
	case webhook.ModeHITL:
		body = "🛠️ Workspace ready: " + wsURL + "\n\n_Open it and start working._"
	case webhook.ModeAgent:
		body = "🤖 Coder agent dispatched.\n\n- **Workspace:** " + wsURL
		if s, ok := chatURL.(string); ok {
			body += "\n- **Chat:** " + s
		}
		if s, ok := chatErr.(string); ok {
			body += "\n- ⚠️ Chat creation failed: " + s
		}
	}
	body += "\n\n_Posted by the GitLab → Coder bridge._"

	if err := h.gitlab.PostIssueComment(ctx, projectID, iid, body); err != nil {
		log.Error("issue comment failed", "err", err)
	}
}

func (h *Handler) forwardCoderError(w http.ResponseWriter, log *slog.Logger, op string, err error) {
	var apiErr *coder.APIError
	if errors.As(err, &apiErr) {
		log.Error("coder api error", "op", op, "status", apiErr.Status, "body", string(apiErr.Body))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(apiErr.Status)
		if json.Valid(apiErr.Body) {
			_, _ = w.Write(apiErr.Body)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok":     false,
			"error":  op + " failed",
			"detail": string(apiErr.Body),
		})
		return
	}
	log.Error("coder call failed", "op", op, "err", err)
	writeJSON(w, http.StatusBadGateway, map[string]any{
		"ok":    false,
		"error": op + " failed: " + err.Error(),
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func newRequestID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

