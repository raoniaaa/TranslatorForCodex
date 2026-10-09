using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Windows.Automation;
using NativeAutomation;

namespace Translator.Windows
{
    internal sealed class Composer
    {
        readonly IUIAutomation automation = new CUIAutomation8();
        CompositionEvents compositionEvents = new CompositionEvents();
        IUIAutomationElement watchedElement;
        IntPtr watchedWindow;
        string lastTarget;
        internal object CompositionEventMetadata() { return compositionEvents.Metadata(lastTarget); }
        void Unwatch()
        {
            var events = (IUIAutomation3)automation;
            if (watchedElement != null) {
                try { events.RemoveTextEditTextChangedEventHandler(watchedElement, compositionEvents); } catch { }
                try { events.RemoveAutomationEventHandler(20015, watchedElement, compositionEvents); } catch { }
            }
            watchedElement = null; watchedWindow = IntPtr.Zero;
        }
        void WatchWindow()
        {
            IntPtr window = Native.GetForegroundWindow();
            if (window == watchedWindow) return;
            Unwatch();
            compositionEvents = new CompositionEvents();
            var events = (IUIAutomation3)automation;
            watchedElement = automation.ElementFromHandle(window);
            try {
                // The composer is recreated when switching chats. Subscribe to
                // the Codex window before locating its focused editor, and keep
                // event state separate for each editor's runtime identity.
                events.AddTextEditTextChangedEventHandler(watchedElement, NativeAutomation.TreeScope.TreeScope_Subtree, TextEditChangeType.TextEditChangeType_Composition, null, compositionEvents);
                events.AddTextEditTextChangedEventHandler(watchedElement, NativeAutomation.TreeScope.TreeScope_Subtree, TextEditChangeType.TextEditChangeType_CompositionFinalized, null, compositionEvents);
                events.AddAutomationEventHandler(20015, watchedElement, NativeAutomation.TreeScope.TreeScope_Subtree, null, compositionEvents);
                watchedWindow = window;
            } catch { Unwatch(); throw; }
        }
        internal int ActiveCompositionLength = -1;
        internal string CaptureStage = "idle";
        internal static string Target(AutomationElement element)
        {
            return element.Current.ProcessId + ":" + String.Join(".", element.GetRuntimeId());
        }
        internal bool Composition(AutomationElement element, out bool composing)
        {
            composing = false;
            ActiveCompositionLength = -1;
            var native = automation.GetFocusedElement();
            if (native == null || native.CurrentProcessId != element.Current.ProcessId ||
                !native.GetRuntimeId().SequenceEqual(element.GetRuntimeId())) return false;
            string target = Target(element);
            lastTarget = target;
            var pattern = native.GetCurrentPattern(10032) as IUIAutomationTextEditPattern;
            if (pattern == null) return false;
            var range = pattern.GetActiveComposition();
            string rangeText = range == null ? "" : range.GetText(-1);
            ActiveCompositionLength = rangeText.Length;
            if (compositionEvents.Resolve(target, range != null, rangeText, out composing)) return true;
            Thread.Sleep(200);
            var focused = automation.GetFocusedElement();
            if (focused == null || !Native.CodexForeground() || focused.CurrentProcessId != element.Current.ProcessId ||
                !focused.GetRuntimeId().SequenceEqual(element.GetRuntimeId())) return false;
            var fresh = pattern.GetActiveComposition();
            string freshText = fresh == null ? "" : fresh.GetText(-1);
            ActiveCompositionLength = freshText.Length;
            return compositionEvents.Resolve(target, fresh != null, freshText, out composing);
        }
        internal Dictionary<string, object> Capture(string type)
        {
            CaptureStage = "foreground";
            var result = new Dictionary<string, object> {
                { "type", type }, { "trusted", true }, { "supported", false },
                { "editable", false }, { "compositionKnown", false }, { "guard", "Windows UI Automation TextEdit" }
            };
            try
            {
                if (!Native.CodexForeground()) return result;
                WatchWindow();
                CaptureStage = "focused-editor";
                var element = AutomationElement.FocusedElement;
                if (element == null || !Native.IsCodex(element.Current.ProcessId) ||
                    element.Current.ControlType != ControlType.Edit || element.Current.IsPassword ||
                    !element.Current.HasKeyboardFocus || element.Current.IsOffscreen) return result;
                CaptureStage = "plain-text";
                if (!PlainTextContent.IsSupported(element)) return result;
                CaptureStage = "read-draft";
                var draft = DraftAccess.Read(element);
                CaptureStage = "composition";
                bool composing;
                bool known = Composition(element, out composing);
                CaptureStage = "recheck-draft";
                var freshDraft = DraftAccess.Read(element);
                if (draft.Text != freshDraft.Text || draft.SelectionStart != freshDraft.SelectionStart ||
                    draft.SelectionLength != freshDraft.SelectionLength) return result;
                result["target"] = Target(element);
                result["compositionKnown"] = known;
                result["composing"] = composing;
                result["text"] = draft.Text;
                result["selectionStart"] = draft.SelectionStart;
                result["selectionLength"] = draft.SelectionLength;
                result["atEnd"] = draft.SelectionStart == draft.Text.Length && draft.SelectionLength == 0;
                result["supported"] = true;
                result["editable"] = true;
                CaptureStage = "ready";
            }
            catch (Exception error) { CaptureStage += ":" + error.GetType().Name; result["supported"] = false; }
            return result;
        }
        internal bool Safe(AutomationElement element, string target, uint inputTick)
        {
            try
            {
                if (Native.InputTick() != inputTick || !Native.CodexForeground()) return false;
                var focused = AutomationElement.FocusedElement;
                if (focused == null || Target(focused) != target || !focused.Current.HasKeyboardFocus ||
                    !Native.IsCodex(focused.Current.ProcessId) || !Automation.Compare(element, focused)) return false;
                bool composing;
                return Composition(focused, out composing) && !composing && Native.InputTick() == inputTick && Native.CodexForeground();
            }
            catch { return false; }
        }
    }
}
