$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:LOCALAPPDATA 'Programs\TranslatorForCodex'
if (@(Get-Process Translator -ErrorAction SilentlyContinue | Where-Object Path -eq "$destination\Translator.exe").Count) {
    throw 'Please quit Translator from the tray before updating.'
}
New-Item -ItemType Directory -Force $destination | Out-Null
foreach ($name in @('Translator.exe','Translator.exe.config','translator-server.exe','NativeAutomation.dll',
    'Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.Wpf.dll','WebView2Loader.dll','WebView2-LICENSE.txt')) {
    if (!(Test-Path "$PSScriptRoot\$name")) { throw "Missing package file: $name. Extract the entire ZIP before installing." }
}
foreach ($file in Get-ChildItem $PSScriptRoot -File) {
    if ($file.Extension -in @('.exe','.dll','.config','.ico') -or $file.Name -eq 'WebView2-LICENSE.txt') {
        Copy-Item $file.FullName $destination -Force
    }
}
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
    $shortcut = $shell.CreateShortcut((Join-Path $folder 'Translator.lnk'))
    $shortcut.TargetPath = "$destination\Translator.exe"
    $shortcut.WorkingDirectory = $destination
    $shortcut.IconLocation = "$destination\Translator.exe,0"
    $shortcut.Description = 'Translator for Codex'
    $shortcut.Save()
}
Start-Process "$destination\Translator.exe"
Write-Host 'Installed. Open Translator from the desktop or Start menu.'
