using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using Translator.Windows;

class IntegrationTest
{
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static readonly string Output = "Hello 😀 See you tomorrow.";
    static int calls;
    static bool sourceMatched;

    [MTAThread]
    static int Main(string[] args)
    {
        if (Process.GetCurrentProcess().SessionId != 0 || args.Length != 2) return 2;
        string config = Path.Combine(Path.GetTempPath(), "TranslatorTest-" + Guid.NewGuid().ToString("N"));
        var server = new TcpListener(IPAddress.Loopback, 0);
        Process backend = null, fixture = null;
        try {
            server.Start();
            var mock = new Thread(delegate() {
                try {
                    using (var client = server.AcceptTcpClient())
                    using (var stream = client.GetStream()) {
                        var reader = new StreamReader(stream, Encoding.UTF8, false, 1024, true);
                        string line; int length = 0;
                        while (!String.IsNullOrEmpty(line = reader.ReadLine()))
                            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = Int32.Parse(line.Substring(15).Trim());
                        // All request bytes are UTF-8; read as chars until the byte count is satisfied.
                        var body = new StringBuilder();
                        while (Encoding.UTF8.GetByteCount(body.ToString()) < length) {
                            int c = reader.Read(); if (c < 0) break; body.Append((char)c);
                        }
                        sourceMatched = body.ToString().Contains("你好，明天见");
                        Interlocked.Increment(ref calls);
                        byte[] payload = Encoding.UTF8.GetBytes(Json.Serialize(new { choices = new[] { new { message = new { content = Output } } } }));
                        byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + payload.Length + "\r\nConnection: close\r\n\r\n");
                        stream.Write(header, 0, header.Length); stream.Write(payload, 0, payload.Length);
                    }
                } catch { }
            }) { IsBackground = true };
            mock.Start();
            fixture = Process.Start(new ProcessStartInfo(args[1], "--fixture") { UseShellExecute = false, RedirectStandardOutput = true });
            string handle = fixture.StandardOutput.ReadLine();
            var root = AutomationElement.FromHandle(new IntPtr(Int64.Parse(handle)));
            var field = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
            var draft = DraftAccess.Read(field);
            var info = new ProcessStartInfo(args[0], "--native-hosted") {
                UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true,
                RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8
            };
            info.EnvironmentVariables["TRANSLATOR_CONFIG_DIR"] = config;
            info.EnvironmentVariables["TRANSLATOR_BASE_URL"] = "http://127.0.0.1:" + ((IPEndPoint)server.LocalEndpoint).Port + "/v1";
            info.EnvironmentVariables["TRANSLATOR_MODEL"] = "isolated-fixture";
            info.EnvironmentVariables["TRANSLATOR_API_KEY"] = "";
            var messages = new BlockingCollection<Dictionary<string, object>>();
            backend = new Process { StartInfo = info };
            backend.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) messages.Add(new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(e.Data));
            };
            backend.ErrorDataReceived += delegate { };
            backend.Start(); backend.BeginOutputReadLine(); backend.BeginErrorReadLine();
            Action<string> send = delegate(string type) {
                var message = new { type = type, target = "owned-fixture", text = draft.Text, selectionStart = draft.SelectionStart,
                    selectionLength = draft.SelectionLength, trusted = true, supported = true, editable = true,
                    compositionKnown = true, composing = false };
                byte[] bytes = Encoding.UTF8.GetBytes(Json.Serialize(message) + "\n");
                backend.StandardInput.BaseStream.Write(bytes, 0, bytes.Length); backend.StandardInput.BaseStream.Flush();
            };
            send("snapshot"); Thread.Sleep(800);
            Check(calls == 0, "idle draft does not call API");
            send("translate"); send("translate");
            var replacement = Wait(messages, "replace", null);
            Check(calls == 1 && sourceMatched && (string)replacement["expected"] == draft.Text && (string)replacement["text"] == Output,
                "explicit request translates the full draft once through the Windows backend");
            bool caret;
            Check(DraftAccess.Replace(draft, (string)replacement["text"], delegate { return true; }, out caret) && caret,
                "backend result reaches the fixture with end caret");
            backend.StandardInput.WriteLine(Json.Serialize(new { type = "result", id = replacement["id"], ok = true }));
            backend.StandardInput.Flush();
            Wait(messages, "status", "success");
            draft = DraftAccess.Read(field); send("snapshot"); Thread.Sleep(800);
            Check(calls == 1, "acknowledged result stays idle without another click");
            return 0;
        } catch (Exception error) { Console.WriteLine("FAIL: " + error.GetType().Name); return 1; }
        finally {
            server.Stop();
            if (backend != null) { try { backend.StandardInput.Close(); if (!backend.WaitForExit(1000)) backend.Kill(); } catch { } backend.Dispose(); }
            if (fixture != null) { try { if (!fixture.HasExited) fixture.Kill(); } catch { } fixture.Dispose(); }
            if (Directory.Exists(config)) Directory.Delete(config, true);
        }
    }
    static Dictionary<string, object> Wait(BlockingCollection<Dictionary<string, object>> messages, string type, string phase)
    {
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < 10000) {
            Dictionary<string, object> message;
            if (messages.TryTake(out message, 200) && (string)message["type"] == type && (phase == null || (string)message["phase"] == phase)) return message;
        }
        throw new TimeoutException();
    }
    static void Check(bool valid, string title) { if (!valid) throw new InvalidOperationException(); Console.WriteLine("PASS: " + title); }
}
