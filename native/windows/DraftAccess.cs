using System;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Translator.Windows
{
    // Keep text in memory only. The native host must also check target
    // application identity and IME composition before calling this adapter.
    internal sealed class DraftSnapshot
    {
        internal AutomationElement Element;
        internal string Text;
        internal int SelectionStart;
        internal int SelectionLength;
    }

    internal static class DraftAccess
    {
        internal static DraftSnapshot Read(AutomationElement element)
        {
            if (element == null) throw new InvalidOperationException("No input element.");
            var info = element.Current;
            if (info.IsPassword || !info.IsEnabled || info.ControlType != ControlType.Edit)
                throw new InvalidOperationException("Unsupported input element.");
            var value = (ValuePattern)element.GetCurrentPattern(ValuePattern.Pattern);
            if (value.Current.IsReadOnly) throw new InvalidOperationException("Read-only input.");
            var text = (TextPattern)element.GetCurrentPattern(TextPattern.Pattern);
            var selections = text.GetSelection();
            if (selections.Length != 1) throw new InvalidOperationException("Ambiguous selection.");
            string content = value.Current.Value;
            if (text.DocumentRange.GetText(-1) != content)
                throw new InvalidOperationException("Inconsistent text providers.");
            var prefix = text.DocumentRange.Clone();
            prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, selections[0], TextPatternRangeEndpoint.Start);
            int start = prefix.GetText(-1).Length;
            int length = selections[0].GetText(-1).Length;
            if (start > content.Length || length > content.Length - start)
                throw new InvalidOperationException("Invalid selection.");
            if (value.Current.Value != content)
                throw new InvalidOperationException("Draft changed while reading.");
            return new DraftSnapshot { Element = element, Text = content, SelectionStart = start, SelectionLength = length };
        }

        // stillSafe must verify focus, target identity, composition and new user
        // input. It is called immediately before writing and again before moving
        // the caret. No automatic retries or keyboard/clipboard fallbacks.
        internal static bool Replace(DraftSnapshot expected, string replacement,
            Func<bool> stillSafe, out bool caretAtEnd)
        {
            caretAtEnd = false;
            if (!stillSafe()) return false;
            var current = Read(expected.Element);
            if (current.Text != expected.Text || current.SelectionStart != expected.SelectionStart ||
                current.SelectionLength != expected.SelectionLength || !stillSafe()) return false;
            var value = (ValuePattern)expected.Element.GetCurrentPattern(ValuePattern.Pattern);
            value.SetValue(replacement);
            // Electron may update its accessibility text and reset selection on
            // a later frame. Move the caret once, only if no input intervened.
            Thread.Sleep(200);
            if (value.Current.Value != replacement) return false;
            if (!stillSafe()) return true; // Text changed; do not fight new input.
            var text = (TextPattern)expected.Element.GetCurrentPattern(TextPattern.Pattern);
            if (text.DocumentRange.GetText(-1) != replacement) return true;
            var end = text.DocumentRange.Clone();
            end.MoveEndpointByRange(TextPatternRangeEndpoint.Start, end, TextPatternRangeEndpoint.End);
            if (!stillSafe()) return true;
            end.Select();
            var actual = Read(expected.Element);
            caretAtEnd = actual.Text == replacement && actual.SelectionStart == replacement.Length && actual.SelectionLength == 0;
            return true;
        }
    }
}
