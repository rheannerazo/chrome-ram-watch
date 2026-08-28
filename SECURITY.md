# Security policy

## Supported versions

| Version | Security updates |
| --- | --- |
| 0.3.x | Yes |
| 0.2.x | Yes |
| 0.1.x | Yes |

## Report a vulnerability

Use the repository's private vulnerability-reporting option under the Security tab when it is available.

If private reporting is unavailable, open an issue with a non-sensitive summary and ask the maintainers for a private contact route. Do not post exploit details, personal URLs, browser history, raw command lines, or credentials in a public issue.

Include the affected version, Windows version, PowerShell version, reproduction conditions, and expected impact.

The PowerShell watcher is designed to be read-only, file-write-free, process-control-free, and network-free. A report that finds process termination, browser mutation, unexpected file or registry writes, telemetry, or disclosure of raw command lines should be treated as high priority.

The optional cleanup companion has a deliberately narrow mutation boundary. Its only tab or page-state mutation is `chrome.tabs.discard(tabId)`. The manual flow requires an exact review and separate confirmation. Auto Guard is a separately consented, disabled-by-default background mode that requires the non-warning local `storage` permission, valid optional `alarms` and `system.memory` permissions, sustained physical-memory pressure, a valid cooldown, and strict exact-tab safeguards. Storage alone cannot enable automation. Optional permission management is limited to `chrome.permissions.contains()`, `chrome.permissions.request()`, and `chrome.permissions.remove()`.

Auto Guard may persist only its versioned consent, numeric configuration, aggregate pressure and cooldown state, and a bounded sanitized local journal. The journal may include exact tab IDs but never titles, URLs, page contents, incognito metadata, or raw error messages. It must use `chrome.storage.local`, never synced storage.

Treat any of the following companion behavior as high priority:

- automatic or scheduled discarding without current versioned consent, required local storage, both optional Auto Guard permissions, valid strict configuration, sustained pressure, and cooldown checks;
- manual discarding without the review and separate confirmation steps;
- automatically discarding an incognito, highlighted, loading, active, pinned, audible, already-discarded, non-auto-discardable, recent, unknown-state, or protected safety-state-changed tab;
- calling a discard API without a fresh exact-tab-ID recheck immediately beforehand;
- adding any required permission other than `storage`, host permissions, content scripts, network access, telemetry, native messaging, tab closing, page injection, or process control;
- failing to cancel a pending cycle synchronously when consent changes or an automatic permission is removed;
- retaining consent after automatic-permission removal, or resuming from old consent after permission regrant;
- using any alarm other than the exact Auto Guard alarm or any storage area other than `chrome.storage.local`;
- exceeding the bounded cycle cap or bypassing the global cooldown; or
- persisting or transmitting tab titles, URLs, page contents, incognito metadata, raw errors, or browsing history.

Here, a changed tab means that its exact ID or a protected active, pinned, audible, discarded, auto-discardable, incognito, highlighted, loading, or inactivity state changed after observation. A title or URL change alone is not a protected safety-state change.

See [companion-extension/SECURITY.md](companion-extension/SECURITY.md) for the detailed permission and data-flow disclosure.
