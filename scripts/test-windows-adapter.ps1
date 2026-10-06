param([string]$BackendPath, [string]$AppPath)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repoRoot 'dist\windows-probe'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
New-Item -ItemType Directory -Force $output | Out-Null
$executable = Join-Path $output 'DraftAccessTest.exe'
$arguments = @('/nologo', '/target:exe', "/out:$executable", '/r:System.Xaml.dll')
foreach ($assembly in @('UIAutomationClient', 'UIAutomationTypes', 'WindowsBase', 'PresentationCore', 'PresentationFramework')) {
    $arguments += "/r:$framework\WPF\$assembly.dll"
}
$arguments += (Join-Path $repoRoot 'native\windows\DraftAccess.cs')
$arguments += (Join-Path $repoRoot 'native\windows\diagnostics\DraftAccessTest.cs')
& "$framework\csc.exe" @arguments
if ($LASTEXITCODE -ne 0) { throw 'Adapter test compilation failed.' }
& $executable
if ($LASTEXITCODE -ne 0) { throw 'Adapter tests failed.' }
if ($BackendPath) {
    $arguments = @('/nologo', '/target:exe', '/codepage:65001', "/out:$output\IntegrationTest.exe", '/r:System.Web.Extensions.dll')
    foreach ($assembly in @('UIAutomationClient', 'UIAutomationTypes', 'WindowsBase')) { $arguments += "/r:$framework\WPF\$assembly.dll" }
    $arguments += (Join-Path $repoRoot 'native\windows\DraftAccess.cs')
    $arguments += (Join-Path $repoRoot 'native\windows\diagnostics\IntegrationTest.cs')
    & "$framework\csc.exe" @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Integration test compilation failed.' }
    & "$output\IntegrationTest.exe" $BackendPath $executable
    if ($LASTEXITCODE -ne 0) { throw 'Integration test failed.' }
}
if ($AppPath) {
    if ([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0) {
        throw 'Run window tests in an isolated service/SSH session.'
    }
    $windowTest = Join-Path $output 'SettingsLifecycleTest.exe'
    $arguments = @('/nologo', '/target:winexe', '/r:System.Xaml.dll', "/out:$windowTest")
    foreach ($assembly in @('WindowsBase', 'PresentationCore', 'PresentationFramework')) {
        $arguments += "/r:$framework\WPF\$assembly.dll"
    }
    $arguments += (Join-Path $repoRoot 'native\windows\diagnostics\SettingsLifecycleTest.cs')
    & "$framework\csc.exe" @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Window test compilation failed.' }
    $report = Join-Path $output ('settings-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $process = Start-Process $windowTest -ArgumentList ('"' + (Resolve-Path $AppPath).Path + '" "' + $report + '"') -PassThru
    if (!$process.WaitForExit(25000)) {
        $process.Kill()
        throw 'Window tests timed out.'
    }
    if (Test-Path $report) { Get-Content $report }
    if ($process.ExitCode -ne 0) { throw 'Window tests failed.' }
}
