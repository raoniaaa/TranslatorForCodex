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
func armed(text string) (*State, time.Time) {
	s := New()
	s.DelayMS = 800
	now := time.Now()
	s.Observe(draft(text), now)
	s.Toggle(now)
	return s, now
}
func TestWaitsForCandidateToDisappear(t *testing.T) {
	s, now := armed("你好ni hao")
	v := s.Current
	v.Composing = true
	s.Observe(v, now)
	if s.Next(now.Add(5*time.Second)) != nil {
		t.Fatal("translated unfinished composition")
	}
	v.Composing = false
	v.Text = "你好你好"
	s.Observe(v, now.Add(6*time.Second))
	if s.Next(now.Add(6100*time.Millisecond)) != nil {
		t.Fatal("commit bypassed quiet period")
	}
	if s.Next(now.Add(7*time.Second)) == nil {
		t.Fatal("did not translate after quiet period")
	}
}
func TestStaleResultCannotReplaceEditedDraft(t *testing.T) {
	s, now := armed("请修复代码")
	j := s.Next(now.Add(time.Second))
	if j == nil {
		t.Fatal("missing job")
	}
	s.Observe(draft("请不要修复代码"), now.Add(2*time.Second))
	if s.Complete(*j, "Please fix the code.", nil) != nil {
		t.Fatal("stale translation would overwrite new draft")
	}
}
func TestFocusChangeCancelsAndKeepsModeEnabled(t *testing.T) {
	s, now := armed("测试")
	j := s.Next(now.Add(time.Second))
	v := draft("测试")
	v.Target = "codex:2"
	s.Observe(v, now.Add(2*time.Second))
	if !s.Armed || s.Complete(*j, "Test", nil) != nil {
		t.Fatal("cross-field write permitted")
	}
}
func TestUnknownIMEAndSelectionDoNotTranslate(t *testing.T) {
	for _, kind := range []string{"unknown", "selection", "caret"} {
		t.Run(kind, func(t *testing.T) {
			s, now := armed("测试")
			v := s.Current
			switch kind {
			case "unknown":
				v.CompositionKnown = false
			case "selection":
				v.SelectionLength = 2
			case "caret":
				v.AtEnd = false
			}
			s.Observe(v, now)
			if s.Next(now.Add(time.Second)) != nil {
				t.Fatal("unsafe state translated")
			}
		})
	}
}
func translated(t *testing.T) (*State, time.Time) {
	t.Helper()
	s, now := armed("你好")
	j := s.Next(now.Add(time.Second))
	r := s.Complete(*j, "Hello", nil)
	if r == nil {
		t.Fatal("missing replacement")
	}
	s.Acknowledge(r.ID, true, "")
	s.Observe(draft("Hello"), now.Add(2*time.Second))
	return s, now
}
func TestAppendRetranslatesWholeOriginal(t *testing.T) {
	s, now := translated(t)
	s.Observe(draft("Hello，明天见"), now.Add(3*time.Second))
	j := s.Next(now.Add(4 * time.Second))
	if j == nil || j.Source != "你好，明天见" {
		t.Fatalf("lost whole original: %+v", j)
	}
	r := s.Complete(*j, "Hello, see you tomorrow.", nil)
	if r == nil || r.ReplaceStart != 0 || r.InsertText != r.Text {
		t.Fatal("not a whole draft replacement")
	}
	s.Acknowledge(r.ID, true, "")
	s.Observe(draft(r.Text), now.Add(5*time.Second))
	restored := s.Undo()
	if restored == nil || restored.Text != "Hello，明天见" {
		t.Fatal("undo failed to restore exact previous draft")
	}
}

func TestNativeUndoIsNotRetranslated(t *testing.T) {
	s, now := translated(t)
	s.Observe(draft("你好"), now.Add(3*time.Second))
	if s.Next(now.Add(5*time.Second)) != nil {
		t.Fatal("undo caused translation loop")
	}
	s.Observe(draft("你好啊"), now.Add(6*time.Second))
	if s.Next(now.Add(7*time.Second)) == nil {
		t.Fatal("editing should resume translation")
	}
}
func TestRestoreDoesNotTranslateChineseAgain(t *testing.T) {
	s, now := translated(t)
	r := s.Undo()
	if r == nil || r.Text != "你好" {
		t.Fatal("incorrect restore")
	}
	s.Acknowledge(r.ID, true, "")
	s.Observe(draft("你好"), now.Add(3*time.Second))
	if s.Next(now.Add(5*time.Second)) != nil {
		t.Fatal("restore caused translation loop")
	}
}
func TestErrorDoesNotRetryContinuously(t *testing.T) {
	s, now := armed("测试")
	j := s.Next(now.Add(time.Second))
	s.Complete(*j, "", errors.New("HTTP 401"))
	if s.Phase != "error" || s.Next(now.Add(10*time.Second)) != nil {
		t.Fatal("failed request retried without new input")
	}
}
func TestIncompleteCodeBlockWaits(t *testing.T) {
	s, now := armed("修复：\n```go\nfunc main()")
	if s.Next(now.Add(time.Second)) != nil {
		t.Fatal("translated incomplete code block")
	}
}

func TestProtectedChineseInOutputDoesNotLoop(t *testing.T) {
	s, now := armed("检查 `中文变量`")
	job := s.Next(now.Add(time.Second))
	r := s.Complete(*job, "Check `中文变量`", nil)
	s.Acknowledge(r.ID, true, "")
	s.Observe(draft("Check `中文变量`"), now.Add(2*time.Second))
	if s.Next(now.Add(4*time.Second)) != nil {
		t.Fatal("protected Chinese triggered a translation loop")
	}
}

func TestModeResumesAfterLeavingComposer(t *testing.T) {
	s, now := armed("第一段")
	oldJob := s.Next(now.Add(time.Second))
	s.Observe(Snapshot{Trusted: true}, now.Add(2*time.Second))
	if !s.Armed || s.Phase != "waiting-focus" || s.Next(now.Add(10*time.Second)) != nil {
		t.Fatal("focus loss disabled mode or allowed a request")
	}
	if s.Complete(*oldJob, "old output", nil) != nil {
		t.Fatal("stale response survived focus loss")
	}
	s.Observe(draft("第二段"), now.Add(11*time.Second))
	if s.Next(now.Add(11500*time.Millisecond)) != nil {
		t.Fatal("return skipped debounce")
	}
	job := s.Next(now.Add(12 * time.Second))
	if job == nil || job.Source != "第二段" {
		t.Fatal("return did not resume without toggling")
	}
}
func TestEnableBeforePermissionAndFocus(t *testing.T) {
	s := New()
	s.DelayMS = 800
	now := time.Now()
	s.Toggle(now)
	if !s.Armed || s.Phase != "permission" || s.Next(now.Add(time.Second)) != nil {
		t.Fatal("mode intent lost while awaiting permission")
	}
	s.Observe(Snapshot{Trusted: true}, now.Add(2*time.Second))
	if !s.Armed || s.Phase != "waiting-focus" {
		t.Fatal("grant without focus disabled mode")
	}
	s.Observe(draft("授权后继续"), now.Add(3*time.Second))
	if s.Next(now.Add(4*time.Second)) == nil {
		t.Fatal("grant and focus did not automatically resume")
	}
}
func TestExplicitOffStaysOffAfterRefocusing(t *testing.T) {
	s, now := armed("测试")
	job := s.Next(now.Add(time.Second))
	s.Toggle(now.Add(2 * time.Second))
	s.Observe(Snapshot{Trusted: true}, now.Add(3*time.Second))
	s.Observe(draft("新的草稿"), now.Add(4*time.Second))
	if s.Armed || s.Next(now.Add(6*time.Second)) != nil || s.Complete(*job, "test", nil) != nil {
		t.Fatal("explicitly disabled mode resumed or wrote a stale result")
	}
}
func TestPermissionRevokedCancelsWithoutDisabling(t *testing.T) {
	s, now := armed("测试")
	job := s.Next(now.Add(time.Second))
	v := s.Current
	v.Trusted = false
	s.Observe(v, now.Add(2*time.Second))
	if !s.Armed || s.Next(now.Add(3*time.Second)) != nil || s.Complete(*job, "test", nil) != nil {
		t.Fatal("revocation allowed translation or disabled intent")
	}
	v.Trusted = true
	s.Observe(v, now.Add(4*time.Second))
	if s.Next(now.Add(5*time.Second)) == nil {
		t.Fatal("restoring permission did not resume")
	}
}
func TestFocusReturnKeepsUndoAndProtectedTextSuppressed(t *testing.T) {
	for _, undo := range []bool{false, true} {
		s, now := armed("检查 `中文变量`")
		job := s.Next(now.Add(time.Second))
		r := s.Complete(*job, "Check `中文变量`", nil)
		s.Acknowledge(r.ID, true, "")
		s.Observe(draft(r.Text), now.Add(2*time.Second))
		if undo {
			r = s.Undo()
			s.Acknowledge(r.ID, true, "")
			s.Observe(draft(r.Text), now.Add(3*time.Second))
		}
		current := s.Current
		s.Observe(Snapshot{Trusted: true}, now.Add(4*time.Second))
		s.Observe(current, now.Add(5*time.Second))
		if !s.Armed || s.Next(now.Add(6*time.Second)) != nil {
			t.Fatal("return retriggered unchanged protected/undone text")
		}
	}
}

func TestReplacementOffsetsUseUTF16(t *testing.T) {
	r := makeReplacement(1, draft("Hi 😀你好!"), "Hi 😀hello!")
	if r.ReplaceStart != 0 || r.ReplaceLength != 8 || r.InsertText != r.Text {
		t.Fatalf("bad whole UTF-16 write: %+v", r)
	}
}
func TestAppendEnglishDoesNotRetranslateProtectedChinese(t *testing.T) {
	s, now := armed("检查 `中文变量`")
	j := s.Next(now.Add(time.Second))
	r := s.Complete(*j, "Check `中文变量`", nil)
	s.Acknowledge(r.ID, true, "")
	s.Observe(draft(r.Text+" please"), now.Add(2*time.Second))
	if s.Next(now.Add(3*time.Second)) != nil {
		t.Fatal("English append retranslates old protected Chinese")
	}
}

func TestAppendingDuringRequestCancelsWholeResult(t *testing.T) {
	for _, composing := range []bool{false, true} {
		s, now := armed("你好")
		j := s.Next(now.Add(time.Second))
		v := draft("你好明天见")
		v.Composing = composing
		s.Observe(v, now.Add(2*time.Second))
		if s.Complete(*j, "Hello", nil) != nil {
			t.Fatal("old result overwrote continued input")
		}
		if s.Next(now.Add(2100*time.Millisecond)) != nil {
			t.Fatal("did not debounce continued input")
		}
		if composing && s.Next(now.Add(10*time.Second)) != nil {
			t.Fatal("translated while composing")
		}
	}
}
func TestDefaultQuietPeriod(t *testing.T) {
	s := New()
	now := time.Now()
	s.Observe(draft("完整的句子"), now)
	s.Toggle(now)
	if s.Next(now.Add(1900*time.Millisecond)) != nil {
		t.Fatal("translated too early")
	}
	if s.Next(now.Add(2100*time.Millisecond)) == nil {
		t.Fatal("did not translate complete draft")
	}
}
