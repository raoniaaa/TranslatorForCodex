using System;
using System.Diagnostics;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using Translator.Windows;

class DraftAccessTest
{
    static readonly string Source = "Hello 😀你好，明天见";
    static readonly string Translation = "Hello 😀 See you tomorrow.";

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--fixture")
        {
            var field = new TextBox { Text = Source, AcceptsReturn = true };
            var window = new Window { Title = "Translator isolated test", Content = field, Width = 400, Height = 200 };
            // A failed/terminated parent must not leave a fixture running.
            var expiry = new DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
            expiry.Tick += delegate { expiry.Stop(); window.Close(); };
            expiry.Start();
            window.Loaded += delegate { field.Focus(); field.Select(3, 2); Console.WriteLine(new WindowInteropHelper(window).Handle.ToInt64()); };
            new Application().Run(window);
            return 0;
        }
        // Deliberately refuse the interactive desktop: this fixture must never
        // interrupt a user's Codex draft or steal their focus.
        if (Process.GetCurrentProcess().SessionId != 0)
        {
            Console.Error.WriteLine("Run this fixture in an isolated service/SSH session.");
            return 2;
        }
        int code = 1;
        var worker = new Thread(delegate() {
            try { Run(); code = 0; }
            catch (Exception error) { Console.Error.WriteLine("FAIL: " + error.GetType().Name + ": " + error.Message); }
        });
        worker.SetApartmentState(ApartmentState.MTA);
        worker.IsBackground = true;
        worker.Start();
        if (!worker.Join(25000)) Console.Error.WriteLine("FAIL: UI Automation timed out.");
        return code;
    }

    static void Check(bool result, string name)
    {
        if (!result) throw new InvalidOperationException(name);
        Console.WriteLine("PASS: " + name);
    }

    static void Run()
    {
        var child = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--fixture") { UseShellExecute = false, RedirectStandardOutput = true });
        long windowHandle = 0;
        child.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args) {
            long handle;
            if (long.TryParse(args.Data, out handle)) Interlocked.Exchange(ref windowHandle, handle);
        };
        child.BeginOutputReadLine();
        try
        {
            AutomationElement field = null;
            var timer = Stopwatch.StartNew();
            while (field == null && timer.ElapsedMilliseconds < 10000)
            {
                Thread.Sleep(100);
                child.Refresh();
                if (child.HasExited) throw new InvalidOperationException("Fixture exited: " + child.ExitCode);
                if (Interlocked.Read(ref windowHandle) == 0) continue;
                field = AutomationElement.FromHandle(new IntPtr(Interlocked.Read(ref windowHandle))).FindFirst(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
            }
            if (field == null) throw new InvalidOperationException("Fixture unavailable.");
            var original = DraftAccess.Read(field);
            Check(original.Text == Source && original.SelectionStart == 3 && original.SelectionLength == 2,
                "read full draft with a middle selection and emoji");
            bool caret;
            Check(!DraftAccess.Replace(original, Translation, delegate { return false; }, out caret)
                && DraftAccess.Read(field).Text == Source, "reject unsafe input state without changing text");
            var value = (ValuePattern)field.GetCurrentPattern(ValuePattern.Pattern);
            value.SetValue("User edited this draft");
            Check(!DraftAccess.Replace(original, Translation, delegate { return true; }, out caret)
                && DraftAccess.Read(field).Text == "User edited this draft", "reject stale text");
            value.SetValue(Source);
            var text = (TextPattern)field.GetCurrentPattern(TextPattern.Pattern);
            var start = text.DocumentRange.Clone();
            start.MoveEndpointByRange(TextPatternRangeEndpoint.End, start, TextPatternRangeEndpoint.Start);
            start.Select();
            var beforeSelection = DraftAccess.Read(field);
            var end = text.DocumentRange.Clone();
            end.MoveEndpointByRange(TextPatternRangeEndpoint.Start, end, TextPatternRangeEndpoint.End);
            end.Select();
            Check(!DraftAccess.Replace(beforeSelection, Translation, delegate { return true; }, out caret), "reject changed selection");
            start.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, 3);
            start.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, 2);
            start.Select();
            var ready = DraftAccess.Read(field);
            Check(DraftAccess.Replace(ready, Translation, delegate { return true; }, out caret)
                && caret && DraftAccess.Read(field).Text == Translation, "replace whole draft and place caret at end");
            var translated = DraftAccess.Read(field);
            int guardChecks = 0;
            Check(DraftAccess.Replace(translated, Source, delegate { return ++guardChecks <= 2; }, out caret)
                && !caret && DraftAccess.Read(field).Text == Source, "skip caret correction when safety changes after writing");
        }
        finally
        {
            if (!child.HasExited) child.Kill();
            child.Dispose();
        }
    }
}
