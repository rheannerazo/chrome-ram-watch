# Security policy

## Supported versions

| Version | Security updates |
| --- | --- |
| 0.2.x | Yes |
| 0.1.x | Yes |

## Report a vulnerability

Use the repository's private vulnerability-reporting option under the Security tab when it is available.

If private reporting is unavailable, open an issue with a non-sensitive summary and ask the maintainers for a private contact route. Do not post exploit details, personal URLs, browser history, raw command lines, or credentials in a public issue.

Include the affected version, Windows version, PowerShell version, reproduction conditions, and expected impact.

The PowerShell watcher is designed to be read-only, file-write-free, process-control-free, and network-free. A report that finds process termination, browser mutation, unexpected file or registry writes, telemetry, or disclosure of raw command lines should be treated as high priority.

The optional cleanup companion has a deliberately narrow mutation boundary. Its permitted read-only tab calls are `chrome.tabs.query()` and `chrome.tabs.get()`. Optional permission management is limited to `chrome.permissions.contains()`, `chrome.permissions.request()`, and `chrome.permissions.remove()`. Its only tab or page-state mutation is the exact, explicitly confirmed `chrome.tabs.discard(tabId)` call for a selected tab that still passes every safety condition. It must not close tabs, kill processes, run background cleanup, inject page code, use host permissions, use native messaging, make network requests, or store browsing metadata.

Treat any of the following companion behavior as high priority:

- automatic or scheduled discarding;
- discarding without the review and separate confirmation steps;
- discarding an active, pinned, audible, already-discarded, non-auto-discardable, recent, unknown-state, or protected safety-state-changed tab;
- calling a discard API without a fresh exact-tab-ID recheck immediately beforehand;
- adding required `tabs` permission, host permissions, content scripts, background workers, network access, telemetry, tab closing, or process control; or
- persisting or transmitting tab titles, URLs, selections, or results.

Here, a changed tab means that its exact ID or a protected active, pinned, audible, discarded, auto-discardable, or inactivity state changed after review. A title or URL change alone is not a protected safety-state change.

See [companion-extension/SECURITY.md](companion-extension/SECURITY.md) for the detailed permission and data-flow disclosure.
