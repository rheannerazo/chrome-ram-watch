# Contributing

Thank you for helping improve Chrome RAM Watch.

## Before opening a change

- Search existing issues before opening a duplicate.
- Keep the PowerShell watcher read-only.
- Do not add tab closing, tab discarding, process termination, registry writes, file writes, remote-code execution, telemetry, or page-content collection to the main watcher.
- Keep cleanup behavior in the separate optional companion. Manual cleanup requires an exact review plus a separate final confirmation. Automatic cleanup must remain disabled by default and require current versioned consent, required local `storage`, both optional Auto Guard permissions, strict configuration, sustained physical-memory pressure, cooldown, and bounded cycle checks.
- The companion's only tab or page-state mutation may be `chrome.tabs.discard(tabId)` for an exact tab ID that passes a fresh safety recheck immediately before the call. Every automatic action also requires a sanitized persisted intent and confirmed final state.
- Keep read-only tab access limited to `chrome.tabs.query()` and `chrome.tabs.get()`. Keep optional permission management limited to `chrome.permissions.contains()`, `chrome.permissions.request()`, and `chrome.permissions.remove()`.
- Auto Guard may use only the exact named `chrome.alarms` alarm, `chrome.system.memory.getInfo()`, and bounded sanitized `chrome.storage.local` state. Required permissions must remain exactly `storage`; optional permissions must remain exactly `alarms`, `system.memory`, and `tabs`. Do not add `chrome.tabs.remove`, window removal, host permissions, content scripts, native messaging, network access, synced storage, page injection, or process control to the companion.
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
node --check .\companion-extension\guard-core.js
node --check .\companion-extension\service-worker.js
node .\tests\Test-Companion.js
node .\tests\Test-AutoGuard.js
.\tests\Test-Release.ps1 -Version 0.3.0
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

Load `companion-extension` as an unpacked extension only in a disposable Chrome profile used for testing. Use Chrome 121 or later and tabs that contain no real work. Verify current-window manual scan, review, protected safety-state revalidation, discard, and result confirmation. Separately verify Auto Guard starts off, requests only optional `alarms` and `system.memory`, requires three valid pressure samples, honors the cycle cap and cooldown, logs sanitized outcomes, and fully disables. Test disable, re-enable, and automatic-permission removal while a final tab lookup is pending; none may issue a later discard. Regranting a removed permission must not resume old consent. If testing incognito, confirm manual candidates have an explicit **Incognito** label and Auto Guard never targets them.

## Pull requests

Describe:

- The problem and the intended behavior
- The Windows and PowerShell versions tested
- Any new data the script reads, emits, or stores
- How the change preserves the read-only safety contract
- Any Chrome read-only APIs, optional-permission APIs, or mutation APIs used by the optional companion
- How manual cleanup preserves exact review, separate confirmation, and final-state revalidation
- How automatic cleanup preserves explicit consent, pressure continuity, exact-tab safeguards, bounded execution, local data minimization, and fail-closed recovery

Do not include personal URLs, browser history, raw command lines, or unsanitized diagnostic output in issues or pull requests.
