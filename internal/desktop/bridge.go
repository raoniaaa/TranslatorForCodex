package desktop

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"

	"translator/internal/engine"
)

type Event struct {
	engine.Snapshot
	ID uint64 `json:"id"`
	OK bool   `json:"ok"`
}
type Bridge struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	mu  sync.Mutex
}

func Start(root, settingsURL string, receive func(Event)) (*Bridge, error) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command(filepath.Join(root, "translator-bridge"), settingsURL)
	case "windows":
		cmd = exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(root, "bridge.ps1"), "-SettingsURL", settingsURL)
	default:
		return nil, fmt.Errorf("此原型支持 Windows 和 macOS")
	}
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	// Native diagnostics must never include a draft or credentials.
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	b := &Bridge{cmd: cmd, in: in}
	go func() {
		scan := bufio.NewScanner(out)
		scan.Buffer(make([]byte, 4096), 1<<20)
		for scan.Scan() {
			var event Event
			if json.Unmarshal(scan.Bytes(), &event) == nil {
				receive(event)
			}
		}
		_ = cmd.Wait()
		receive(Event{Snapshot: engine.Snapshot{Type: "closed", Reason: "桌面连接已断开，请重启工具"}})
	}()
	return b, nil
}
func (b *Bridge) Send(v any) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return json.NewEncoder(b.in).Encode(v)
}
func (b *Bridge) Close() {
	_ = b.in.Close()
	if b.cmd.Process != nil {
		_ = b.cmd.Process.Kill()
	}
}
