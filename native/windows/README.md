# Windows native preview

The Windows companion is a native WPF application with an embedded WebView2
settings window, a draggable nonactivating pet, a tray menu, and Control+T.
The existing Go backend handles API requests, configuration and guarded manual
translation. No terminal, Go installation, .NET SDK or browser tab is required
on the machine running the packaged app.

## Build and install

On Windows x64 with Go 1.24+ and .NET Framework 4.8:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\build-windows.ps1
```

The script downloads the pinned official Microsoft WebView2 SDK package and
uses the built-in C# compiler. To build the Go backend on another machine,
pass `-BackendPath <path-to-windows-x64-translator-server.exe>`.

Distribute the **whole** `dist/windows` folder as a ZIP. After extracting it,
double-click `Translator.exe` for portable use, or `Install.cmd` to install
under `%LOCALAPPDATA%\Programs\TranslatorForCodex` and create desktop and
Start menu shortcuts. Quit from the tray before updating. The package is an
unsigned preview. Microsoft Edge WebView2 Runtime must be installed; it was
already present on the test machine.

Settings, the API key and pet position are saved under
`%LOCALAPPDATA%\CodexTranslator`. The native host sets a user-specific inherited
Windows directory ACL before launching the backend. The key is a plaintext
local file, not a Credential Manager entry. WebView2 autofill and password
saving are disabled. Configuration stays separate from application binaries.

Write the entire draft, commit Chinese input, then click the pet or press
**Ctrl+T**. **Ctrl+Alt+R** restores the last translated draft if it is unchanged.
Hotkeys are registered only while Codex is foreground. Closing settings or
returning to Codex minimizes the settings window while
keeping its taskbar icon. Click that taskbar button to restore settings; the tray
menu provides an explicit Quit action. The title bar, taskbar, tray and installed
shortcuts use the executable's embedded Translator icon. Reopening the shortcut
also returns to settings.

To check the settings lifecycle in an isolated service/SSH session, build the app
and run `scripts/test-windows-adapter.ps1 -AppPath dist/windows/Translator.exe`.
This checks taskbar window styles, the native icon, minimize/close/restore and
explicit exit using the actual settings window. It does not inspect real drafts
or use saved API settings. This check does not replace verifying the Explorer
taskbar button on the signed-in desktop.

The Windows guard queries `IUIAutomationTextEditPattern.GetActiveComposition`
and refuses replacement if the composition state is unknown or active. It also
rechecks the focused control, exact text and selection, and user input before
moving the caret. Attachments and other embedded controls are outside the
plain-text preview scope.

## Compatibility probe

The read-only probe checks the installed Codex desktop app.
It does not translate, replace text, send keys, access the clipboard, or change
focus. Reports contain control capabilities and text/selection lengths, never
draft contents, window titles, account credentials, or API keys.

## Run on Windows

From PowerShell **on the signed-in desktop**, with Codex open:

```powershell
.\scripts\probe-windows.ps1
```

If the machine's default policy blocks local scripts, use a process-scoped
policy without changing the machine's persistent configuration:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\probe-windows.ps1
```

Click the Codex message composer during the five-second countdown. The probe
takes three samples and saves a uniquely named JSON report under
`%LOCALAPPDATA%\CodexTranslator\diagnostics`. Run it once with a completed test
draft and again while the Chinese IME candidate list is open to compare exposed
capabilities. Do not send the test draft.

The script uses the Windows .NET Framework C# compiler and system UI Automation
assemblies; no .NET SDK or NuGet download is required. `-BuildOnly` compiles the
probe without inspecting the desktop. A provider timeout terminates only the
probe process, preserving any completed samples.

SSH commands run in a service session and cannot inspect the user's Codex UI.
Launch the probe from the interactive desktop. A temporary, manually started
Task Scheduler task with `Interactive` logon and `Limited` run level is another
option for remote development; compile probes as `winexe` and keep any launcher
hidden so it cannot steal focus or close the candidate list. Remove the temporary
task after the run. Do not save an
account password in scripts or task definitions.

## Initial findings — 2026-10-06

- Compiled the Go backend for Windows x64 successfully.
- Compiled and ran this probe on Windows build `26200.9457`, in the user's
  interactive session, with Codex `26.930.3930.0`.
- Found a visible enabled `ControlType.Edit` exposing `ValuePattern` with
  `IsReadOnly=false`, plus `TextPattern` and selection access.
- A second run after the user focused the message composer confirmed that this
  editable control is the composer; text length and selection were readable.
- The user confirmed that API configuration and preview translation work, and
  later confirmed that Ctrl+T translates the Codex draft after committing Chinese
  input. This is a user-reported interactive result, separate from the read-only
  capability probes and automated fixture tests.
- During testing, the composition guard sometimes kept reporting an active
  composition after the user expected it to be committed. Temporary console
  probes also disturbed focus. Broad IME compatibility, actual Codex undo and
  caret behavior are not established by the successful Ctrl+T test.

## Draft adapter foundation

`DraftAccess.cs` implements reading and guarded whole-value replacement using
`ValuePattern`, and selection/caret access using `TextPattern`. It requires its
caller to check focus, target identity, IME composition, and intervening user
input. The native host connects this adapter to the Go backend and supplies these
safety checks. Do not use an unconditional safety callback with a real application.

The adapter was compiled and tested in a separate WPF fixture in SSH session 0,
without changing the interactive Codex draft. All six checks passed:

- Full draft and middle selection reading, including emoji.
- Unsafe state rejection without writing.
- Stale text rejection.
- Changed selection rejection.
- Whole-draft replacement with the caret at the end.
- No caret correction when safety changes after writing.

Run these tests **only in an isolated service/SSH session**:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\test-windows-adapter.ps1
```

The fixture refuses to run tests on the interactive desktop. It uses only its
own test strings, never the clipboard, and exits automatically if its parent
fails. Passing these tests does not validate Codex's actual replacement behavior
or Chinese IME handling; those require a later controlled integration test.

The current package is identified by its `OpenAI.Codex_…` installation path and
`ChatGPT.exe` executable. A differently packaged Codex installation requires an
updated identity check. The scan is bounded to 3,000 nodes and six seconds per
sample, with an external process timeout because individual provider calls may
block. A partial scan is not evidence that an input box is absent.

A Windows backend integration test also passed using an isolated local mock API:
idle drafts produce no API calls, duplicate explicit requests produce one call,
the whole result reaches the WPF fixture with the caret at the end, and the
acknowledged result stays idle. Run it with `-BackendPath` on
`test-windows-adapter.ps1`. Actual Ctrl+T translation was subsequently confirmed by the user. This does
not establish compatibility with every input method or Codex version, nor
validate all caret and undo cases.
