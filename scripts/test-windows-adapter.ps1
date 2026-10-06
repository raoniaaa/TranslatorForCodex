param([string]$BackendPath)
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
