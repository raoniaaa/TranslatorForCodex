using System;
using System.Runtime.InteropServices;
using NativeAutomation;

namespace Translator.Windows
{
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class CompositionEvents : IUIAutomationTextEditTextChangedEventHandler, IUIAutomationEventHandler
    {
        readonly object sync = new object();
        readonly CompositionStates states = new CompositionStates();
        static string Target(IUIAutomationElement sender)
        {
            if (sender == null || sender.CurrentControlType != 50004 || sender.CurrentIsPassword != 0 ||
                sender.CurrentHasKeyboardFocus == 0 || !Native.IsCodex(sender.CurrentProcessId)) return null;
            return sender.CurrentProcessId + ":" + String.Join(".", sender.GetRuntimeId());
        }
        public void HandleTextEditTextChangedEvent(IUIAutomationElement sender, TextEditChangeType kind, string[] strings)
        {
            if (strings == null || strings.Length != 1) return;
            try {
                string target = Target(sender);
                if (target == null) return;
                lock (sync) {
                    if (kind == TextEditChangeType.TextEditChangeType_Composition)
                        states.For(target).Observe(strings[0], false, Environment.TickCount);
                    else if (kind == TextEditChangeType.TextEditChangeType_CompositionFinalized)
                        states.For(target).Observe(strings[0], true, Environment.TickCount);
                }
            } catch { }
        }
        public void HandleAutomationEvent(IUIAutomationElement sender, int eventId)
        {
            try {
                string target = Target(sender);
                if (target != null) lock (sync) states.For(target).Changed(Environment.TickCount);
            } catch { }
        }
        internal bool Resolve(string target, bool hasRange, string rangeText, out bool composing)
        {
            lock (sync) return states.For(target).Resolve(hasRange, rangeText, Environment.TickCount, out composing);
        }
        internal object Metadata(string target)
        {
            lock (sync) {
                var state = states.For(target);
                return new { observed = state.Observed, finalized = state.Finalized, textLength = state.TextLength };
            }
        }
    }
}
