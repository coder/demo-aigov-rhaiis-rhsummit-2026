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
	ID           string `json:"id"`
	Name         string `json:"name"`
	OwnerID      string `json:"owner_id"`
	OwnerName    string `json:"owner_name"`
	TemplateID   string `json:"template_id"`
	TemplateName string `json:"template_name"`
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
	req.Header.Set("Coder-Session-Token", c.token)
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
