package web

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"translator/internal/credentials"
	"translator/internal/desktop"
	"translator/internal/engine"
)

type memorySecrets struct {
	keys map[string]string
	fail bool
}

func (s *memorySecrets) Get(id string) (string, error) { return s.keys[id], nil }
func (s *memorySecrets) Set(id, key string) error {
	if s.fail {
		return errors.New("test storage unavailable")
	}
	s.keys[id] = key
	return nil
}
func (s *memorySecrets) Delete(id string) error { delete(s.keys, id); return nil }
func setupConfig(t *testing.T) {
	t.Helper()
	t.Setenv("TRANSLATOR_CONFIG_DIR", t.TempDir())
	for _, name := range []string{"TRANSLATOR_API_KEY", "TRANSLATOR_BASE_URL", "TRANSLATOR_MODEL"} {
		t.Setenv(name, "")
	}
}
func startTest(t *testing.T, store credentials.Store) *App {
	t.Helper()
	a, err := startWithStore("", true, store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.Close)
	return a
}
func saveTest(t *testing.T, a *App, body string, want int) {
	t.Helper()
	r, err := http.Post(a.URL+"api/config", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Body.Close()
	if r.StatusCode != want {
		t.Fatalf("save status %d, want %d", r.StatusCode, want)
	}
}

const firstConfig = `{"baseUrl":"https://example.com/v1","model":"test","apiKey":"test-only-secret","delayMs":900}`

func TestConfigurationRestoresWithoutExposingKey(t *testing.T) {
	setupConfig(t)
	store := &memorySecrets{keys: map[string]string{}}
	a := startTest(t, store)
	saveTest(t, a, firstConfig, 200)
	data, err := os.ReadFile(a.settingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "test-only-secret") {
		t.Fatal("plaintext key in settings")
	}
	info, _ := os.Stat(a.settingsPath)
	if info.Mode().Perm() != 0600 {
		t.Fatal("settings permissions")
	}
	response, err := http.Get(a.URL + "api/state")
	if err != nil {
		t.Fatal(err)
	}
	data, _ = io.ReadAll(response.Body)
	response.Body.Close()
	if strings.Contains(string(data), "test-only-secret") {
		t.Fatal("key exposed by state")
	}
	var status struct {
		HasKey    bool `json:"hasKey"`
		KeyStored bool `json:"keyStored"`
	}
	json.Unmarshal(data, &status)
	if !status.HasKey || !status.KeyStored {
		t.Fatal("key not reported stored")
	}
	a.Close()
	b := startTest(t, store)
	if b.config.APIKey != "test-only-secret" || b.config.BaseURL != "https://example.com/v1" || b.config.Model != "test" || b.state.DelayMS != 900 {
		t.Fatal("restart did not restore configuration")
	}
	saveTest(t, b, `{"baseUrl":"https://example.com/v1","model":"new-model","apiKey":"","delayMs":800}`, 200)
	if b.config.APIKey != "test-only-secret" || len(store.keys) != 1 {
		t.Fatal("blank key did not preserve secret or old entry leaked")
	}
	saveTest(t, b, `{"baseUrl":"https://example.com/v1","model":"new-model","apiKey":"updated-test-key","delayMs":800}`, 200)
	b.Close()
	c := startTest(t, store)
	if c.config.APIKey != "updated-test-key" || c.config.Model != "new-model" || len(store.keys) != 1 {
		t.Fatal("updated key did not survive restart")
	}
	saveTest(t, c, `{"baseUrl":"https://example.com/v1","model":"new-model","clearKey":true,"delayMs":800}`, 200)
	c.Close()
	d := startTest(t, store)
	if d.config.APIKey != "" || len(store.keys) != 0 {
		t.Fatal("cleared key survived restart")
	}
}
func TestCrossOriginAndHostProtection(t *testing.T) {
	setupConfig(t)
	store := &memorySecrets{keys: map[string]string{}}
	a := startTest(t, store)
	saveTest(t, a, firstConfig, 200)
	req, _ := http.NewRequest("POST", a.URL+"api/config", strings.NewReader(firstConfig))
	req.Header.Set("Origin", "https://evil.invalid")
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 403 {
		t.Fatal("cross-origin write accepted")
	}
	req, _ = http.NewRequest("GET", a.URL+"api/state", nil)
	req.Host = "evil.invalid"
	response, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 403 {
		t.Fatal("host mismatch accepted")
	}
	saveTest(t, a, `{"baseUrl":"https://different.example/v1","model":"test","apiKey":"","delayMs":800}`, 200)
	a.Close()
	b := startTest(t, store)
	if b.config.APIKey != "" || len(store.keys) != 0 {
		t.Fatal("old key followed changed API host")
	}
}
func TestFailedPersistencePreservesConfiguration(t *testing.T) {
	setupConfig(t)
	store := &memorySecrets{keys: map[string]string{}}
	a := startTest(t, store)
	saveTest(t, a, firstConfig, 200)
	before, _ := os.ReadFile(a.settingsPath)
	oldID := a.keyID
	store.fail = true
	saveTest(t, a, `{"baseUrl":"https://example.com/v1","model":"new","apiKey":"new-test-key","delayMs":800}`, 400)
	after, _ := os.ReadFile(a.settingsPath)
	if !bytes.Equal(before, after) || a.keyID != oldID || a.config.Model != "test" {
		t.Fatal("failed secret save changed config")
	}
	store.fail = false
	oldPath := a.settingsPath
	// Make the destination parent a file to force settings persistence to fail.
	blocked := filepath.Join(t.TempDir(), "blocked")
	os.WriteFile(blocked, []byte("file"), 0600)
	a.settingsPath = filepath.Join(blocked, "settings.json")
	saveTest(t, a, `{"baseUrl":"https://example.com/v1","model":"new","apiKey":"new-test-key","delayMs":800}`, 400)
	after, _ = os.ReadFile(oldPath)
	if !bytes.Equal(before, after) || a.keyID != oldID || len(store.keys) != 1 {
		t.Fatal("failed config write damaged old key or leaked new key")
	}
}
func TestOnlyExplicitNativeClickRequestsTranslation(t *testing.T) {
	setupConfig(t)
	a := startTest(t, &memorySecrets{keys: map[string]string{}})
	saveTest(t, a, firstConfig, 200)
	snapshot := engine.Snapshot{Type: "snapshot", Trusted: true, Supported: true, Editable: true, Target: "codex:1", Text: "中文", SelectionStart: 0, AtEnd: false, CompositionKnown: true}
	a.Receive(desktop.Event{Snapshot: snapshot})
	a.Receive(desktop.Event{Snapshot: engine.Snapshot{Type: "connect"}})
	a.mu.Lock()
	busy := a.state.Busy
	a.mu.Unlock()
	if busy {
		t.Fatal("focus or connect started translation")
	}
	snapshot.Type = "translate"
	a.Receive(desktop.Event{Snapshot: snapshot})
	a.mu.Lock()
	busy = a.state.Busy
	current := a.state.Current
	a.mu.Unlock()
	if !busy || current.Text != "中文" || current.SelectionStart != 0 {
		t.Fatal("explicit click snapshot ignored")
	}
	saveTest(t, a, `{"baseUrl":"https://example.com/v1","model":"updated"}`, 200)
	a.mu.Lock()
	busy = a.state.Busy
	a.mu.Unlock()
	if busy {
		t.Fatal("settings change kept old request active")
	}
	snapshot.Type = "snapshot"
	a.Receive(desktop.Event{Snapshot: snapshot})
	a.mu.Lock()
	busy = a.state.Busy
	a.mu.Unlock()
	if busy {
		t.Fatal("snapshot restarted request")
	}
}

func TestLocalConfigurationRestoresAfterRestart(t *testing.T) {
	setupConfig(t)
	store := credentials.New("")
	a := startTest(t, store)
	saveTest(t, a, firstConfig, 200)
	a.Close()
	b := startTest(t, credentials.New(""))
	if b.config.APIKey != "test-only-secret" || b.storageError != "" || !b.keyPersisted {
		t.Fatal("local key did not restore")
	}
	saveTest(t, b, `{"baseUrl":"https://example.com/v1","model":"test","clearKey":true,"delayMs":2000}`, 200)
	b.Close()
	c := startTest(t, credentials.New(""))
	if c.config.APIKey != "" {
		t.Fatal("deleted local key survived restart")
	}
}
func TestLegacyDelayUsesWholeDraftQuietPeriod(t *testing.T) {
	setupConfig(t)
	dir := os.Getenv("TRANSLATOR_CONFIG_DIR")
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"delayMs":800}`), 0600); err != nil {
		t.Fatal(err)
	}
	a := startTest(t, &memorySecrets{keys: map[string]string{}})
	if a.state.DelayMS != 2000 {
		t.Fatal("legacy short delay was not migrated")
	}
}
