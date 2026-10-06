using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
class GenerateIcon
{
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    static void Main(string[] args)
    {
        using (var image = new Bitmap(256, 256)) {
            using (var g = Graphics.FromImage(image))
            using (var gold = new SolidBrush(Color.FromArgb(255, 204, 125)))
            using (var dark = new SolidBrush(Color.FromArgb(28, 56, 46))) {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                g.FillEllipse(gold, 27, 50, 202, 182);
                g.FillRectangle(gold, 121, 29, 14, 43); g.FillEllipse(gold, 115, 16, 26, 26);
                g.FillEllipse(gold, 9, 108, 42, 66); g.FillEllipse(gold, 205, 108, 42, 66);
                g.FillEllipse(gold, 57, 210, 50, 40); g.FillEllipse(gold, 149, 210, 50, 40);
                g.FillEllipse(dark, 51, 94, 154, 111);
                g.FillEllipse(gold, 86, 127, 16, 38); g.FillEllipse(gold, 154, 127, 16, 38);
            }
            IntPtr handle = image.GetHicon();
            try { using (var icon = Icon.FromHandle(handle)) using (var file = File.Create(args[0])) icon.Save(file); }
            finally { DestroyIcon(handle); }
        }
    }
}
