package coder

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// Client is a minimal Coder API client covering only the four calls the bridge needs.
type Client struct {
	baseURL string
	token   string
	http    *http.Client
}

func New(baseURL, token string, timeout time.Duration) *Client {
	return &Client{
		baseURL: baseURL,
		token:   token,
		http:    &http.Client{Timeout: timeout},
	}
}

type User struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
}

type Template struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	DisplayName    string `json:"display_name"`
	OrganizationID string `json:"organization_id"`
}

type Workspace struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	OwnerID        string `json:"owner_id"`
	OwnerName      string `json:"owner_name"`
	OrganizationID string `json:"organization_id"`
	TemplateID     string `json:"template_id"`
	TemplateName   string `json:"template_name"`
}

// MintTokenRequest creates a per-user API token; admin-token authenticated
// caller can mint on behalf of {user}. POST /api/v2/users/{user}/keys/tokens.
type MintTokenRequest struct {
	TokenName string `json:"token_name"`
	Lifetime  int64  `json:"lifetime"` // nanoseconds
	Scope     string `json:"scope,omitempty"`
}

type MintTokenResponse struct {
	Key string `json:"key"`
}

// CreateChatRequest body for POST /api/experimental/chats.
// Wire format from codersdk.CreateChatRequest (subagent research).
type CreateChatRequest struct {
	OrganizationID string          `json:"organization_id"`
	WorkspaceID    string          `json:"workspace_id,omitempty"`
	ModelConfigID  string          `json:"model_config_id,omitempty"`
	Content        []ChatInputPart `json:"content"`
	ClientType     string          `json:"client_type,omitempty"`
}

// ModelConfig is a chatd model entry from /api/experimental/chats/model-configs.
type ModelConfig struct {
	ID          string `json:"id"`
	Provider    string `json:"provider"`
	Model       string `json:"model"`
	DisplayName string `json:"display_name"`
	Enabled     bool   `json:"enabled"`
	IsDefault   bool   `json:"is_default"`
}

type ChatInputPart struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

type Chat struct {
	ID             string `json:"id"`
	OrganizationID string `json:"organization_id"`
	OwnerID        string `json:"owner_id"`
	WorkspaceID    string `json:"workspace_id"`
	Title          string `json:"title"`
}

type CreateWorkspaceRequest struct {
	TemplateID string `json:"template_id"`
	Name       string `json:"name"`
}

// APIError carries the upstream Coder status + body so the handler can forward it.
type APIError struct {
	Status int
	Body   []byte
}

func (e *APIError) Error() string {
	return fmt.Sprintf("coder api: status=%d body=%s", e.Status, string(e.Body))
}

// ErrNotFound is returned when an entity doesn't exist (HTTP 404).
var ErrNotFound = errors.New("coder: not found")

func (c *Client) do(ctx context.Context, method, path string, body any, out any) error {
	return c.doWithToken(ctx, c.token, method, path, body, out)
}

// doWithToken is like do but uses the supplied token instead of the client's
// admin token. Used for chat creation calls that must run as the target user
// (chatd hardcodes owner_id = caller's user; see decisions §32 followup).
func (c *Client) doWithToken(ctx context.Context, token, method, path string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshal request: %w", err)
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, reader)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Coder-Session-Token", token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("http: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode == http.StatusNotFound {
		return ErrNotFound
	}
	if resp.StatusCode >= 400 {
		return &APIError{Status: resp.StatusCode, Body: respBody}
	}
	if out != nil && len(respBody) > 0 {
		if err := json.Unmarshal(respBody, out); err != nil {
			return fmt.Errorf("decode response: %w", err)
		}
	}
	return nil
}

func (c *Client) GetUser(ctx context.Context, username string) (*User, error) {
	var u User
	if err := c.do(ctx, http.MethodGet, "/api/v2/users/"+url.PathEscape(username), nil, &u); err != nil {
		return nil, err
	}
	return &u, nil
}

func (c *Client) GetWorkspaceByName(ctx context.Context, username, name string) (*Workspace, error) {
	var w Workspace
	path := "/api/v2/users/" + url.PathEscape(username) + "/workspace/" + url.PathEscape(name)
	if err := c.do(ctx, http.MethodGet, path, nil, &w); err != nil {
		return nil, err
	}
	return &w, nil
}

func (c *Client) ListTemplates(ctx context.Context) ([]Template, error) {
	var ts []Template
	if err := c.do(ctx, http.MethodGet, "/api/v2/templates", nil, &ts); err != nil {
		return nil, err
	}
	return ts, nil
}

func (c *Client) CreateWorkspace(ctx context.Context, username string, req CreateWorkspaceRequest) (*Workspace, error) {
	var w Workspace
	path := "/api/v2/users/" + url.PathEscape(username) + "/workspaces"
	if err := c.do(ctx, http.MethodPost, path, req, &w); err != nil {
		return nil, err
	}
	return &w, nil
}

// ListModelConfigs returns the enabled model configurations registered in
// chatd. Used by the bridge to resolve a label-supplied slug ("llama",
// "sonnet") to a concrete model_config_id.
func (c *Client) ListModelConfigs(ctx context.Context) ([]ModelConfig, error) {
	var mcs []ModelConfig
	if err := c.do(ctx, http.MethodGet, "/api/experimental/chats/model-configs", nil, &mcs); err != nil {
		return nil, err
	}
	return mcs, nil
}

// MintUserToken creates a short-lived API token for {username} on behalf of
// the admin caller. Used to then create a chat as that user.
func (c *Client) MintUserToken(ctx context.Context, username string, lifetimeSeconds int64) (string, error) {
	req := MintTokenRequest{
		TokenName: "bridge-jit-" + fmt.Sprint(time.Now().UnixNano()),
		Lifetime:  lifetimeSeconds * int64(time.Second),
	}
	var resp MintTokenResponse
	if err := c.do(ctx, http.MethodPost,
		"/api/v2/users/"+url.PathEscape(username)+"/keys/tokens", req, &resp); err != nil {
		return "", err
	}
	return resp.Key, nil
}

// CreateChat creates a new chat session AS the supplied user (uses userToken,
// NOT the admin token — chatd hardcodes owner_id = caller's user). Returns
// the chat ID.
func (c *Client) CreateChat(ctx context.Context, userToken string, req CreateChatRequest) (*Chat, error) {
	if req.ClientType == "" {
		req.ClientType = "api"
	}
	var chat Chat
	if err := c.doWithToken(ctx, userToken, http.MethodPost,
		"/api/experimental/chats", req, &chat); err != nil {
		return nil, err
	}
	return &chat, nil
}

// Ping checks Coder reachability for readiness probes.
func (c *Client) Ping(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/api/v2/buildinfo", nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 500 {
		return fmt.Errorf("coder buildinfo status %d", resp.StatusCode)
	}
	return nil
}
