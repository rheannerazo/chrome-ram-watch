# Chrome RAM Watch: Auto Guard

This optional Manifest V3 v0.3 companion has two separate cleanup modes:

- Auto Guard checks physical-memory availability in the background and, only after sustained pressure, discards a tightly bounded set of eligible inactive tabs.
- Manual review scans only the current Chrome window and discards only exact tabs you review and confirm.

Discard unloads page content from memory while keeping the tab in the tab strip. Chrome reloads the page when you activate it.

The extension never closes tabs, kills processes, injects page code, reads page contents, makes network requests, or sends telemetry. The PowerShell watcher remains read-only.

## Install locally

1. Open `chrome://extensions` in Chrome.
2. Turn on **Developer mode**.
3. Select **Load unpacked**.
4. Choose this `companion-extension` folder.
5. Pin **Chrome RAM Watch: Auto Guard** if you want quick access.

The manifest requires only Chrome's non-warning `storage` permission. It is used only for local Auto Guard consent, configuration, aggregate state, cooldown, and the bounded sanitized journal. Auto Guard stays off until you enable it, and scheduling, physical-memory access, and title or URL display remain optional.

## Enable Auto Guard

Auto Guard starts disabled.

1. Open the popup.
2. Choose an available-memory trigger and minimum inactive age. The defaults are 15% available physical RAM and four hours inactive.
3. Read the unsaved-work warning and select the consent checkbox.
4. Select **Enable Auto Guard**.

That user gesture requests two optional permissions:

- `alarms` schedules a local check every two minutes;
- `system.memory` reads total and available physical-memory capacity.

The required non-warning `storage` permission keeps the versioned consent, strict configuration, aggregate status, cooldown, and bounded local action journal across service-worker restarts. It does not enable Auto Guard by itself.

Auto Guard requires three consecutive valid low-memory samples. A missing or invalid reading, clock rollback, normal reading, or gap longer than five minutes resets continuity. After the third qualifying sample, it attempts no more than two oldest eligible tabs, then reserves a fifteen-minute global cooldown before another automatic cycle.

Before every automatic target, it confirms that permission, consent, configuration revision, pressure, and cooldown state remain valid. It writes a sanitized intent record, fetches the exact tab ID, applies the full safety check, checks the current in-memory consent epoch, calls `chrome.tabs.discard(tabId)` with no asynchronous gap after those checks, validates Chrome's response, and fetches the tab once more to confirm `discarded === true`.

An API anomaly, invalid response, unconfirmed result, configuration change, consent-epoch change, or storage failure stops the remaining cycle. Disable, re-enable, or removal of an automatic permission invalidates the epoch synchronously, so a cycle waiting on Chrome cannot issue a later discard. A protected tab-state change skips that tab. Automatic actions are oldest-first with a numeric tab-ID tie break.

Disable Auto Guard from the popup to clear its alarm, automatic settings, state, and journal, then remove only the optional `alarms` and `system.memory` permissions. Removing either permission also disarms Auto Guard and deletes its stored consent and automatic state. Granting it again cannot resume the old consent; a fresh enable gesture is required. The required local `storage` permission and separate optional `tabs` permission are unchanged.

## Automatic safety contract

An automatic candidate must have every exact state:

- a valid numeric tab ID;
- `active === false`;
- `pinned === false`;
- `audible === false`;
- `discarded === false`;
- `autoDiscardable === true`;
- `incognito === false`;
- `highlighted === false`;
- `status === "complete"`; and
- a finite `lastAccessed` timestamp at or beyond the configured inactivity threshold.

Missing, malformed, future, or unknown values always fail closed. Auto Guard ignores incognito tabs even if Chrome later allows the extension in incognito mode.

## Use manual review

1. Open the extension popup in the Chrome window you want to review. It scans only that current window. Open the popup separately in every other Chrome window you want to review.
2. Choose an inactivity threshold.
3. Optional: select **Show titles and URLs**. Chrome requests the optional `tabs` permission. Without it, exact tab IDs remain available.
4. Select eligible tabs.
5. Select **Review selected tabs**. The extension re-fetches each selection and removes any tab that no longer meets the manual safeguards.
6. Review the exact tab IDs and unsaved-work warning.
7. Separately select **Discard selected tabs**.
8. Keep the popup open until the confirmed results appear.

Manual review requires inactive, unpinned, explicitly inaudible, not already discarded, explicitly auto-discardable, old-enough tabs. Missing state is never treated as safe. A changed tab means its exact ID or protected active, pinned, audible, discarded, auto-discardable, or inactivity state changed.

If Chrome allows this extension in incognito mode, manual candidates are labeled **Incognito** from Chrome's `tab.incognito` value. Auto Guard still ignores them.

## Data and capability boundaries

The service worker and popup use only these Chrome capabilities:

- `chrome.permissions.contains()`, `chrome.permissions.request()`, and `chrome.permissions.remove()`;
- `chrome.tabs.query()`, `chrome.tabs.get()`, and `chrome.tabs.discard()`;
- `chrome.system.memory.getInfo()`;
- the named Auto Guard alarm through `chrome.alarms`; and
- `chrome.storage.local` for automatic configuration, aggregate state, and the bounded sanitized journal.

The only tab or page-state mutation in either mode is `chrome.tabs.discard(tabId)`. The extension never closes a tab.

The journal can contain timestamp, cycle number, configuration revision, exact tab ID, status, reason code, and available-memory percentage. It never stores titles, URLs, page contents, incognito details, raw error messages, or browsing history, and it never uses synced storage.

The optional `tabs` permission exposes sensitive title and URL fields only while granted. The popup may display the current title and committed URL, but neither automatic logic nor storage uses them.

## Important limitations

- The extension cannot detect unfinished forms, drafts, editors, uploads, calls, captures, or other unsaved page state. Pin any tab Auto Guard must never touch.
- Chrome does not provide an atomic conditional-discard operation. The implementation minimizes, but cannot remove, the small race after the final state observation.
- `lastAccessed` is the last activation time, not proof that a page has no background work.
- `chrome.system.memory` reports physical capacity and availability only. It does not report Windows commit pressure, Chrome-only RAM, or per-tab memory.
- Oldest-first selection is deterministic but may not choose the largest tab.
- Alarms can be delayed or coalesced after sleep. A long gap resets the pressure streak.
- Chrome decides the actual memory effect. A discarded tab can reload itself later.

## Local validation

From the repository root, run:

```powershell
node --check .\companion-extension\guard-core.js
node --check .\companion-extension\service-worker.js
node --check .\companion-extension\popup.js
node .\tests\Test-Companion.js
node .\tests\Test-AutoGuard.js
```

See [SECURITY.md](SECURITY.md) for the detailed permission and storage disclosure.

## Chrome API references

- [Chrome Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs)
- [Chrome System Memory API](https://developer.chrome.com/docs/extensions/reference/api/system/memory)
- [Chrome Alarms API](https://developer.chrome.com/docs/extensions/reference/api/alarms)
- [Chrome Storage API](https://developer.chrome.com/docs/extensions/reference/api/storage)
- [Chrome Permissions API](https://developer.chrome.com/docs/extensions/reference/api/permissions)
