using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Translator.Windows
{
    internal sealed class App : Application
    {
        readonly BlockingCollection<Action> work = new BlockingCollection<Action>();
        readonly object sendLock = new object();
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };
        readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexTranslator");
        Process backend;
        Composer composer;
        PetWindow pet;
        SettingsWindow settings;
        Forms.NotifyIcon tray;
        DispatcherTimer timer;
        EventWaitHandle reopen, quit;
        volatile bool closing;
        int writeEpoch;
        string url, phase = "idle", message = "写好后点击宠物，翻译整段草稿";
        bool busy, hotkeyAttempted, translateHotkey, undoHotkey;
        bool diagnostics;
        int diagnosticTicks, hotkeyPresses;
        volatile object snapshotMetadata;
        DateTime started;
        Native.WinEventCallback foregroundCallback;
        IntPtr foregroundHook;

        [STAThread]
        static void Main(string[] args)
        {
            string suffix = WindowsIdentity.GetCurrent().User.Value;
            if (args.Length == 1 && args[0] == "--quit") {
                try { using (var signal = EventWaitHandle.OpenExisting("Local\\CodexTranslatorQuit-" + suffix)) signal.Set(); } catch { }
                return;
            }
            bool first;
            using (var mutex = new Mutex(true, "Local\\CodexTranslator-" + suffix, out first))
            {
                if (!first) {
                    try { using (var signal = EventWaitHandle.OpenExisting("Local\\CodexTranslatorShow-" + suffix)) signal.Set(); } catch { }
                    return;
                }
                var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                app.diagnostics = Array.IndexOf(args, "--diagnostics") >= 0;
                app.reopen = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\CodexTranslatorShow-" + suffix);
                app.quit = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\CodexTranslatorQuit-" + suffix);
                app.Startup += delegate {
                    try { app.Start(); }
                    catch { MessageBox.Show("Translator 启动失败。请完整解压应用文件夹后再运行。", "Translator"); app.Quit(1); }
                };
                app.Exit += delegate { app.Stop(); };
                app.Run();
            }
        }
        void Start()
        {
            Directory.CreateDirectory(directory);
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User,
                FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(directory, security);
            if (diagnostics) Directory.CreateDirectory(Path.Combine(directory, "diagnostics"));
            pet = new PetWindow(directory);
            pet.Translate = delegate { work.Add(delegate { Send(composer.Capture("translate")); }); };
            pet.Settings = OpenSettings;
            pet.Recover = delegate { pet.ResetPosition(); GoToCodex(); };
            pet.Cancel = delegate { Interlocked.Increment(ref writeEpoch); Send(new { type = "pause" }); };
            pet.MessageHook = delegate(IntPtr hwnd, int msg, IntPtr w, IntPtr l) {
                if (msg == 0x312 && Native.CodexForeground()) {
                    if (w.ToInt32() == 1) { hotkeyPresses++; pet.Translate(); }
                    else if (w.ToInt32() == 2) Undo();
                }
                return IntPtr.Zero;
            };
            // Create the nonactivating window handle without making it visible.
            new WindowInteropHelper(pet).EnsureHandle();
            tray = new Forms.NotifyIcon { Text = "Translator · 点击宠物或 Ctrl+T 翻译", Icon = CreateIcon(), Visible = true };
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("打开设置", null, delegate { OpenSettings(); });
            menu.Items.Add("前往 Codex", null, delegate { GoToCodex(); });
            menu.Items.Add("找回翻译宠物", null, delegate { pet.ResetPosition(); GoToCodex(); });
            menu.Items.Add("取消本次翻译", null, delegate { pet.Cancel(); });
            menu.Items.Add("退出 Translator", null, delegate { Quit(); });
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { OpenSettings(); };
            var info = new ProcessStartInfo(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "translator-server.exe"), "--native-hosted") {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            info.EnvironmentVariables["TRANSLATOR_CONFIG_DIR"] = directory;
            backend = new Process { StartInfo = info, EnableRaisingEvents = true };
            backend.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data == null || closing) return;
                try {
                    var command = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(e.Data);
                    string type = Text(command, "type");
                    if (type == "cancel-write") { Interlocked.Increment(ref writeEpoch); return; }
                    if (type == "replace") { int epoch = Volatile.Read(ref writeEpoch); work.Add(delegate { Replace(command, epoch); }); }
                    else Dispatcher.BeginInvoke(new Action(delegate { Handle(command); }));
                } catch { }
            };
            backend.ErrorDataReceived += delegate { }; // Never log drafts, provider errors or secrets.
            backend.Exited += delegate { if (!closing) Dispatcher.BeginInvoke(new Action(delegate { MessageBox.Show("翻译服务已退出，请重新打开 Translator。", "Translator"); Quit(1); })); };
            backend.Start(); backend.BeginOutputReadLine(); backend.BeginErrorReadLine();
            var worker = new Thread(delegate() {
                composer = new Composer();
                while (!closing) {
                    try {
                        Action action;
                        if (work.TryTake(out action, 180)) action();
                        if (!closing) {
                            var snapshot = composer.Capture("snapshot");
                            Send(snapshot);
                            if (diagnostics) snapshotMetadata = new {
                                observedAt = DateTime.UtcNow.ToString("o"), supported = snapshot["supported"],
                                known = snapshot["compositionKnown"], composing = snapshot.ContainsKey("composing") && Convert.ToBoolean(snapshot["composing"]),
                                activeCompositionLength = composer.ActiveCompositionLength,
                                compositionEvents = composer.CompositionEventMetadata(),
                                captureStage = composer.CaptureStage,
                                textLength = Text(snapshot, "text").Length
                            };
                        }
                    } catch { Send(new { type = "notice", reason = "无法读取输入状态，请重新点击 Codex 输入框。" }); }
                }
            }) { IsBackground = true };
            worker.SetApartmentState(ApartmentState.MTA); worker.Start();
            new Thread(delegate() {
                while (!closing) {
                    int signal = WaitHandle.WaitAny(new WaitHandle[] { reopen, quit });
                    if (closing) break;
                    Dispatcher.BeginInvoke(new Action(delegate { if (signal == 1) Quit(); else OpenSettings(); }));
                }
            }) { IsBackground = true }.Start();
            foregroundCallback = delegate { UpdateForeground(); };
            foregroundHook = Native.SetWinEventHook(3, 3, IntPtr.Zero, foregroundCallback, 0, 0, 0);
            timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
            timer.Tick += delegate {
                UpdateForeground(); pet.Status(message, phase, busy ? (DateTime.UtcNow - started).TotalSeconds : 0);
                if (diagnostics && ++diagnosticTicks % 5 == 0) {
                    try { File.WriteAllText(Path.Combine(directory, "diagnostics", "app-state.json"), new JavaScriptSerializer().Serialize(new {
                        at = DateTime.UtcNow.ToString("o"), phase = phase, busy = busy, hotkeyRegistered = translateHotkey,
                        hotkeyPresses = hotkeyPresses, snapshot = snapshotMetadata
                    })); } catch { }
                }
            };
            timer.Start();
        }
        void Handle(Dictionary<string, object> command)
        {
            switch (Text(command, "type")) {
                case "settings":
                    Uri address;
                    string candidate = Text(command, "url");
                    if (Uri.TryCreate(candidate, UriKind.Absolute, out address) && address.Scheme == "http" && address.Host == "127.0.0.1") { url = candidate; OpenSettings(); }
                    break;
                case "status":
                    phase = Text(command, "phase"); message = Text(command, "message");
                    bool next = command.ContainsKey("busy") && Convert.ToBoolean(command["busy"]);
                    if (next && !busy) started = DateTime.UtcNow;
                    busy = next;
                    break;
                case "connect": GoToCodex(); break;
                case "show-pet": pet.ResetPosition(); GoToCodex(); break;
                case "reveal-app": Process.Start("explorer.exe", "/select,\"" + System.Reflection.Assembly.GetExecutingAssembly().Location + "\""); break;
                case "permission": case "recheck-permission":
                    Send(new { type = "notice", reason = "Windows 无需辅助功能授权。请让 Codex 与 Translator 都以普通用户运行。" }); break;
            }
        }
        void Replace(Dictionary<string, object> command, int epoch)
        {
            bool ok = false, caret = false;
            string reason = "草稿或输入状态已改变，请重新点击翻译。";
            try {
                var current = composer.Capture("snapshot");
                string target = Text(command, "target");
                if (epoch == Volatile.Read(ref writeEpoch) && Text(current, "target") == target &&
                    current.ContainsKey("supported") && Convert.ToBoolean(current["supported"]) &&
                    Text(current, "text") == Text(command, "expected") &&
                    Number(current, "selectionStart") == Number(command, "selectionStart") &&
                    Number(current, "selectionLength") == Number(command, "selectionLength")) {
                    var snapshot = DraftAccess.Read(AutomationElement.FocusedElement);
                    if (Composer.Target(snapshot.Element) != target || snapshot.Text != Text(command, "expected") ||
                        snapshot.SelectionStart != Number(command, "selectionStart") ||
                        snapshot.SelectionLength != Number(command, "selectionLength"))
                        throw new InvalidOperationException("Draft changed during validation.");
                    uint inputTick = Native.InputTick();
                    ok = DraftAccess.Replace(snapshot, Text(command, "text"), delegate {
                        return epoch == Volatile.Read(ref writeEpoch) && !closing && composer.Safe(snapshot.Element, target, inputTick);
                    }, out caret);
                    if (ok) reason = caret ? "" : "英文已填入；光标位置未确认，请手动点击末尾。";
                }
            } catch { reason = "输入框未接受替换，请检查草稿后重试。"; }
            Send(new { type = "result", id = command["id"], ok = ok, reason = reason });
        }
        void Undo() { work.Add(delegate { Send(composer.Capture("snapshot")); Send(new { type = "undo" }); }); }
        void OpenSettings()
        {
            if (closing || url == null) return;
            if (settings == null) { settings = new SettingsWindow(url, directory); MainWindow = settings; settings.Closed += delegate { settings = null; }; }
            settings.Show(); settings.WindowState = WindowState.Normal; settings.Activate();
        }
        void GoToCodex()
        {
            try { if (settings != null) settings.MinimizeToTaskbar(); Native.GoToCodex(); UpdateForeground(); }
            catch (Exception e) { MessageBox.Show(e.Message, "Translator"); }
        }
        void UpdateForeground()
        {
            if (closing) return;
            bool active = Native.CodexForeground();
            if (active && !hotkeyAttempted) {
                hotkeyAttempted = true;
                translateHotkey = Native.RegisterHotKey(pet.Handle, 1, 0x4002, 0x54);
                undoHotkey = Native.RegisterHotKey(pet.Handle, 2, 0x4003, 0x52);
                if (!translateHotkey) Send(new { type = "notice", reason = "Ctrl+T 已被其他程序占用，请点击宠物翻译。" });
            } else if (!active && hotkeyAttempted) {
                ReleaseHotkeys();
            }
            if (active && !pet.IsVisible) pet.Show();
            if (!active && pet.IsVisible) pet.Hide();
        }
        void ReleaseHotkeys()
        {
            if (translateHotkey) Native.UnregisterHotKey(pet.Handle, 1);
            if (undoHotkey) Native.UnregisterHotKey(pet.Handle, 2);
            translateHotkey = undoHotkey = hotkeyAttempted = false;
        }
        void Send(object value)
        {
            if (closing || backend == null) return;
            try { lock (sendLock) { byte[] bytes = Encoding.UTF8.GetBytes(json.Serialize(value) + "\n"); backend.StandardInput.BaseStream.Write(bytes, 0, bytes.Length); backend.StandardInput.BaseStream.Flush(); } } catch { }
        }
        void Quit(int exitCode = 0)
        {
            closing = true;
            if (settings != null) settings.AllowClose = true;
            Shutdown(exitCode);
        }
        void Stop()
        {
            closing = true; Interlocked.Increment(ref writeEpoch);
            if (timer != null) timer.Stop();
            if (pet != null) ReleaseHotkeys();
            if (foregroundHook != IntPtr.Zero) Native.UnhookWinEvent(foregroundHook);
            if (tray != null) { tray.Visible = false; tray.Icon.Dispose(); tray.Dispose(); }
            if (backend != null) {
                try { backend.StandardInput.Close(); if (!backend.WaitForExit(700)) backend.Kill(); } catch { }
                backend.Dispose();
            }
            if (reopen != null) reopen.Set();
        }
        static string Text(Dictionary<string, object> value, string key) { object item; return value.TryGetValue(key, out item) ? Convert.ToString(item) : ""; }
        static int Number(Dictionary<string, object> value, string key) { object item; return value.TryGetValue(key, out item) ? Convert.ToInt32(item) : -1; }
        static System.Drawing.Icon CreateIcon()
        {
            var applicationIcon = System.Drawing.Icon.ExtractAssociatedIcon(typeof(App).Assembly.Location);
            if (applicationIcon != null) return applicationIcon;
            using (var bitmap = new System.Drawing.Bitmap(32, 32)) {
                using (var graphics = System.Drawing.Graphics.FromImage(bitmap)) {
                    graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    graphics.Clear(System.Drawing.Color.Transparent);
                    using (var gold = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(255, 204, 125))) {
                        graphics.FillEllipse(gold, 2, 3, 28, 27);
                        graphics.FillRectangle(System.Drawing.Brushes.DarkSlateGray, 7, 11, 18, 12);
                        graphics.FillEllipse(gold, 10, 14, 3, 6); graphics.FillEllipse(gold, 19, 14, 3, 6);
                    }
                }
                IntPtr handle = bitmap.GetHicon();
                try { return (System.Drawing.Icon)System.Drawing.Icon.FromHandle(handle).Clone(); }
                finally { Native.DestroyIcon(handle); }
            }
        }
    }
}
