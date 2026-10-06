package web

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"translator/internal/credentials"
	"translator/internal/desktop"
	"translator/internal/engine"
	"translator/internal/provider"
)

//go:embed ui/*
var assets embed.FS

type App struct {
	mu           sync.Mutex
	state        *engine.State
	config       provider.Config
	bridge       *desktop.Bridge
	cancel       context.CancelFunc
	bridgeStatus string
	URL          string
	server       *http.Server
	stop         chan struct{}
	closeOnce    sync.Once
	previewSlots chan struct{}
	settingsPath string
	lastHUD      string
	secrets      credentials.Store
	keyID        string
	storageError string
	keyPersisted bool
}
type savedPreferences struct {
	preferences
	KeyID      string `json:"keyId,omitempty"`
	WholeDraft bool   `json:"wholeDraft"`
}

type preferences struct {
	BaseURL string `json:"baseUrl"`
	Model   string `json:"model"`
	DelayMS int    `json:"delayMs"`
}

func Start(root string, demo bool, hosted ...bool) (*App, error) {
	return startWithStore(root, demo, credentials.New(root), hosted...)
}
func startWithStore(root string, demo bool, secrets credentials.Store, hosted ...bool) (*App, error) {
	a := &App{state: engine.New(), stop: make(chan struct{}), previewSlots: make(chan struct{}, 2), secrets: secrets}
	dir := credentials.ConfigDir()
	if dir != "" {
		a.settingsPath = filepath.Join(dir, "settings.json")
		if data, err := os.ReadFile(a.settingsPath); err == nil {
			var p savedPreferences
			if json.Unmarshal(data, &p) == nil {
				a.config.BaseURL = p.BaseURL
				a.config.Model = p.Model
				a.keyID = p.KeyID
				if p.KeyID != "" {
					key, err := a.secrets.Get(p.KeyID)
					if err != nil {
						a.storageError = err.Error()
					} else {
						a.config.APIKey = key
						a.keyPersisted = key != ""
					}
					if err == nil && key == "" {
						a.storageError = "未找到已保存的 API Key，请重新保存密钥"
					}
				}
				if p.DelayMS >= 400 && p.DelayMS <= 3000 {
					a.state.DelayMS = p.DelayMS
					if !p.WholeDraft && p.DelayMS < 2000 {
						a.state.DelayMS = 2000
					}
				}
			}
		}
	}
	if v := os.Getenv("TRANSLATOR_BASE_URL"); v != "" {
		if origin(v) != origin(a.config.BaseURL) {
			a.config.APIKey = ""
			a.keyPersisted = false
		}
		a.config.BaseURL = v
	}
	if v := os.Getenv("TRANSLATOR_API_KEY"); v != "" {
		a.config.APIKey = v
		a.keyPersisted = false
	}
	if v := os.Getenv("TRANSLATOR_MODEL"); v != "" {
		a.config.Model = v
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	token := make([]byte, 24)
	if _, err := rand.Read(token); err != nil {
		listener.Close()
		return nil, err
	}
	prefix := "/" + hex.EncodeToString(token) + "/"
	a.URL = "http://" + listener.Addr().String() + prefix
	mux := http.NewServeMux()
	mux.HandleFunc(prefix+"api/state", a.status)
	mux.HandleFunc(prefix+"api/config", a.configure)
	mux.HandleFunc(prefix+"api/preview", a.preview)
	mux.HandleFunc(prefix+"api/pause", func(w http.ResponseWriter, r *http.Request) {
		if !post(w, r) {
			return
		}
		a.mu.Lock()
		a.state.Reset("已取消本次翻译，写好后点击宠物")
		if a.bridge != nil {
			_ = a.bridge.Send(map[string]string{"type": "cancel-write"})
		}
		if a.cancel != nil {
			a.cancel()
		}
		a.mu.Unlock()
		reply(w, map[string]bool{"ok": true})
	})
	for _, action := range []string{"permission", "recheck-permission", "reveal-app", "connect", "show-pet", "demo"} {
		action := action
		mux.HandleFunc(prefix+"api/"+action, func(w http.ResponseWriter, r *http.Request) {
			if !post(w, r) {
				return
			}
			a.mu.Lock()
			b := a.bridge
			configured := a.config.BaseURL != "" && a.config.Model != ""
			a.mu.Unlock()
			if b == nil {
				bad(w, errors.New("演示模式没有桌面连接，请使用打包后的应用"))
				return
			}
			if action == "connect" && !configured {
				bad(w, errors.New("请先保存 API 地址和模型"))
				return
			}
			if err := b.Send(map[string]string{"type": action}); err != nil {
				bad(w, errors.New("桌面连接已断开，请重启工具"))
				return
			}
			reply(w, map[string]bool{"ok": true})
		})
	}
	ui, _ := fs.Sub(assets, "ui")
	mux.Handle(prefix, http.StripPrefix(prefix, http.FileServer(http.FS(ui))))
	a.server = &http.Server{ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != listener.Addr().String() {
			http.Error(w, "Invalid host", 403)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" && origin != "http://"+r.Host {
			http.Error(w, "Invalid origin", 403)
			return
		}
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})}
	go a.server.Serve(listener)
	if !demo {
		var bridge *desktop.Bridge
		var err error
		if len(hosted) > 0 && hosted[0] {
			bridge = desktop.Attach(a.Receive)
		} else {
			bridge, err = desktop.Start(root, a.URL, a.Receive)
		}
		a.mu.Lock()
		a.bridge = bridge
		if err != nil {
			a.bridgeStatus = "桌面组件未启动，请使用打包后的应用"
		} else {
			a.bridgeStatus = "桌面组件已连接"
		}
		a.mu.Unlock()
	} else {
		a.bridgeStatus = "浏览器试译模式，不读取或修改桌面应用"
	}
	go a.loop()
	return a, nil
}
func (a *App) Done() <-chan struct{} { return a.stop }
func (a *App) Close() {
	a.closeOnce.Do(func() {
		close(a.stop)
		a.mu.Lock()
		if a.cancel != nil {
			a.cancel()
		}
		b := a.bridge
		a.mu.Unlock()
		if b != nil {
			b.Close()
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = a.server.Shutdown(ctx)
	})
}
func (a *App) Receive(e desktop.Event) {
	a.mu.Lock()
	defer a.mu.Unlock()
	rev := a.state.Revision
	switch e.Type {
	case "snapshot":
		a.state.Observe(e.Snapshot, time.Now())
	case "translate":
		if a.config.Model == "" || a.config.BaseURL == "" {
			a.state.Phase = "error"
			a.state.Status = "请先在设置中填写 API 地址和模型"
			return
		}
		a.state.Request(e.Snapshot, time.Now())

	case "pause":
		a.state.Reset("已取消本次翻译，写好后点击宠物")
		if a.bridge != nil {
			_ = a.bridge.Send(map[string]string{"type": "cancel-write"})
		}
	case "undo":
		if r := a.state.Undo(); r != nil && a.bridge != nil {
			if err := a.bridge.Send(r); err != nil {
				a.state.Acknowledge(r.ID, false, "桌面连接失败")
			}
		}
	case "result":
		a.state.Acknowledge(e.ID, e.OK, e.Reason)
	case "notice":
		a.state.Phase = "error"
		a.state.Status = e.Reason
	case "closed":
		a.state.Observe(engine.Snapshot{}, time.Now())
		a.state.Phase = "error"
		a.state.Status = e.Reason
		a.bridgeStatus = e.Reason
	case "quit":
		go a.Close()
		return
	}
	if rev != a.state.Revision && a.cancel != nil {
		a.cancel()
		a.cancel = nil
	}
}
func (a *App) loop() {
	tick := time.NewTicker(150 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-a.stop:
			return
		case <-tick.C:
			a.mu.Lock()
			job := a.state.Next(time.Now())
			if job != nil {
				ctx, cancel := context.WithCancel(context.Background())
				a.cancel = cancel
				config := a.config
				go func(j engine.Job) {
					defer cancel()
					translated, err := provider.Translate(ctx, config, j.Source)
					a.mu.Lock()
					defer a.mu.Unlock()
					if r := a.state.Complete(j, translated, err); r != nil {
						if a.bridge == nil {
							a.state.Acknowledge(r.ID, false, "桌面连接不可用")
						} else if err := a.bridge.Send(r); err != nil {
							a.state.Acknowledge(r.ID, false, "桌面连接失败")
						}
					}
				}(*job)
			}
			hud := map[string]any{"type": "status", "phase": a.state.Phase, "message": a.state.Status, "busy": a.state.Busy, "model": a.config.Model, "configured": a.config.BaseURL != "" && a.config.Model != ""}
			data, _ := json.Marshal(hud)
			if string(data) != a.lastHUD && a.bridge != nil {
				_ = a.bridge.Send(hud)
				a.lastHUD = string(data)
			}
			a.mu.Unlock()
		}
	}
}
func reply(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
func bad(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}
func post(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != "POST" {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return false
	}
	return true
}
func (a *App) status(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		w.WriteHeader(405)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	reply(w, map[string]any{"state": a.state, "config": preferences{a.config.BaseURL, a.config.Model, a.state.DelayMS}, "hasKey": a.config.APIKey != "", "keyStored": a.keyPersisted, "storageError": a.storageError, "configured": a.config.BaseURL != "" && a.config.Model != "", "bridge": a.bridgeStatus, "native": a.bridge != nil, "trusted": a.state.Current.Trusted, "guard": a.state.Current.Guard, "platform": runtime.GOOS})
}
func origin(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return u.Scheme + "://" + u.Host
}
func (a *App) configure(w http.ResponseWriter, r *http.Request) {
	if !post(w, r) {
		return
	}
	var input struct {
		provider.Config
		DelayMS  int  `json:"delayMs"`
		ClearKey bool `json:"clearKey"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768)).Decode(&input) != nil {
		bad(w, errors.New("设置格式错误"))
		return
	}
	input.BaseURL = strings.TrimSpace(input.BaseURL)
	input.Model = strings.TrimSpace(input.Model)
	input.APIKey = strings.TrimSpace(input.APIKey)
	if _, err := input.Config.Endpoint(); err != nil {
		bad(w, err)
		return
	}
	if input.Model == "" {
		bad(w, errors.New("请输入模型名称"))
		return
	}
	if input.DelayMS == 0 {
		input.DelayMS = 2000
	}
	if input.DelayMS < 400 || input.DelayMS > 3000 {
		bad(w, errors.New("停顿时间须为 400–3000 毫秒"))
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if input.APIKey == "" && !input.ClearKey && origin(input.BaseURL) == origin(a.config.BaseURL) {
		if a.storageError != "" {
			bad(w, errors.New("无法读取本地密钥，请填写密钥后重新保存"))
			return
		}
		input.APIKey = a.config.APIKey
	}
	if input.ClearKey {
		input.APIKey = ""
	}
	if a.settingsPath == "" {
		bad(w, errors.New("无法定位本地设置目录"))
		return
	}
	// Store the new credential first, then atomically publish its reference.
	// A failed file write leaves the old settings and key intact.
	newID := ""
	if input.APIKey != "" {
		token := make([]byte, 24)
		if _, err := rand.Read(token); err != nil {
			bad(w, errors.New("无法保存密钥"))
			return
		}
		newID = hex.EncodeToString(token)
		if err := a.secrets.Set(newID, input.APIKey); err != nil {
			bad(w, err)
			return
		}
	}
	committed := false
	defer func() {
		if !committed && newID != "" {
			_ = a.secrets.Delete(newID)
		}
	}()
	data, _ := json.MarshalIndent(savedPreferences{preferences{input.BaseURL, input.Model, input.DelayMS}, newID, true}, "", "  ")
	if err := writeSettings(a.settingsPath, data); err != nil {
		bad(w, errors.New("无法保存本地设置，原设置已保留"))
		return
	}
	committed = true
	oldID := a.keyID
	a.keyID = newID
	a.keyPersisted = newID != ""
	a.storageError = ""
	if oldID != "" {
		_ = a.secrets.Delete(oldID)
	}

	if a.cancel != nil {
		a.cancel()
	}
	a.state.Reset("设置已保存在本机；写好后点击宠物翻译")
	if a.bridge != nil {
		_ = a.bridge.Send(map[string]string{"type": "cancel-write"})
	}

	a.config = input.Config
	a.state.DelayMS = input.DelayMS
	reply(w, map[string]bool{"ok": true, "hasKey": a.config.APIKey != "", "keyStored": a.keyID != ""})
}
func (a *App) preview(w http.ResponseWriter, r *http.Request) {
	if !post(w, r) {
		return
	}
	select {
	case a.previewSlots <- struct{}{}:
		defer func() { <-a.previewSlots }()
	default:
		bad(w, errors.New("请等待上一次试译完成"))
		return
	}
	var input struct {
		Text string `json:"text"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768)).Decode(&input) != nil {
		bad(w, errors.New("输入过长或格式错误"))
		return
	}
	if strings.TrimSpace(input.Text) == "" {
		bad(w, errors.New("请输入中文"))
		return
	}
	a.mu.Lock()
	config := a.config
	a.mu.Unlock()
	start := time.Now()
	text, err := provider.Translate(r.Context(), config, input.Text)
	if err != nil {
		bad(w, err)
		return
	}
	reply(w, map[string]any{"text": text, "durationMs": time.Since(start).Milliseconds()})
}

func writeSettings(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), "settings-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
