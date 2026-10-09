using System;
using System.Collections.Generic;

namespace Translator.Windows
{
    internal sealed class CompositionStates
    {
        readonly Dictionary<string, CompositionState> states = new Dictionary<string, CompositionState>();
        internal CompositionState For(string target)
        {
            CompositionState state;
            target = target ?? "";
            if (!states.TryGetValue(target, out state)) {
                if (states.Count >= 64) states.Clear();
                states[target] = state = new CompositionState();
            }
            return state;
        }
    }
    // Chromium retains the last TSF range after commitment. Its Composition
    // event carries the full, uncommitted string; newer Chromium builds omit
    // CompositionFinalized and only raise ordinary TextChanged on commitment.
    // Match the queried range against the last active event instead of treating
    // every non-null range as proof of ongoing composition. Text stays in memory.
    internal sealed class CompositionState
    {
        string activeText;
        int changedAt;
        bool changed;
        internal bool Observed { get { return activeText != null; } }
        internal bool Finalized { get; private set; }
        internal int TextLength { get { return activeText == null ? -1 : activeText.Length; } }
        internal void Observe(string text, bool finalized, int tick)
        {
            activeText = text; Finalized = finalized; changed = false; changedAt = tick;
        }
        internal void Changed(int tick) { changed = true; changedAt = tick; }
        internal bool Resolve(bool hasRange, string rangeText, int tick, out bool composing)
        {
            composing = hasRange;
            if (!hasRange || !Observed) return true;
            if (rangeText == activeText && !Finalized) return true;
            // A TextChanged event alone also occurs during preedit. Require
            // both a different range value and a quiet event stream. A new
            // Composition event always restores the active guard.
            if (!Finalized && !changed) return true;
            if (unchecked((uint)(tick - changedAt)) < 180) return false;
            composing = false;
            return true;
        }
    }
}
