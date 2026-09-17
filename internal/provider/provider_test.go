package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestEndpoint(t *testing.T) {
	for _, base := range []string{"https://example.com/v1", "https://example.com/v1/", "https://example.com/v1/chat/completions"} {
		got, err := (Config{BaseURL: base}).Endpoint()
		if err != nil || got != "https://example.com/v1/chat/completions" {
			t.Fatalf("%s => %s %v", base, got, err)
		}
	}
	for _, base := range []string{"http://example.com/v1", "https://secret@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/a"} {
		if _, err := (Config{BaseURL: base}).Endpoint(); err == nil {
			t.Fatalf("accepted invalid endpoint %s", base)
		}
	}
}
func TestLiteralProtectionAndRequest(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer test-only-key" {
			t.Error("incorrect request")
		}
		var body struct {
			Model    string                           `json:"model"`
			Messages []struct{ Role, Content string } `json:"messages"`
		}
		if json.NewDecoder(r.Body).Decode(&body) != nil {
			t.Fatal("invalid JSON")
		}
		if body.Model != "test-model" || len(body.Messages) != 2 {
			t.Error("invalid model/messages")
		}
		text := body.Messages[1].Content
		if strings.Contains(text, "foo()") || strings.Contains(text, "example.com") {
			t.Error("literal leaked into model text")
		}
		text = strings.ReplaceAll(text, "请检查", "Please check")
		json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": text}, "finish_reason": "stop"}}})
	}))
	defer server.Close()
	source := "请检查 `foo()` 和 https://example.com/a\n```go\nfmt.Println(\"你好\")\n```"
	got, err := Translate(context.Background(), Config{BaseURL: server.URL + "/v1", Model: "test-model", APIKey: "test-only-key"}, source)
	if err != nil || got != strings.ReplaceAll(source, "请检查", "Please check") {
		t.Fatalf("literal roundtrip failed: %q %v", got, err)
	}
}
func TestBadOutputsAreNotApplied(t *testing.T) {
	for _, kind := range []string{"missing-literal", "truncated", "empty", "auth"} {
		t.Run(kind, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if kind == "auth" {
					w.WriteHeader(401)
					w.Write([]byte("sensitive-provider-detail"))
					return
				}
				reason := "stop"
				text := "hello"
				if kind == "truncated" {
					reason = "length"
				}
				if kind == "empty" {
					text = ""
				}
				json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": text}, "finish_reason": reason}}})
			}))
			defer server.Close()
			source := "你好"
			if kind == "missing-literal" {
				source = "请检查 `foo()`"
			}
			_, err := Translate(context.Background(), Config{BaseURL: server.URL, Model: "test"}, source)
			if err == nil || strings.Contains(err.Error(), "sensitive-provider-detail") {
				t.Fatalf("bad output accepted or leaked: %v", err)
			}
		})
	}
}
func TestCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Now()
	_, err := Translate(ctx, Config{BaseURL: server.URL, Model: "test"}, "你好")
	if err != context.Canceled || time.Since(start) > time.Second {
		t.Fatalf("cancellation failed: %v", err)
	}
}
