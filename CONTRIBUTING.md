# Contributing

Thank you for helping improve Chrome RAM Watch.

## Before opening a change

- Search existing issues before opening a duplicate.
- Keep the tool read-only unless a proposal is discussed and accepted first.
- Do not add tab closing, process termination, registry writes, remote-code execution, telemetry, or page-content collection to the main watcher.
- Avoid logging raw Chrome command lines because they can contain local paths or other sensitive values.

## Local checks

Run the dependency-free test suite in both supported PowerShell editions when available:

```powershell
powershell.exe -NoProfile -File .\tests\Test-Static.ps1
pwsh -NoProfile -File .\tests\Test-Static.ps1
```

Run PSScriptAnalyzer 1.25.0:

```powershell
Invoke-ScriptAnalyzer `
    -Path .\Watch-ChromeRam.ps1 `
    -Settings .\PSScriptAnalyzerSettings.psd1
```

Test live output without changing Chrome:

```powershell
.\Watch-ChromeRam.ps1 -ListInstances
.\Watch-ChromeRam.ps1 -Once
.\Watch-ChromeRam.ps1 -Once -Json | ConvertFrom-Json
```

## Pull requests

Describe:

- The problem and the intended behavior
- The Windows and PowerShell versions tested
- Any new data the script reads, emits, or stores
- How the change preserves the read-only safety contract

Do not include personal URLs, browser history, raw command lines, or unsanitized diagnostic output in issues or pull requests.
