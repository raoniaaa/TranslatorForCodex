using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Automation;
using NativeAutomation;

namespace Translator.Windows
{
    internal sealed class Composer
    {
        readonly IUIAutomation automation = new CUIAutomation();
        internal static string Target(AutomationElement element)
        {
            return element.Current.ProcessId + ":" + String.Join(".", element.GetRuntimeId());
        }
        internal bool Composition(AutomationElement element, out bool composing)
        {
            composing = false;
            var native = automation.GetFocusedElement();
            if (native == null || native.CurrentProcessId != element.Current.ProcessId ||
                !native.GetRuntimeId().SequenceEqual(element.GetRuntimeId())) return false;
            var pattern = native.GetCurrentPattern(10032) as IUIAutomationTextEditPattern;
            if (pattern == null) return false;
            composing = pattern.GetActiveComposition() != null;
            return true;
        }
        internal Dictionary<string, object> Capture(string type)
        {
            var result = new Dictionary<string, object> {
                { "type", type }, { "trusted", true }, { "supported", false },
                { "editable", false }, { "compositionKnown", false }, { "guard", "Windows UI Automation TextEdit" }
            };
            try
            {
                if (!Native.CodexForeground()) return result;
                var element = AutomationElement.FocusedElement;
                if (element == null || !Native.IsCodex(element.Current.ProcessId) ||
                    element.Current.ControlType != ControlType.Edit || element.Current.IsPassword ||
                    !element.Current.HasKeyboardFocus || element.Current.IsOffscreen) return result;
                // Only plain text: reject embedded controls (attachments/mentions).
                var child = TreeWalker.ControlViewWalker.GetFirstChild(element);
                int count = 0;
                while (child != null)
                {
                    if (++count > 100 || child.Current.ControlType != ControlType.Text) return result;
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                }
                bool composing;
                bool known = Composition(element, out composing);
                result["target"] = Target(element);
                result["compositionKnown"] = known;
                result["composing"] = composing;
                var draft = DraftAccess.Read(element);
                result["text"] = draft.Text;
                result["selectionStart"] = draft.SelectionStart;
                result["selectionLength"] = draft.SelectionLength;
                result["atEnd"] = draft.SelectionStart == draft.Text.Length && draft.SelectionLength == 0;
                result["supported"] = true;
                result["editable"] = true;
            }
            catch { result["supported"] = false; }
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
                return Composition(focused, out composing) && !composing;
            }
            catch { return false; }
        }
    }
}
