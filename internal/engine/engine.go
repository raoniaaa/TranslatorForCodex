// Package engine owns the guarded draft translation state machine.
package engine

import (
	"strings"
	"time"
	"unicode"
	"unicode/utf16"
)

type Snapshot struct {
	Type             string `json:"type"`
	Target           string `json:"target"`
	Text             string `json:"text"`
	SelectionStart   int    `json:"selectionStart"`
	SelectionLength  int    `json:"selectionLength"`
	AtEnd            bool   `json:"atEnd"`
	Editable         bool   `json:"editable"`
	CompositionKnown bool   `json:"compositionKnown"`
	Composing        bool   `json:"composing"`
	Trusted          bool   `json:"trusted"`
	Supported        bool   `json:"supported"`
	Guard            string `json:"guard"`
	Reason           string `json:"reason"`
}
type Job struct {
	Revision uint64
	Snapshot Snapshot
	Source   string
	Started  time.Time
}
type Replacement struct {
	Type            string `json:"type"`
	ID              uint64 `json:"id"`
	Target          string `json:"target"`
	Expected        string `json:"expected"`
	Text            string `json:"text"`
	SelectionStart  int    `json:"selectionStart"`
	SelectionLength int    `json:"selectionLength"`
	Undo            bool   `json:"-"`
	Source          string `json:"-"`
	ReplaceStart    int    `json:"replaceStart"`
	ReplaceLength   int    `json:"replaceLength"`
	InsertText      string `json:"insertText"`
}
type State struct {
	Armed       bool     `json:"armed"`
	Phase       string   `json:"phase"`
	Status      string   `json:"status"`
	Original    string   `json:"original"`
	Translation string   `json:"translation"`
	LatencyMS   int64    `json:"latencyMs"`
	Revision    uint64   `json:"revision"`
	DelayMS     int      `json:"delayMs"`
	Current     Snapshot `json:"-"`
	target      string
	changed     time.Time
	attempted   uint64
	pending     *Job
	applying    *Replacement
	appliedAt   time.Time
	lastSource  string
	lastOutput  string
	lastApplied string
	lastBefore  string
	suppressed  string
}

func New() *State {
	return &State{Phase: "idle", Status: "配置服务后，点击宠物开启持续翻译模式", DelayMS: 2000}
}
func HasChinese(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}
func (s *State) set(phase, message string) { s.Phase = phase; s.Status = message }
func (s *State) Reset(reason string) {
	s.Armed = false
	s.target = ""
	s.pending = nil
	s.applying = nil
	s.Revision++
	s.lastSource = ""
	s.lastOutput = ""
	s.lastApplied = ""
	s.lastBefore = ""
	s.suppressed = ""
	s.set("paused", reason)
}
func eligible(v Snapshot) bool {
	return v.Trusted && v.Supported && v.Editable && v.Target != ""
}
func (s *State) invalidate() {
	s.pending = nil
	s.applying = nil
	s.Revision++
}
func (s *State) Toggle(now time.Time) {
	if s.Armed {
		s.Reset("翻译模式已关闭，点击宠物可再次开启")
		return
	}
	// The switch represents the user's intent, independently of focus or permission.
	s.Armed = true
	s.target = ""
	s.changed = now
	s.attempted = 0
	s.invalidate()
	s.Observe(s.Current, now)
}
func (s *State) Observe(v Snapshot, now time.Time) {
	old := s.Current
	s.Current = v
	if !s.Armed {
		return
	}
	if !eligible(v) {
		if eligible(old) || s.pending != nil || s.applying != nil {
			s.invalidate()
		}
		if !v.Trusted {
			s.set("permission", "翻译模式已开启，等待辅助功能授权")
		} else {
			s.set("waiting-focus", "翻译模式已开启，回到 Codex 输入框会自动继续")
		}
		return
	}
	if v.Target != s.target {
		s.invalidate()
		s.target = v.Target
		s.lastSource = ""
		s.lastOutput = ""
		s.lastApplied = ""
		s.lastBefore = ""
		s.suppressed = ""
		s.changed = now
		s.attempted = 0
		s.set("ready", "翻译模式已开启，正常输入中文即可")
	} else if !eligible(old) {
		// Recheck and debounce the returning draft before resuming.
		s.invalidate()
		s.changed = now
		s.attempted = 0
		s.set("waiting", "已回到输入框，等待输入停顿…")
	}

	changed := old.Text != v.Text || old.SelectionStart != v.SelectionStart || old.SelectionLength != v.SelectionLength || old.Composing != v.Composing || old.CompositionKnown != v.CompositionKnown || old.AtEnd != v.AtEnd
	if changed {
		s.Revision++
		s.changed = now
		s.pending = nil
		if s.applying != nil && v.Text != s.applying.Text {
			s.applying = nil
		}
		if s.suppressed != "" && v.Text != s.suppressed {
			s.suppressed = ""
		}
		// Native Cmd+Z must not cause the same draft to be translated again.
		if s.lastOutput != "" && old.Text == s.lastApplied && v.Text == s.lastBefore {
			s.suppressed = v.Text
			s.lastOutput = ""
			s.lastApplied = ""
			s.lastSource = ""
			s.lastBefore = ""
			s.set("restored", "已撤销，本段原文暂不再自动翻译")
			return
		}
		if v.Text == s.suppressed && s.suppressed != "" {
			s.set("restored", "已恢复中文，继续编辑后恢复翻译")
			return
		}
		if v.Composing {
			s.set("composing", "等待中文选词完成")
		} else if !v.CompositionKnown {
			s.set("unsupported", "当前输入法暂不支持自动替换")
		} else if s.lastOutput != "" && v.Text == s.lastOutput {
			s.set("success", "英文已填入，可继续输入中文")
		} else {
			s.set("waiting", "等待输入停顿…")
		}
	}
}
func (s *State) Next(now time.Time) *Job {
	v := s.Current
	if s.applying != nil && now.Sub(s.appliedAt) > 3*time.Second {
		s.invalidate()
		s.attempted = s.Revision
		s.set("error", "写入确认超时，已保留草稿；继续编辑后重试")
		return nil
	}
	if !s.Armed || s.pending != nil || s.applying != nil {
		return nil
	}
	if !eligible(v) {
		if !v.Trusted {
			s.set("permission", "翻译模式已开启，等待辅助功能授权")
		} else {
			s.set("waiting-focus", "翻译模式已开启，回到 Codex 输入框会自动继续")
		}
		return nil
	}
	if v.Composing {
		s.set("composing", "等待中文选词完成")
		return nil
	}
	if !v.CompositionKnown {
		s.set("unsupported", "当前输入法暂不支持自动替换")
		return nil
	}
	if !v.AtEnd || v.SelectionLength != 0 {
		s.set("editing", "正在编辑，光标回到末尾后继续")
		return nil
	}
	if v.Text == s.suppressed && s.suppressed != "" {
		return nil
	}
	if s.lastOutput != "" && v.Text == s.lastOutput {
		s.set("success", "英文已填入，可继续输入中文")
		return nil
	}
	if !HasChinese(v.Text) || strings.TrimSpace(v.Text) == "" {
		if s.Phase != "success" && s.Phase != "restored" {
			s.set("ready", "已开启，等待中文输入")
		}
		return nil
	}
	if s.attempted == s.Revision {
		return nil
	}
	if now.Sub(s.changed) < time.Duration(s.DelayMS)*time.Millisecond {
		s.set("waiting", "等待输入停顿…")
		return nil
	}
	if strings.Count(v.Text, "```")%2 != 0 {
		s.set("editing", "等待代码块输入完整")
		return nil
	}
	source := v.Text
	if s.lastOutput != "" && strings.HasPrefix(v.Text, s.lastOutput) {
		tail := strings.TrimPrefix(v.Text, s.lastOutput)
		if !HasChinese(tail) {
			s.set("ready", "等待新增中文")
			return nil
		}
		// Preserve original meaning when extending a previously translated draft.
		source = s.lastSource + tail
	}
	j := &Job{Revision: s.Revision, Snapshot: v, Source: source, Started: now}

	s.pending = j
	s.attempted = s.Revision
	s.Original = v.Text
	s.LatencyMS = 0
	s.set("translating", "正在翻译，请稍候…")
	return j
}
func (s *State) Complete(j Job, translation string, err error) *Replacement {
	v := s.Current
	if s.pending == nil || !s.Armed || !eligible(v) || j.Revision != s.Revision || j.Revision != s.pending.Revision || j.Snapshot.Target != v.Target || j.Snapshot.Text != v.Text || !v.CompositionKnown || v.Composing || !v.AtEnd || v.SelectionLength != 0 || v.SelectionStart != j.Snapshot.SelectionStart {
		return nil
	}
	s.pending = nil
	s.LatencyMS = time.Since(j.Started).Milliseconds()
	if err != nil {
		s.set("error", err.Error())
		return nil
	}
	s.Original = v.Text
	s.Translation = translation
	r := makeReplacement(j.Revision, v, translation)
	r.Source = j.Source
	s.applying = r
	s.appliedAt = time.Now()
	s.set("applying", "正在填入完整译文…")
	return r
}
func (s *State) Acknowledge(id uint64, ok bool, reason string) {
	r := s.applying
	if r == nil || r.ID != id {
		return
	}
	s.applying = nil
	if !ok {
		s.lastSource = ""
		s.lastOutput = ""
		s.lastApplied = ""
		s.lastBefore = ""
		s.set("error", "未替换："+reason)
		return
	}
	if r.Undo {
		s.suppressed = r.Text
		s.lastSource = ""
		s.lastOutput = ""
		s.lastApplied = ""
		s.lastBefore = ""
		s.set("restored", "已恢复中文，继续编辑后恢复翻译")
		return
	}
	s.lastSource = r.Source
	s.lastOutput = r.Text
	s.lastApplied = r.Text
	s.lastBefore = r.Expected
	s.set("success", "英文已填入，可继续输入中文")
	if reason != "" {
		s.Status = reason
	}
}
func (s *State) Undo() *Replacement {
	if !s.Armed || !eligible(s.Current) || s.Current.Target != s.target || s.applying != nil || s.lastOutput == "" || s.Current.Text != s.lastApplied || !s.Current.AtEnd || s.Current.SelectionLength != 0 || s.Current.Composing || !s.Current.CompositionKnown {
		s.set("error", "草稿已改变，无法直接恢复；可以使用 ⌘Z")
		return nil
	}
	s.Revision++
	s.pending = nil
	r := makeReplacement(s.Revision, s.Current, s.lastBefore)
	r.Undo = true
	s.applying = r
	s.appliedAt = time.Now()
	return r
}

// A single whole-draft write; offsets use UTF-16 for macOS accessibility.
func makeReplacement(id uint64, snapshot Snapshot, text string) *Replacement {
	return &Replacement{Type: "replace", ID: id, Target: snapshot.Target, Expected: snapshot.Text, Text: text, SelectionStart: snapshot.SelectionStart, SelectionLength: snapshot.SelectionLength,
		ReplaceStart: 0, ReplaceLength: len(utf16.Encode([]rune(snapshot.Text))), InsertText: text}
}
