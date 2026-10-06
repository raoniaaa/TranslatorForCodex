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

// Busy describes only the current explicit request, never a continuous mode.
type State struct {
	Busy        bool     `json:"busy"`
	Phase       string   `json:"phase"`
	Status      string   `json:"status"`
	Original    string   `json:"original"`
	Translation string   `json:"translation"`
	LatencyMS   int64    `json:"latencyMs"`
	Revision    uint64   `json:"revision"`
	DelayMS     int      `json:"delayMs"` // Read old preferences without enabling timed translation.
	Current     Snapshot `json:"-"`
	requested   bool
	pending     *Job
	applying    *Replacement
	appliedAt   time.Time
	lastTarget  string
	lastOutput  string
	lastBefore  string
}

func New() *State {
	return &State{Phase: "idle", Status: "输入完成后，点击宠物翻译当前整段草稿", DelayMS: 2000}
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
func eligible(v Snapshot) bool             { return v.Trusted && v.Supported && v.Editable && v.Target != "" }
func sameDraft(a, b Snapshot) bool {
	return a.Target == b.Target && a.Text == b.Text && a.SelectionStart == b.SelectionStart && a.SelectionLength == b.SelectionLength && a.Composing == b.Composing && a.CompositionKnown == b.CompositionKnown && eligible(a) == eligible(b)
}
func (s *State) cancel() {
	s.Busy = false
	s.requested = false
	s.pending = nil
	s.applying = nil
	s.Revision++
}
func (s *State) Reset(reason string) {
	s.cancel()
	s.lastTarget = ""
	s.lastOutput = ""
	s.lastBefore = ""
	s.set("idle", reason)
}
func (s *State) Observe(v Snapshot, now time.Time) {
	old := s.Current
	s.Current = v
	if s.Busy && !sameDraft(old, v) {
		// Native writes are acknowledged before the next snapshot. Never carry a
		// click across edits, composition changes, lost focus or permission changes.
		s.cancel()
		s.set("cancelled", "输入状态已改变，本次翻译已取消；写好后再点击宠物")
		return
	}
	if s.Busy {
		return
	}
	if !v.Trusted {
		s.set("permission", "请为 Translator 开启辅助功能权限")
		return
	}
	if !eligible(v) {
		s.set("waiting-focus", "点击 Codex 输入框，写好后再点击宠物")
		return
	}
	if !sameDraft(old, v) {
		if s.lastTarget == v.Target && s.lastOutput == v.Text && s.lastOutput != "" {
			s.set("success", "英文已填入，下一次翻译由你点击触发")
		} else {
			s.set("ready", "写好后点击宠物，翻译当前整段草稿")
		}
	}
}

// Request captures only the focused draft supplied with this explicit click.
// Repeated clicks while busy do not queue another translation.
func (s *State) Request(v Snapshot, now time.Time) {
	if s.Busy {
		return
	}
	s.Observe(v, now)
	if !eligible(v) {
		return
	}
	if !v.CompositionKnown {
		s.set("unsupported", "无法确认输入法组合状态，请完成选词并重新点击输入框")
		return
	}
	if v.Composing {
		s.set("composing", "请先完成中文选词，再点击宠物翻译")
		return
	}
	length := len(utf16.Encode([]rune(v.Text)))
	if v.SelectionStart < 0 || v.SelectionLength < 0 || v.SelectionStart > length || v.SelectionLength > length-v.SelectionStart {
		s.set("error", "无法确定当前选区，请重新点击输入框")
		return
	}
	if !HasChinese(v.Text) {
		s.set("ready", "当前草稿没有需要翻译的中文")
		return
	}
	if strings.Count(v.Text, "```")%2 != 0 {
		s.set("editing", "代码块尚未闭合，补齐后再点击宠物")
		return
	}
	s.Revision++
	s.Busy = true
	s.requested = true
	s.set("checking", "正在检查当前草稿…")
}
func (s *State) Next(now time.Time) *Job {
	if s.applying != nil && now.Sub(s.appliedAt) > 3*time.Second {
		s.cancel()
		s.set("error", "写入确认超时，请检查草稿后再点击重试")
		return nil
	}
	if !s.requested || !s.Busy {
		return nil
	}
	s.requested = false
	j := &Job{Revision: s.Revision, Snapshot: s.Current, Source: s.Current.Text, Started: now}
	s.pending = j
	s.Original = j.Source
	s.LatencyMS = 0
	s.set("translating", "正在翻译整段草稿，请稍候…")
	return j
}
func (s *State) Complete(j Job, translation string, err error) *Replacement {
	if s.pending == nil || !s.Busy || j.Revision != s.Revision || j.Revision != s.pending.Revision || !eligible(s.Current) || !sameDraft(j.Snapshot, s.Current) {
		return nil
	}
	s.pending = nil
	s.LatencyMS = time.Since(j.Started).Milliseconds()
	if err != nil {
		s.Busy = false
		s.set("error", err.Error()+"；点击宠物可重试")
		return nil
	}
	s.Translation = translation
	r := makeReplacement(j.Revision, s.Current, translation)
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
	s.Busy = false
	if !ok {
		s.lastOutput = ""
		s.set("error", "未确认替换："+reason)
		return
	}
	if r.Undo {
		s.lastTarget = ""
		s.lastOutput = ""
		s.lastBefore = ""
		s.set("restored", "已恢复替换前的草稿，点击宠物才会再次翻译")
		return
	}
	s.lastTarget = r.Target
	s.lastOutput = r.Text
	s.lastBefore = r.Expected
	s.set("success", "英文已填入，下一次翻译由你点击触发")
	if reason != "" {
		s.Status = reason
	}
}
func (s *State) Undo() *Replacement {
	v := s.Current
	if s.Busy || !eligible(v) || s.lastTarget != v.Target || s.lastOutput == "" || v.Text != s.lastOutput || v.Composing || !v.CompositionKnown {
		s.set("error", "草稿已改变或正在处理，无法直接恢复；请使用编辑器的撤销功能")
		return nil
	}
	s.Revision++
	r := makeReplacement(s.Revision, v, s.lastBefore)
	r.Undo = true
	s.Busy = true
	s.applying = r
	s.appliedAt = time.Now()
	s.set("applying", "正在恢复替换前的草稿…")
	return r
}
func makeReplacement(id uint64, snapshot Snapshot, text string) *Replacement {
	return &Replacement{Type: "replace", ID: id, Target: snapshot.Target, Expected: snapshot.Text, Text: text, SelectionStart: snapshot.SelectionStart, SelectionLength: snapshot.SelectionLength,
		ReplaceStart: 0, ReplaceLength: len(utf16.Encode([]rune(snapshot.Text))), InsertText: text}
}
