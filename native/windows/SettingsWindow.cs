using System;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Translator.Windows
{
    internal sealed class SettingsWindow : Window
    {
        readonly WebView2 browser = new WebView2();
        bool initialized;
        internal bool AllowClose;
        internal SettingsWindow(string url, string configDirectory)
        {
            Title = "Translator · Codex 输入翻译"; Width = 1100; Height = 810;
            MinWidth = 760; MinHeight = 620; WindowStartupLocation = WindowStartupLocation.CenterScreen;
            ShowInTaskbar = true;
            using (var icon = System.Drawing.Icon.ExtractAssociatedIcon(typeof(SettingsWindow).Assembly.Location)) {
                if (icon != null) {
                    var image = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    image.Freeze(); Icon = image;
                }
            }
            Background = System.Windows.Media.Brushes.Black; Content = browser;
            Closing += delegate(object sender, System.ComponentModel.CancelEventArgs e) {
                if (AllowClose) return;
                e.Cancel = true;
                MinimizeToTaskbar();
            };
            Loaded += async delegate {
                if (initialized) return;
                initialized = true;
                try {
                    var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(configDirectory, "WebView2"));
                    await browser.EnsureCoreWebView2Async(environment);
                    browser.CoreWebView2.Settings.IsPasswordAutosaveEnabled = false;
                    browser.CoreWebView2.Settings.IsGeneralAutofillEnabled = false;
                    browser.CoreWebView2.Settings.AreDevToolsEnabled = false;
                    browser.CoreWebView2.NavigationStarting += delegate(object sender, CoreWebView2NavigationStartingEventArgs e) {
                        if (!e.Uri.StartsWith(url, StringComparison.Ordinal)) e.Cancel = true;
                    };
                    browser.CoreWebView2.NewWindowRequested += delegate(object sender, CoreWebView2NewWindowRequestedEventArgs e) { e.Handled = true; };
                    browser.CoreWebView2.DownloadStarting += delegate(object sender, CoreWebView2DownloadStartingEventArgs e) { e.Cancel = true; };
                    browser.CoreWebView2.Navigate(url);
                } catch {
                    Content = new System.Windows.Controls.TextBlock {
                        Text = "无法打开设置窗口。请安装 Microsoft Edge WebView2 Runtime 后重新打开 Translator。",
                        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(40), FontSize = 20,
                        Foreground = System.Windows.Media.Brushes.White
                    };
                }
            };
            Closed += delegate { browser.Dispose(); };
        }
        internal void MinimizeToTaskbar()
        {
            // Keep a real taskbar window so a click can restore settings.
            // Hide() would remove the user's entry point to the running app.
            WindowState = WindowState.Minimized;
        }
    }
}
