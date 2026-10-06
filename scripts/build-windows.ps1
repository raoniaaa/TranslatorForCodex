param([string]$BackendPath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repo 'dist\windows'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (!(Test-Path $compiler)) { throw 'Windows x64 with .NET Framework 4.8 is required.' }
New-Item -ItemType Directory -Force $output | Out-Null
if ($BackendPath) {
    Copy-Item $BackendPath (Join-Path $output 'translator-server.exe') -Force
} else {
    Push-Location $repo
    try {
        & go build -trimpath -ldflags='-s -w' -o "$output\translator-server.exe" ./cmd/translator
        if ($LASTEXITCODE -ne 0) { throw 'Go build failed.' }
    } finally { Pop-Location }
}
$version = '1.0.4258.31'
$cache = Join-Path $repo ".cache\webview2\$version"
$package = Join-Path $cache 'package'
if (!(Test-Path "$package\lib\net462\Microsoft.Web.WebView2.Wpf.dll")) {
    New-Item -ItemType Directory -Force $cache | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg" -OutFile "$cache\webview2.zip" -UseBasicParsing
    Expand-Archive "$cache\webview2.zip" -DestinationPath $package -Force
}
foreach ($file in @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll')) {
    Copy-Item "$package\lib\net462\$file" $output -Force
}
Copy-Item "$package\runtimes\win-x64\native\WebView2Loader.dll" $output -Force
Copy-Item "$package\LICENSE.txt" (Join-Path $output 'WebView2-LICENSE.txt') -Force
& $compiler /nologo /out:$output\ImportAutomation.exe "$repo\native\windows\build\ImportAutomation.cs"
if ($LASTEXITCODE -ne 0) { throw 'Interop generator build failed.' }
& "$output\ImportAutomation.exe" "$output\NativeAutomation.dll"
if ($LASTEXITCODE -ne 0) { throw 'Interop generation failed.' }
Remove-Item "$output\ImportAutomation.exe"
& $compiler /nologo /r:System.Drawing.dll /out:$output\GenerateIcon.exe "$repo\native\windows\build\GenerateIcon.cs"
if ($LASTEXITCODE -ne 0) { throw 'Icon generator build failed.' }
& "$output\GenerateIcon.exe" "$output\Translator.ico"
if ($LASTEXITCODE -ne 0) { throw 'Icon generation failed.' }
Remove-Item "$output\GenerateIcon.exe"
$arguments = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
    "/out:$output\Translator.exe", "/win32icon:$output\Translator.ico", "/win32manifest:$repo\native\windows\app.manifest",
    '/r:System.Xaml.dll', '/r:System.Web.Extensions.dll', '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll',
    "/r:$output\NativeAutomation.dll", "/r:$output\Microsoft.Web.WebView2.Core.dll", "/r:$output\Microsoft.Web.WebView2.Wpf.dll")
foreach ($assembly in @('UIAutomationClient', 'UIAutomationTypes', 'WindowsBase', 'PresentationCore', 'PresentationFramework')) {
    $arguments += "/r:$framework\WPF\$assembly.dll"
}
$arguments += @(Get-ChildItem "$repo\native\windows\*.cs" | Select-Object -ExpandProperty FullName)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Native application build failed.' }
@'
<?xml version="1.0" encoding="utf-8"?>
<configuration><startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8"/></startup></configuration>
'@ | Set-Content "$output\Translator.exe.config" -Encoding UTF8
Copy-Item "$PSScriptRoot\install-windows.ps1" $output -Force
Copy-Item "$PSScriptRoot\Install.cmd" $output -Force
Write-Host "Built: $output\Translator.exe"
