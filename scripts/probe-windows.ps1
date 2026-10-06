param([switch]$BuildOnly)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repoRoot 'dist\windows-probe'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (!(Test-Path $compiler)) { throw 'The 64-bit .NET Framework compiler was not found.' }
New-Item -ItemType Directory -Force $output | Out-Null
$executable = Join-Path $output 'InputProbe.exe'
$compilerArguments = @(
    '/nologo', '/target:winexe', "/out:$executable",
    "/r:$framework\WPF\UIAutomationClient.dll",
    "/r:$framework\WPF\UIAutomationTypes.dll",
    "/r:$framework\WPF\WindowsBase.dll",
    '/r:System.Web.Extensions.dll',
    (Join-Path $repoRoot 'native\windows\diagnostics\InputProbe.cs')
)
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw 'Input probe compilation failed.' }
if ($BuildOnly) { Write-Output $executable; exit 0 }

if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Run the probe from PowerShell on the signed-in desktop, not an SSH service session.'
}
$reportDirectory = Join-Path $env:LOCALAPPDATA 'CodexTranslator\diagnostics'
New-Item -ItemType Directory -Force $reportDirectory | Out-Null
$report = Join-Path $reportDirectory ('input-' + [Guid]::NewGuid().ToString('N') + '.json')
Write-Host 'Click the Codex message input now. Inspection starts in 5 seconds; text will not be changed.'
Start-Sleep -Seconds 5
$probe = Start-Process -FilePath $executable -ArgumentList ('"' + $report + '"') -PassThru
if (!$probe.WaitForExit(25000)) {
    $probe.Kill()
    throw "The accessibility provider timed out. Any completed samples are in $report"
}
if ($probe.ExitCode -ne 0) { throw "The probe failed with exit code $($probe.ExitCode)." }
Write-Host "Read-only report: $report"
Get-Content $report
