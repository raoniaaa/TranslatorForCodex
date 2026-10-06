package engine

import (
	"errors"
	"testing"
	"time"
	"unicode/utf16"
)

func draft(text string) Snapshot {
	return Snapshot{Type: "snapshot", Target: "codex:1", Text: text, SelectionStart: len(utf16.Encode([]rune(text))), AtEnd: true, Editable: true, CompositionKnown: true, Trusted: true, Supported: true}
}
func clicked(text string) (*State, time.Time) {
	s := New()
	now := time.Now()
	s.Request(draft(text), now)
	return s, now
}
func TestTypingAndLongPausesNeverTranslate(t *testing.T) {
	s := New()
	now := time.Now()
	for i, text := range []string{"你", "你好", "你好，明天见"} {
		s.Observe(draft(text), now.Add(time.Duration(i)*time.Hour))
		if s.Next(now.Add(24*time.Hour)) != nil || s.Busy {
			t.Fatal("typing or waiting started a request")
		}
	}
}
func TestClickTranslatesWholeDraftFromAnySelection(t *testing.T) {
	for _, selection := range [][2]int{{0, 0}, {3, 0}, {2, 2}} {
		s := New()
		now := time.Now()
		v := draft("Hello 😀你好，明天见")
		v.SelectionStart = selection[0]
		v.SelectionLength = selection[1]
		v.AtEnd = false
		s.Request(v, now)
		j := s.Next(now)
		if j == nil || j.Source != v.Text {
			t.Fatal("click did not translate whole visible draft immediately")
		}
		r := s.Complete(*j, "Hello, see you tomorrow.", nil)
		if r == nil || r.Expected != v.Text || r.ReplaceStart != 0 || r.ReplaceLength != len(utf16.Encode([]rune(v.Text))) || r.SelectionStart != selection[0] || r.SelectionLength != selection[1] {
			t.Fatal("incorrect whole-draft replacement or selection guard")
		}
		s.Acknowledge(r.ID, true, "")
		s.Observe(draft(r.Text), now)
		if s.Busy || s.Next(now.Add(time.Hour)) != nil {
			t.Fatal("completed request remained enabled")
		}
	}
}
func TestClickDuringCompositionRequiresAnotherClick(t *testing.T) {
	s := New()
	now := time.Now()
	v := draft("ni hao")
	v.Composing = true
	s.Request(v, now)
	if s.Busy || s.Next(now) != nil {
		t.Fatal("requested during composition")
	}
	v = draft("你好")
	s.Observe(v, now)
	if s.Next(now.Add(time.Hour)) != nil {
		t.Fatal("old click was queued after composition")
	}
	s.Request(v, now)
	if s.Next(now) == nil {
		t.Fatal("explicit click after composition failed")
	}
}
func TestStaleResultCancelledWithoutAutomaticRetry(t *testing.T) {
	for _, change := range []string{"append", "edit", "caret", "selection", "target", "focus", "permission", "composition", "unknown-ime"} {
		t.Run(change, func(t *testing.T) {
			s, now := clicked("请修复代码")
			j := s.Next(now)
			v := s.Current
			switch change {
			case "append":
				v = draft(v.Text + "不要修改界面")
			case "edit":
				v = draft("请不要修复代码")
			case "caret":
				v.SelectionStart = 0
				v.AtEnd = false
			case "selection":
				v.SelectionLength = 1
				v.SelectionStart = 0
				v.AtEnd = false
			case "target":
				v.Target = "codex:2"
			case "focus":
				v = Snapshot{Trusted: true}
			case "permission":
				v.Trusted = false
			case "composition":
				v.Composing = true
			case "unknown-ime":
				v.CompositionKnown = false
			}
			s.Observe(v, now)
			if s.Complete(*j, "Fix code.", nil) != nil || s.Busy {
				t.Fatal("stale result accepted")
			}
			s.Observe(draft("请修复代码"), now.Add(time.Second))
			if s.Next(now.Add(time.Hour)) != nil {
				t.Fatal("returned focus or input retriggered old click")
			}
			s.Request(s.Current, now)
			if s.Next(now) == nil {
				t.Fatal("new click could not retry")
			}
		})
	}
}
func TestEditBeforeDispatchConsumesClick(t *testing.T) {
	s, now := clicked("你好")
	s.Observe(draft("你好世界"), now)
	if s.Next(now) != nil {
		t.Fatal("click applied to later draft")
	}
}
func TestRepeatedClicksDoNotQueue(t *testing.T) {
	s, now := clicked("你好")
	j := s.Next(now)
	s.Request(s.Current, now)
	if s.Next(now) != nil {
		t.Fatal("duplicate request")
	}
	r := s.Complete(*j, "Hello", nil)
	s.Acknowledge(r.ID, true, "")
	s.Observe(draft("Hello 又见面了"), now)
	if s.Next(now.Add(time.Hour)) != nil {
		t.Fatal("click queued next translation")
	}
}
func TestErrorsRequireExplicitRetry(t *testing.T) {
	s, now := clicked("测试")
	j := s.Next(now)
	s.Complete(*j, "", errors.New("HTTP 401"))
	if s.Busy || s.Next(now.Add(time.Hour)) != nil {
		t.Fatal("failure retried automatically")
	}
	s.Request(s.Current, now)
	if s.Next(now) == nil {
		t.Fatal("explicit retry failed")
	}
}
func TestInvalidClicksNeverBecomePending(t *testing.T) {
	for _, kind := range []string{"untrusted", "unsupported", "unknown", "invalid-selection", "no-Chinese", "incomplete-code"} {
		t.Run(kind, func(t *testing.T) {
			s := New()
			now := time.Now()
			v := draft("测试")
			switch kind {
			case "untrusted":
				v.Trusted = false
			case "unsupported":
				v.Editable = false
			case "unknown":
				v.CompositionKnown = false
			case "invalid-selection":
				v.SelectionStart = 10
			case "no-Chinese":
				v = draft("hello")
			case "incomplete-code":
				v = draft("检查 ```go")
			}
			s.Request(v, now)
			if s.Busy || s.Next(now) != nil {
				t.Fatal("invalid request allowed")
			}
			s.Observe(draft("有效草稿"), now)
			if s.Next(now.Add(time.Hour)) != nil {
				t.Fatal("invalid click deferred to future draft")
			}
		})
	}
}
func TestUndoWorksFromMiddleAndWaitsForExplicitClick(t *testing.T) {
	s, now := clicked("你好")
	j := s.Next(now)
	r := s.Complete(*j, "Hello", nil)
	s.Acknowledge(r.ID, true, "")
	v := draft(r.Text)
	v.SelectionStart = 1
	v.AtEnd = false
	s.Observe(v, now)
	r = s.Undo()
	if r == nil || r.Text != "你好" {
		t.Fatal("middle-caret restore failed")
	}
	s.Acknowledge(r.ID, true, "")
	s.Observe(draft("你好"), now)
	if s.Next(now.Add(time.Hour)) != nil {
		t.Fatal("undo translated automatically")
	}
	s.Request(s.Current, now)
	if s.Next(now) == nil {
		t.Fatal("cannot explicitly translate restored text")
	}
}
func TestCancelRejectsLateResult(t *testing.T) {
	s, now := clicked("测试")
	j := s.Next(now)
	s.Reset("取消")
	if s.Complete(*j, "Test", nil) != nil || s.Next(now.Add(time.Hour)) != nil {
		t.Fatal("cancelled request resumed")
	}
}
