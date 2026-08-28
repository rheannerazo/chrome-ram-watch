# Contributing

Thank you for helping improve Chrome RAM Watch.

## Before opening a change

- Search existing issues before opening a duplicate.
- Keep the PowerShell watcher read-only.
- Do not add tab closing, tab discarding, process termination, registry writes, file writes, remote-code execution, telemetry, or page-content collection to the main watcher.
- Keep cleanup behavior in the separate optional companion and require an exact review plus a separate final confirmation.
- The companion's only tab or page-state mutation may be `chrome.tabs.discard(tabId)` for an exact tab ID that passes a fresh safety recheck immediately before the call.
- Keep read-only tab access limited to `chrome.tabs.query()` and `chrome.tabs.get()`. Keep optional permission management limited to `chrome.permissions.contains()`, `chrome.permissions.request()`, and `chrome.permissions.remove()`.
- Do not add `chrome.tabs.remove`, window removal, background cleanup, timers, host permissions, content scripts, native messaging, or network access to the companion.
- Avoid logging raw Chrome command lines because they can contain local paths or other sensitive values.

## Local checks

Run the dependency-free test suite in both supported PowerShell editions when available:

```powershell
powershell.exe -NoProfile -File .\tests\Test-Static.ps1
pwsh -NoProfile -File .\tests\Test-Static.ps1
```

The PowerShell static suite invokes the companion JavaScript tests when Node.js is available. Run the companion checks and the separate release verifier directly while developing:

```powershell
node --check .\companion-extension\popup.js
node .\tests\Test-Companion.js
.\tests\Test-Release.ps1 -Version 0.2.0
```

Run PSScriptAnalyzer 1.25.0 on every PowerShell source used by CI:

```powershell
Invoke-ScriptAnalyzer `
    -Path .\Watch-ChromeRam.ps1 `
    -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer `
    -Path .\tests\Test-Static.ps1 `
    -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer `
    -Path .\tests\Test-Release.ps1 `
    -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer `
    -Path .\tools\Build-Release.ps1 `
    -Settings .\PSScriptAnalyzerSettings.psd1
```

Test live output without changing Chrome:

```powershell
.\Watch-ChromeRam.ps1 -ListInstances
.\Watch-ChromeRam.ps1 -Once
.\Watch-ChromeRam.ps1 -AllInstances -Once
.\Watch-ChromeRam.ps1 -Once -Json | ConvertFrom-Json
.\Watch-ChromeRam.ps1 -AllInstances -SampleCount 2 -RefreshSeconds 5 -NoClear
```

Load `companion-extension` as an unpacked extension only in a disposable Chrome profile used for testing. Use Chrome 121 or later. Verify current-window scan, review, protected safety-state revalidation, discard, and result confirmation without using tabs that contain real work. If testing incognito, first allow the extension there in Chrome and confirm that each candidate has an explicit **Incognito** label.

## Pull requests

Describe:

- The problem and the intended behavior
- The Windows and PowerShell versions tested
- Any new data the script reads, emits, or stores
- How the change preserves the read-only safety contract
- Any Chrome read-only APIs, optional-permission APIs, or mutation APIs used by the optional companion
- How the companion preserves exact review, separate confirmation, and final-state revalidation

Do not include personal URLs, browser history, raw command lines, or unsanitized diagnostic output in issues or pull requests.
