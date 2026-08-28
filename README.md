# Chrome RAM Watch

![Windows](https://img.shields.io/badge/platform-Windows-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![License](https://img.shields.io/badge/license-MIT-2EA44F)

![Chrome RAM Watch terminal preview](assets/social-preview.png)

**Find the Chrome process eating your RAM without installing an extension or killing tabs.**

Chrome RAM Watch is a read-only PowerShell monitor for Chrome on Windows. It shows system memory pressure, total memory for one Chrome browser process tree, and the renderer or utility process IDs using the most memory.

It does not close tabs, end processes, inspect page contents, change Chrome settings, require administrator rights, or use the network.

## What it shows

- Available physical RAM and system commit pressure
- Memory paging activity and disk page-read operations
- Summed working set and private bytes for one Chrome browser instance
- Largest Chrome process IDs, types, extension markers, memory, and CPU
- Continuous terminal updates or one-shot JSON output
- A manual route from a renderer PID to its current page

## Requirements

- Windows 10 or Windows 11
- Google Chrome or another Chromium build whose process is named `chrome.exe`
- Windows PowerShell 5.1 or PowerShell 7

No module installation is required.

## Quick start

Download a release or the repository source, open PowerShell in the extracted folder, and inspect the script before running it:

```powershell
Get-Content .\Watch-ChromeRam.ps1 | more
.\Watch-ChromeRam.ps1
```

The display refreshes every 10 seconds. Press `Ctrl+C` to stop it.

If Windows marks a downloaded script as blocked, inspect it first, then remove only that downloaded-file marker:

```powershell
Unblock-File .\Watch-ChromeRam.ps1
```

The project does not recommend piping remote code into PowerShell or bypassing the execution policy.

## Common commands

```powershell
# List selectable Chrome browser instances
.\Watch-ChromeRam.ps1 -ListInstances

# Watch a specific browser process tree
.\Watch-ChromeRam.ps1 -BrowserProcessId 10536

# Print one sample and exit
.\Watch-ChromeRam.ps1 -Once

# Produce machine-readable output
.\Watch-ChromeRam.ps1 -Once -Json

# Show the 20 largest processes every 15 seconds
.\Watch-ChromeRam.ps1 -Top 20 -RefreshSeconds 15
```

| Parameter | Purpose |
| --- | --- |
| `-BrowserProcessId` | Selects a root Chrome browser PID. |
| `-ListInstances` | Lists root browser PIDs in the current Windows session. |
| `-RefreshSeconds` | Sets the refresh interval from 5 to 300 seconds. Default: 10. |
| `-Top` | Sets the number of process rows from 3 to 50. Default: 12. |
| `-Once` | Prints one sample without clearing the terminal. |
| `-Json` | Returns JSON and requires `-Once`. |
| `-NoClear` | Keeps earlier continuous samples in the terminal. |

## Important scope: browser instance, not Chrome profile

Chrome normally permits one browser process per user-data directory, while regular profiles are subdirectories within that user-data directory. Several profiles can therefore share the same browser process tree.

Chrome RAM Watch monitors that process tree. If it displays a launch profile such as `Profile 35`, treat it only as the profile used to start the browser instance. The totals may include other open profiles in the same instance. True per-profile process attribution requires browser-side information that Windows process counters do not provide.

By default, the script selects the single standard Chrome instance in the current Windows session and ignores instances started with a custom `--user-data-dir`. Use `-ListInstances` and `-BrowserProcessId` when more than one instance is present.

Relevant Chromium documentation:

- [Chrome user-data directory structure](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)
- [Chrome ProcessSingleton behavior](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/process_singleton.h)

## Map a renderer PID to a page

Chrome process IDs change when tabs reload or Chrome restarts. Use a current renderer PID from the watcher.

1. Paste `chrome://process-internals/#web-contents` into Chrome's address bar.
2. Press `Ctrl+F` and search for the PID.
3. Find `Frame[PID:routing_id]` and read the associated site and URL.
4. Save unfinished work before reloading or closing that page.

Chromium documents this internal diagnostic view in its [process model documentation](https://chromium.googlesource.com/chromium/src/+/main/docs/process_model_and_site_isolation.md). Its layout can change between Chrome versions.

## Read the measurements

| Measurement | Meaning |
| --- | --- |
| Available RAM | Physical memory Windows can provide immediately. |
| Commit | Memory Windows has promised to processes compared with the commit limit. |
| Summed working set | Sum of resident pages reported for each Chrome process. It is approximate because shared pages can be counted more than once. |
| Private bytes | Memory allocated privately by the selected Chrome process tree. |
| Pages/sec | System-wide pages moved to or from disk to resolve memory faults. It is not limited to the pagefile. |
| Page-read operations/sec | System-wide disk read operations used to resolve hard page faults. One operation can read several pages. |
| CPUPercent | Approximate share of total logical-processor capacity used since the previous sample. It is blank on the first sample. |

See Microsoft's [working-set documentation](https://learn.microsoft.com/en-us/windows/win32/memory/working-set) for the limits of per-process working-set totals.

## JSON output

`-Once -Json` returns schema `chrome-ram-watch/v1`. The scope explicitly states `browser-process-tree` and `MayIncludeProfiles: true` so downstream tools do not mistake the result for per-profile attribution.

```powershell
$sample = .\Watch-ChromeRam.ps1 -Once -Json | ConvertFrom-Json
$sample.Chrome.SummedWorkingSetGB
$sample.TopProcesses
```

## Safety and privacy

The script reads:

- Process IDs, parent IDs, session IDs, executable paths, and Chrome command lines
- Per-process CPU, working-set, and private-memory counters
- Windows physical-memory, commit, and paging counters

Chrome command lines are used only to recognize process type, launch-profile hints, and custom user-data instances. Raw command lines and page URLs are never emitted. `-ListInstances` does display the Chrome executable path so multiple channels can be distinguished.

`Watch-ChromeRam.ps1` contains no network request, process termination, registry write, file deletion, tab control, or Chrome-setting change. Static tests enforce the watcher's no-network and no-process-control contract.

Chrome's extension [`processes` API](https://developer.chrome.com/docs/extensions/reference/api/processes) can expose richer browser-side details, but Chrome currently documents it as Dev-channel-only. This tool uses Windows diagnostics so it can remain extension-free and permission-free.

## Limitations

- It does not reliably separate profiles sharing one Chrome user-data directory.
- It does not monitor Microsoft Edge, Brave, or processes not named `chrome.exe`.
- Summed working set is an approximation, not exact unique physical RAM.
- Renderer PIDs can change at any time.
- The internal PID-to-page view can change between Chrome releases.
- Continuous mode retries when Chrome restarts or process data is temporarily unavailable. A specifically selected root PID must be selected again after that PID exits.

## Troubleshooting

**No standard Chrome browser instance was detected**

Run `.\Watch-ChromeRam.ps1 -ListInstances`, then select a listed root with `-BrowserProcessId`.

**Multiple standard Chrome browser instances were detected**

Use `-ListInstances` to compare the root PID, channel, startup-profile hint, and executable path. Then select the intended PID.

**CPU values are blank**

CPU needs two samples. Wait for the next refresh.

**The script is blocked after download**

Review the source, then run `Unblock-File .\Watch-ChromeRam.ps1`. Do not weaken the machine-wide execution policy for this tool.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for local checks and pull-request guidance. Report security concerns using [SECURITY.md](SECURITY.md).

Chrome RAM Watch is released under the [MIT License](LICENSE).

Google Chrome is a trademark of Google LLC. Chrome RAM Watch is an independent project and is not affiliated with or endorsed by Google.
