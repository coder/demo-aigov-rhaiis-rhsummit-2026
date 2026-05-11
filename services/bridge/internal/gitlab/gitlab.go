// Package gitlab is a minimal GitLab API client covering only what the
// bridge needs: posting a note (comment) back on the originating issue
// with the workspace + chat URLs after the bridge processes a label
// trigger.
package gitlab

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

type Client struct {
	apiURL string
	pat    string
	http   *http.Client
}

func New(apiURL, pat string, timeout time.Duration) *Client {
	return &Client{
		apiURL: apiURL,
		pat:    pat,
		http:   &http.Client{Timeout: timeout},
	}
}

type noteRequest struct {
	Body string `json:"body"`
}

// PostIssueComment posts a comment ("note") on the given issue. Returns the
// note URL on success.
func (c *Client) PostIssueComment(ctx context.Context, projectID, issueIID int, body string) error {
	path := fmt.Sprintf("/projects/%d/issues/%d/notes", projectID, issueIID)
	b, err := json.Marshal(noteRequest{Body: body})
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.apiURL+path, bytes.NewReader(b))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("PRIVATE-TOKEN", c.pat)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("http: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("gitlab notes POST status %d: %s", resp.StatusCode, string(body))
	}
	return nil
}

// IssueURL composes the canonical web URL for an issue. GitLab webhook
// payloads include `object_attributes.url` directly; this helper is a fallback
// when constructing the URL from parts.
func IssueURL(projectWebURL string, iid int) string {
	if projectWebURL == "" {
		return ""
	}
	return projectWebURL + "/-/issues/" + strconv.Itoa(iid)
}

// SafeEscape exposes url.PathEscape for callers that need it without importing
// the stdlib package separately.
func SafeEscape(s string) string { return url.PathEscape(s) }
