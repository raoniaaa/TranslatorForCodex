$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repoRoot 'dist\windows-probe'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$test = Join-Path $output 'CompositionStateTest.exe'
& $compiler /nologo /codepage:65001 "/out:$test" `
    (Join-Path $repoRoot 'native\windows\CompositionState.cs') `
    (Join-Path $repoRoot 'native\windows\diagnostics\CompositionStateTest.cs')
if ($LASTEXITCODE -ne 0) { throw 'Composition test compilation failed.' }
& $test
if ($LASTEXITCODE -ne 0) { throw 'Composition tests failed.' }
$framework = Split-Path $compiler -Parent
$contentTest = Join-Path $output 'PlainTextContentTest.exe'
& $compiler /nologo /codepage:65001 "/out:$contentTest" `
    "/r:$framework\WPF\UIAutomationClient.dll" "/r:$framework\WPF\UIAutomationTypes.dll" "/r:$framework\WPF\WindowsBase.dll" `
    (Join-Path $repoRoot 'native\windows\PlainTextContent.cs') `
    (Join-Path $repoRoot 'native\windows\diagnostics\PlainTextContentTest.cs')
if ($LASTEXITCODE -ne 0) { throw 'Plain text content test compilation failed.' }
& $contentTest
if ($LASTEXITCODE -ne 0) { throw 'Plain text content tests failed.' }
