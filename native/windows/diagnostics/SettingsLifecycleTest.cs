// Runs the actual settings window on the isolated SSH desktop, never the user's.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

class SettingsLifecycleTest
{
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr w, IntPtr l);
    static readonly List<string> results = new List<string>();
    static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
        results.Add("PASS: " + description);
    }
    // Session 0 has no Explorer shell. Check WPF visibility and native minimize
    // state here; verify the actual taskbar button on the interactive desktop.
    static bool WaitFor(Func<bool> condition)
    {
        if (condition()) return true;
        var frame = new DispatcherFrame();
        var elapsed = Stopwatch.StartNew();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(25) };
        timer.Tick += delegate { if (condition() || elapsed.ElapsedMilliseconds > 2000) frame.Continue = false; };
        timer.Start();
        try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
        return condition();
    }
    [STAThread] static int Main(string[] args)
    {
        if (args.Length != 2 || Process.GetCurrentProcess().SessionId != 0) return 2;
        string config = Path.Combine(Path.GetTempPath(), "TranslatorWindowTest-" + Guid.NewGuid().ToString("N"));
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        int code = 1;
        Window window = null;
        Type type = null;
        bool closed = false;
        app.Startup += delegate {
            try {
                var assembly = Assembly.LoadFrom(Path.GetFullPath(args[0]));
                type = assembly.GetType("Translator.Windows.SettingsWindow", true);
                window = (Window)Activator.CreateInstance(type, BindingFlags.Instance | BindingFlags.NonPublic,
                    null, new object[] { "http://127.0.0.1:1/fixture/", config }, null);
                window.Closed += delegate { closed = true; };
                app.MainWindow = window;
                window.Show();
                app.Dispatcher.BeginInvoke(new Action(delegate {
                    try {
                        var handle = new WindowInteropHelper(window).Handle;
                        Check(window.ShowInTaskbar && (GetWindowLong(handle, -20) & 0x40000) != 0,
                            "settings has a taskbar application window");
                        Check(window.Icon != null && SendMessage(handle, 0x7F, new IntPtr(1), IntPtr.Zero) != IntPtr.Zero,
                            "settings exposes its application icon to Windows");
                        type.GetMethod("MinimizeToTaskbar", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(window, null);
                        Check(WaitFor(delegate { return window.IsVisible && IsIconic(handle); }), "returning to Codex minimizes without hiding settings");
                        window.WindowState = WindowState.Normal;
                        Check(WaitFor(delegate { return window.IsVisible && !IsIconic(handle); }), "settings restores after returning to Codex");
                        window.Close();
                        Check(WaitFor(delegate { return !closed && window.IsVisible && IsIconic(handle); }), "close button preserves the taskbar entry");
                        window.WindowState = WindowState.Normal;
                        Check(WaitFor(delegate { return !closed && window.IsVisible && !IsIconic(handle); }), "minimized settings can be restored");
                        type.GetField("AllowClose", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(window, true);
                        window.Close();
                        Check(closed, "explicit exit closes and disposes settings");
                        code = 0;
                    } catch (Exception error) { results.Add("FAIL: " + error.GetType().Name + ": " + error.Message); }
                    finally { app.Shutdown(); }
                }), DispatcherPriority.ApplicationIdle);
            } catch (Exception error) { results.Add("FAIL: " + error.GetType().Name); app.Shutdown(); }
        };
        app.Run();
        File.WriteAllLines(args[1], results);
        try { Directory.Delete(config, true); } catch { }
        return code;
    }
}
