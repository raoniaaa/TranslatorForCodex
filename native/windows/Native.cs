using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Translator.Windows
{
    internal static class Native
    {
        internal delegate void WinEventCallback(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
        [DllImport("user32.dll")] internal static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventCallback callback, uint process, uint thread, uint flags);
        [DllImport("user32.dll")] internal static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] internal static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] internal static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr window, int id);
        [DllImport("user32.dll")] internal static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll")] internal static extern int SetWindowLong(IntPtr window, int index, int value);
        [DllImport("user32.dll")] internal static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput data);
        [DllImport("user32.dll")] internal static extern bool DestroyIcon(IntPtr icon);
        [StructLayout(LayoutKind.Sequential)] internal struct Point { internal int X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct LastInput { internal uint Size, Tick; }
        internal static uint InputTick()
        {
            var input = new LastInput { Size = (uint)Marshal.SizeOf(typeof(LastInput)) };
            if (!GetLastInputInfo(ref input)) throw new InvalidOperationException("Input state unavailable.");
            return input.Tick;
        }
        internal static bool IsCodex(int pid)
        {
            try
            {
                using (var process = Process.GetProcessById(pid))
                {
                    string path = process.MainModule.FileName;
                    return path.IndexOf(@"\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0
                        && System.IO.Path.GetFileName(path).Equals("ChatGPT.exe", StringComparison.OrdinalIgnoreCase);
                }
            }
            catch { return false; }
        }
        internal static bool CodexForeground()
        {
            int pid;
            GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            return IsCodex(pid);
        }
        internal static void GoToCodex()
        {
            foreach (var process in Process.GetProcessesByName("ChatGPT"))
            {
                using (process)
                {
                    if (process.MainWindowHandle != IntPtr.Zero && IsCodex(process.Id))
                    {
                        ShowWindow(process.MainWindowHandle, 9);
                        SetForegroundWindow(process.MainWindowHandle);
                        return;
                    }
                }
            }
            throw new InvalidOperationException("请先打开 Codex 桌面应用。");
        }
    }
}
