using System;
using System.IO;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Translator.Windows
{
    internal sealed class PetWindow : Window
    {
        readonly TextBlock message;
        readonly Ellipse light;
        readonly string positionFile;
        Point down, origin;
        bool pressing, dragged;
        internal Action Translate, Settings, Recover, Cancel;
        internal IntPtr Handle;
        internal Func<IntPtr, int, IntPtr, IntPtr, IntPtr> MessageHook;

        internal PetWindow(string configDirectory)
        {
            positionFile = System.IO.Path.Combine(configDirectory, "pet-position.json");
            Width = 274; Height = 202; WindowStyle = WindowStyle.None;
            AllowsTransparency = true; Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false; ShowActivated = false; Topmost = true;
            Title = "Translator";
            var canvas = new Canvas { Background = Brushes.Transparent };
            var bubble = new Border { Width = 264, Height = 70, CornerRadius = new CornerRadius(20),
                Background = new SolidColorBrush(Color.FromArgb(242, 29, 36, 34)), BorderBrush = new SolidColorBrush(Color.FromRgb(66, 77, 69)), BorderThickness = new Thickness(1) };
            message = new TextBlock { Text = "正在连接…", Foreground = Brushes.White, FontSize = 13,
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(16, 12, 12, 8) };
            bubble.Child = message;
            canvas.Children.Add(bubble); Canvas.SetLeft(bubble, 5);
            var gold = new SolidColorBrush(Color.FromRgb(255, 204, 125));
            var dark = new SolidColorBrush(Color.FromRgb(28, 56, 46));
            Add(canvas, new Rectangle { Width = 4, Height = 22, Fill = gold }, 135, 81);
            light = new Ellipse { Width = 12, Height = 12, Fill = gold }; Add(canvas, light, 131, 75);
            Add(canvas, new Rectangle { Width = 112, Height = 93, RadiusX = 34, RadiusY = 34, Fill = gold }, 81, 98);
            Add(canvas, new Rectangle { Width = 20, Height = 33, RadiusX = 9, RadiusY = 9, Fill = gold }, 67, 129);
            Add(canvas, new Rectangle { Width = 20, Height = 33, RadiusX = 9, RadiusY = 9, Fill = gold }, 187, 129);
            Add(canvas, new Rectangle { Width = 87, Height = 55, RadiusX = 21, RadiusY = 21, Fill = dark }, 94, 118);
            Add(canvas, new Rectangle { Width = 10, Height = 20, RadiusX = 5, RadiusY = 5, Fill = gold }, 111, 135);
            Add(canvas, new Rectangle { Width = 10, Height = 20, RadiusX = 5, RadiusY = 5, Fill = gold }, 155, 135);
            Add(canvas, new Rectangle { Width = 27, Height = 22, RadiusX = 10, RadiusY = 10, Fill = gold }, 95, 178);
            Add(canvas, new Rectangle { Width = 27, Height = 22, RadiusX = 10, RadiusY = 10, Fill = gold }, 151, 178);
            Content = canvas;
            ToolTip = "点击翻译整段 · 拖动挪位置 · 右键设置";
            var menu = new ContextMenu();
            AddMenu(menu, "翻译当前草稿 · Ctrl+T", delegate { if (Translate != null) Translate(); });
            AddMenu(menu, "打开设置", delegate { if (Settings != null) Settings(); });
            AddMenu(menu, "找回宠物", delegate { if (Recover != null) Recover(); });
            AddMenu(menu, "取消本次翻译", delegate { if (Cancel != null) Cancel(); });
            ContextMenu = menu;
            SourceInitialized += delegate {
                Handle = new WindowInteropHelper(this).Handle;
                Native.SetWindowLong(Handle, -20, Native.GetWindowLong(Handle, -20) | 0x08000000 | 0x80);
                HwndSource.FromHwnd(Handle).AddHook(Hook);
                ResetPosition(false);
                try {
                    var saved = new JavaScriptSerializer().Deserialize<double[]>(File.ReadAllText(positionFile));
                    if (saved.Length == 2 && !Double.IsNaN(saved[0]) && !Double.IsNaN(saved[1]) && !Double.IsInfinity(saved[0]) && !Double.IsInfinity(saved[1])) {
                        Left = saved[0]; Top = saved[1]; Clamp();
                    }
                } catch { }
            };
            MouseLeftButtonDown += delegate(object sender, MouseButtonEventArgs e) {
                Native.Point cursor; Native.GetCursorPos(out cursor);
                down = new Point(cursor.X, cursor.Y); origin = new Point(Left, Top);
                pressing = true; dragged = false; CaptureMouse(); e.Handled = true;
            };
            MouseMove += delegate {
                if (!pressing) return;
                Native.Point cursor; Native.GetCursorPos(out cursor);
                var delta = new Point(cursor.X - down.X, cursor.Y - down.Y);
                if (Math.Abs(delta.X) + Math.Abs(delta.Y) > 5) dragged = true;
                if (!dragged) return;
                var transform = HwndSource.FromHwnd(Handle).CompositionTarget.TransformFromDevice;
                var offset = transform.Transform(delta);
                Left = origin.X + offset.X; Top = origin.Y + offset.Y;
            };
            MouseLeftButtonUp += delegate(object sender, MouseButtonEventArgs e) {
                if (!pressing) return;
                pressing = false; ReleaseMouseCapture(); e.Handled = true;
                if (dragged) { Clamp(); SavePosition(); }
                else if (Translate != null) Translate();
            };
            LostMouseCapture += delegate { pressing = false; };
        }
        static void Add(Canvas parent, UIElement element, double x, double y) { parent.Children.Add(element); Canvas.SetLeft(element, x); Canvas.SetTop(element, y); }
        static void AddMenu(ContextMenu menu, string title, Action action) { var item = new MenuItem { Header = title }; item.Click += delegate { action(); }; menu.Items.Add(item); }
        IntPtr Hook(IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled)
        {
            if (msg == 0x21) { handled = true; return new IntPtr(3); } // MA_NOACTIVATE
            if (msg == 0x7E) Clamp();
            if (MessageHook != null) MessageHook(hwnd, msg, w, l);
            return IntPtr.Zero;
        }
        internal void Status(string text, string phase, double elapsed)
        {
            bool busy = phase == "translating" || phase == "applying" || phase == "checking";
            message.Text = text + (busy ? "\n" + elapsed.ToString("0.0") + " 秒" : "\n点击翻译 · Ctrl+T");
            light.Fill = new SolidColorBrush(phase == "error" ? Color.FromRgb(255, 130, 115) : busy ? Color.FromRgb(142, 219, 191) : Color.FromRgb(255, 204, 125));
            light.Opacity = busy ? 0.55 + 0.45 * Math.Abs(Math.Sin(elapsed * 4)) : 1;
        }
        internal void ResetPosition(bool save = true)
        {
            var bounds = System.Windows.Forms.Screen.PrimaryScreen.WorkingArea;
            var transform = HwndSource.FromHwnd(Handle).CompositionTarget.TransformFromDevice;
            var end = transform.Transform(new Point(bounds.Right, bounds.Bottom));
            Left = end.X - Width - 24; Top = end.Y - Height - 32;
            if (save) SavePosition();
        }
        void Clamp()
        {
            var transform = HwndSource.FromHwnd(Handle).CompositionTarget.TransformToDevice;
            var center = transform.Transform(new Point(Left + Width / 2, Top + Height / 2));
            var screen = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point((int)center.X, (int)center.Y));
            var inverse = HwndSource.FromHwnd(Handle).CompositionTarget.TransformFromDevice;
            var start = inverse.Transform(new Point(screen.WorkingArea.Left, screen.WorkingArea.Top));
            var end = inverse.Transform(new Point(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
            Left = Math.Max(start.X, Math.Min(Left, end.X - Width)); Top = Math.Max(start.Y, Math.Min(Top, end.Y - Height));
        }
        void SavePosition() { try { File.WriteAllText(positionFile, new JavaScriptSerializer().Serialize(new[] { Left, Top })); } catch { } }
    }
}
