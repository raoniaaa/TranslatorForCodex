using System;
using System.Collections.Generic;
using System.Windows.Automation;

namespace Translator.Windows
{
    internal static class PlainTextContent
    {
        internal static bool IsSupported(AutomationElement editor)
        {
            return IsSupported(Children(editor), element => element.Current.ControlType,
                element => element.Current.IsKeyboardFocusable, Children);
        }
        static IEnumerable<AutomationElement> Children(AutomationElement parent)
        {
            var walker = TreeWalker.ControlViewWalker;
            var child = walker.GetFirstChild(parent);
            while (child != null) { yield return child; child = walker.GetNextSibling(child); }
        }
        internal static bool IsSupported<T>(IEnumerable<T> roots, Func<T, ControlType> type,
            Func<T, bool> focusable, Func<T, IEnumerable<T>> children)
        {
            var stack = new Stack<KeyValuePair<T, int>>();
            int discovered = 0;
            foreach (var root in roots) {
                if (++discovered > 300) return false;
                stack.Push(new KeyValuePair<T, int>(root, 0));
            }
            while (stack.Count > 0) {
                var next = stack.Pop();
                var kind = type(next.Key);
                // HTML pasted into contenteditable can expose paragraph groups
                // and lists. Inspect their descendants instead of rejecting the
                // container; interactive controls and embedded objects stop here.
                if (next.Value > 32 || focusable(next.Key) ||
                    (kind != ControlType.Text && kind != ControlType.Group &&
                     kind != ControlType.List && kind != ControlType.ListItem)) return false;
                foreach (var child in children(next.Key)) {
                    if (++discovered > 300) return false;
                    stack.Push(new KeyValuePair<T, int>(child, next.Value + 1));
                }
            }
            return true;
        }
    }
}
