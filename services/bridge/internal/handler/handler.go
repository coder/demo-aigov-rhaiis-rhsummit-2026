package handler

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/coder"
	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/config"
	"github.com/coder/demo-aigov-rhaiis-rhsummit-2026/services/bridge/internal/webhook"
)

type Handler struct {
	cfg    *config.Config
	coder  *coder.Client
	logger *slog.Logger
}

func New(cfg *config.Config, c *coder.Client, logger *slog.Logger) *Handler {
	return &Handler{cfg: cfg, coder: c, logger: logger}
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
		"username", p.User.Username,
	)

	if ok, reason := p.IsActionable(); !ok {
		log.Info("noop: not actionable", "reason", reason)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "action": "noop", "reason": reason})
		return
	}

	tmplName := webhook.ExtractTemplate(p.Labels)
	if tmplName == "" {
		log.Info("noop: no template label")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "action": "noop", "reason": "no template label"})
		return
	}
	log = log.With("template", tmplName)

	if p.User.Username == "" {
		log.Warn("payload missing user.username")
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "payload missing user.username"})
		return
	}

	wsName := webhook.WorkspaceName(p.User.Username, p.ObjectAttributes.IID)
	log = log.With("workspace", wsName)

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	if _, err := h.coder.GetUser(ctx, p.User.Username); err != nil {
		if errors.Is(err, coder.ErrNotFound) {
			log.Warn("coder user not found")
			writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
				"ok":    false,
				"error": "coder user not found: " + p.User.Username,
			})
			return
		}
		h.forwardCoderError(w, log, "lookup user", err)
		return
	}

	if existing, err := h.coder.GetWorkspaceByName(ctx, p.User.Username, wsName); err == nil {
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

	templates, err := h.coder.ListTemplates(ctx)
	if err != nil {
		h.forwardCoderError(w, log, "list templates", err)
		return
	}
	var tmpl *coder.Template
	for i := range templates {
		if templates[i].Name == tmplName {
			tmpl = &templates[i]
			break
		}
	}
	if tmpl == nil {
		log.Warn("template not found in coder")
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"ok":    false,
			"error": "template not found: " + tmplName,
		})
		return
	}

	created, err := h.coder.CreateWorkspace(ctx, p.User.Username, coder.CreateWorkspaceRequest{
		TemplateID: tmpl.ID,
		Name:       wsName,
	})
	if err != nil {
		h.forwardCoderError(w, log, "create workspace", err)
		return
	}

	wsURL := h.cfg.CoderPublicURL + "/@" + p.User.Username + "/" + created.Name
	log.Info("workspace created", "workspace_id", created.ID)
	writeJSON(w, http.StatusCreated, map[string]any{
		"ok":             true,
		"action":         "created",
		"workspace_name": created.Name,
		"workspace_url":  wsURL,
	})
}

func (h *Handler) forwardCoderError(w http.ResponseWriter, log *slog.Logger, op string, err error) {
	var apiErr *coder.APIError
	if errors.As(err, &apiErr) {
		log.Error("coder api error", "op", op, "status", apiErr.Status, "body", string(apiErr.Body))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(apiErr.Status)
		// Pass through body verbatim if it's valid JSON; otherwise wrap.
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
