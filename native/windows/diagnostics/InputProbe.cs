// Read-only UI Automation probe. Reports capabilities, never draft contents.
// Run in the signed-in user's interactive desktop, not an SSH service session.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;

class InputProbe
{
    static bool IsCodex(int pid)
    {
        try
        {
            string path = Process.GetProcessById(pid).MainModule.FileName;
            return path.IndexOf(@"\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0
                && Path.GetFileName(path).Equals("ChatGPT.exe", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    static object Describe(AutomationElement element)
    {
        var info = element.Current;
        var result = new Dictionary<string, object>();
        result["controlType"] = info.ControlType.ProgrammaticName;
        result["focused"] = info.HasKeyboardFocus;
        result["enabled"] = info.IsEnabled;
        result["offscreen"] = info.IsOffscreen;
        result["password"] = info.IsPassword;
        var patterns = new List<string>();
        foreach (var pattern in element.GetSupportedPatterns()) patterns.Add(pattern.ProgrammaticName);
        result["patterns"] = patterns;
        if (info.IsPassword) return result;
        object value;
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out value))
        {
            var current = ((ValuePattern)value).Current;
            result["valueReadOnly"] = current.IsReadOnly;
            result["valueLength"] = current.Value.Length;
        }
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out value))
        {
            var text = (TextPattern)value;
            result["textLength"] = text.DocumentRange.GetText(-1).Length;
            var selections = new List<int>();
            foreach (var selection in text.GetSelection()) selections.Add(selection.GetText(-1).Length);
            result["selectionLengths"] = selections;
        }
        return result;
    }

    static object Sample()
    {
        var result = new Dictionary<string, object>();
        result["sessionId"] = Process.GetCurrentProcess().SessionId;
        var focused = AutomationElement.FocusedElement;
        result["codexFocused"] = focused != null && IsCodex(focused.Current.ProcessId);
        if ((bool)result["codexFocused"]) result["focusedElement"] = Describe(focused);
        var candidates = new List<object>();
        var timer = Stopwatch.StartNew();
        int visited = 0;
        foreach (var process in Process.GetProcessesByName("ChatGPT"))
        {
            if (!IsCodex(process.Id) || process.MainWindowHandle == IntPtr.Zero) continue;
            var queue = new Queue<AutomationElement>();
            queue.Enqueue(AutomationElement.FromHandle(process.MainWindowHandle));
            while (queue.Count > 0 && visited < 3000 && timer.ElapsedMilliseconds < 6000)
            {
                var element = queue.Dequeue();
                visited++;
                var type = element.Current.ControlType;
                if (type == ControlType.Edit || type == ControlType.Document)
                    candidates.Add(Describe(element));
                var child = TreeWalker.ControlViewWalker.GetFirstChild(element);
                while (child != null && queue.Count < 3000 && timer.ElapsedMilliseconds < 6000)
                {
                    queue.Enqueue(child);
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                }
            }
        }
        result["visited"] = visited;
        result["candidates"] = candidates;
        return result;
    }

    [MTAThread]
    static int Main(string[] args)
    {
        if (args.Length != 1) return 2;
        var samples = new List<object>();
        for (int i = 0; i < 3; i++)
        {
            try { samples.Add(Sample()); }
            catch (Exception error) { samples.Add(new { errorType = error.GetType().Name }); }
            // Each completed sample survives a provider hanging on a later call.
            File.WriteAllText(args[0], new JavaScriptSerializer().Serialize(samples));
            if (i < 2) Thread.Sleep(1500);
        }
        return 0;
    }
}
