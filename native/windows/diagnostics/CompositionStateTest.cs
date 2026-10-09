using System;
using Translator.Windows;

class CompositionStateTest
{
    static int Main()
    {
        try {
            bool composing;
            var state = new CompositionState();
            Check(state.Resolve(true, "你好", 1000, out composing) && composing,
                "an unobserved retained range remains protected");
            Check(state.Resolve(false, "", 1000, out composing) && !composing,
                "an absent composition range is idle");
            state.Observe("nihao", false, 1000);
            state.Changed(1050);
            Check(state.Resolve(true, "nihao", 5000, out composing) && composing,
                "ordinary text events and a long pause do not finalize preedit");
            Check(!state.Resolve(true, "你好", 1100, out composing) && composing,
                "a recent mismatching range waits for event delivery");
            Check(state.Resolve(true, "你好", 1300, out composing) && !composing,
                "committed Chinese is accepted despite Chromium's retained range");
            state.Observe("shijie", false, 1400);
            state.Changed(1450);
            Check(state.Resolve(true, "shijie", 3000, out composing) && composing,
                "a new composition restores protection after commitment");
            var missingChange = new CompositionState();
            missingChange.Observe("nihao", false, 1000);
            Check(missingChange.Resolve(true, "你好", 3000, out composing) && composing,
                "a range mismatch without a text change does not authorize writing");
            state.Observe("世界", true, 3100);
            Check(!state.Resolve(true, "世界", 3150, out composing),
                "explicit finalized events also wait for delivery to settle");
            Check(state.Resolve(true, "世界", 3400, out composing) && !composing,
                "providers that emit finalized events remain supported");
            state.Observe("ni", false, 3500);
            state.Changed(3550);
            Check(state.Resolve(true, "ni", 4000, out composing) && composing,
                "new active events supersede previous finalized events");
            state.Changed(4100);
            Check(state.Resolve(true, "", 4400, out composing) && !composing,
                "cancelled preedit can clear a retained empty range");
            state.Observe("nihao", false, Int32.MaxValue - 100);
            state.Changed(Int32.MaxValue - 50);
            Check(state.Resolve(true, "你好", Int32.MinValue + 150, out composing) && !composing,
                "the settling interval works across TickCount wraparound");
            var editors = new CompositionStates();
            editors.For("chat-one:editor").Observe("nihao", false, 1000);
            editors.For("chat-one:editor").Changed(1100);
            Check(editors.For("chat-one:editor").Resolve(true, "你好", 1500, out composing) && !composing,
                "the first chat's committed draft is accepted");
            Check(editors.For("chat-two:editor").Resolve(true, "nihao", 1500, out composing) && composing,
                "switching chats never borrows another editor's commit state");
            editors.For("chat-two:editor").Observe("shijie", false, 1600);
            editors.For("chat-two:editor").Changed(1700);
            Check(editors.For("chat-two:editor").Resolve(true, "世界", 2000, out composing) && !composing,
                "the second chat tracks its own composition and commitment");
            Check(editors.For("chat-one:editor").Resolve(true, "你好", 2100, out composing) && !composing,
                "returning to the first editor preserves only its own state");
            return 0;
        } catch (Exception error) { Console.Error.WriteLine("FAIL: " + error.Message); return 1; }
    }
    static void Check(bool valid, string label)
    {
        if (!valid) throw new InvalidOperationException(label);
        Console.WriteLine("PASS: " + label);
    }
}
