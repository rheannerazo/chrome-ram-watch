# Security and privacy disclosure

## Trust boundary

Chrome RAM Watch: Auto Guard has a separate manual mode and automatic mode.

Manual review does not depend on the required `storage` permission and mutates a tab only after review and a separate final confirmation. Auto Guard starts disabled, requires current versioned consent, and requests its two automatic optional capabilities only from the **Enable Auto Guard** user gesture.

## Permission model

| Capability | Manifest access | Use |
| --- | --- | --- |
| Query non-sensitive tab state and call `chrome.tabs.discard(tabId)` | No permission required | Manual candidates, automatic candidates, exact revalidation, discard, and confirmation |
| Show current titles and committed URLs | Optional `tabs` | Requested separately from **Show titles and URLs**; never used by automatic logic or storage |
| Schedule automatic checks | Optional `alarms` | One exact named alarm every two minutes while Auto Guard is enabled |
| Read physical-memory capacity and availability | Optional `system.memory` | Sustained-pressure gate through `chrome.system.memory.getInfo()` |
| Persist automatic consent, configuration, state, cooldown, and journal | Required non-warning `storage` | `chrome.storage.local` only; this permission does not enable Auto Guard by itself |
| Read or change website content | Not requested | Never used |
| Contact websites or services | No host permissions | Never used |

The service worker is always packaged but remains inert unless required `storage`, both optional automatic permissions, current consent, valid strict configuration, valid local state, and the exact named alarm are present.

Optional permission management is limited to `chrome.permissions.contains()`, `chrome.permissions.request()`, and `chrome.permissions.remove()`.

## Automatic execution contract

Auto Guard samples available physical memory every two minutes. It needs three consecutive low-memory samples, with no normal, invalid, failed, reversed-clock, or longer-than-five-minute gap. The user selects an allowed trigger of 10%, 15%, or 20% available RAM and an inactivity threshold of two, four, eight, or twenty-four hours.

A qualifying cycle reserves a fifteen-minute cooldown and attempts at most two discard API calls. Before each target it rechecks permissions, configuration signature, physical-memory pressure, and storage. It then:

1. Writes a sanitized local intent entry.
2. Fetches the exact numeric tab ID.
3. Applies the full pure safety predicate.
4. Calls `chrome.tabs.discard(tabId)` with no asynchronous gap after that passing predicate.
5. Requires an exact-ID response with `discarded === true`.
6. Fetches the exact tab again and requires `discarded === true`.

Wrong, missing, rejected, or unconfirmed API state aborts the remaining cycle. A normal protected-state change skips that tab. Storage failure before intent means no mutation. Storage or confirmation failure after a call stops the cycle and leaves the existing journal as the conservative record.

Each cycle captures the current in-memory consent epoch. Disable, re-enable, or removal of `alarms`, `system.memory`, or the required storage capability increments that epoch synchronously before asynchronous cleanup begins. The epoch is checked after asynchronous boundaries and once more immediately before `chrome.tabs.discard(tabId)`, with no asynchronous gap. Permission removal also clears the alarm and deletes the stored configuration, state, and journal. Regranting a removed permission cannot resume old consent; a fresh enable gesture is required.

## Protected automatic states

Every automatic target must have exact values:

- valid numeric ID matching the requested ID;
- `active === false`;
- `pinned === false`;
- `audible === false`;
- `discarded === false`;
- `autoDiscardable === true`;
- `incognito === false`;
- `highlighted === false`;
- `status === "complete"`; and
- finite, positive, non-future `lastAccessed` old enough for the configured threshold.

Missing or malformed values fail closed. Auto Guard always excludes incognito tabs, even if Chrome permits this extension in incognito mode.

## Manual execution contract

The manual popup scans only that current window. Open the popup separately in every other Chrome window you want to review. Candidate reading uses `chrome.tabs.query()` and exact revalidation uses `chrome.tabs.get()`.

Manual candidates require inactive, unpinned, explicitly inaudible, not already discarded, explicitly auto-discardable, old-enough tabs. The review action cannot discard. Immediately before the final mutation, the popup re-fetches the exact reviewed tab ID and repeats the full manual safety check. A changed tab means the exact ID or protected active, pinned, audible, discarded, auto-discardable, or inactivity state changed.

The only tab or page-state mutation in either mode is `chrome.tabs.discard(tabId)`. The extension never uses `chrome.tabs.remove()`.

## Local data

Manual selections and results remain in popup memory and disappear when the popup closes. Titles and URLs are display-only and never stored.

While Auto Guard is enabled, `chrome.storage.local` contains only:

- consent and configuration revision;
- selected numeric thresholds;
- pressure streak, aggregate timestamps, cooldown, and aggregate last result; and
- a bounded twenty-entry journal containing timestamp, cycle number, configuration revision, exact tab ID, status, reason code, and available-memory percentage.

The extension never stores titles, URLs, page contents, incognito metadata, raw Chrome error messages, or browsing history. It never uses `chrome.storage.sync`. Disabling Auto Guard clears all three automatic storage keys before the popup removes the two optional automatic permissions.

## Capability exclusions

There is no remote code, external JavaScript dependency, network request, telemetry, content script, host permission, native messaging, process API, process termination, tab closing, tab navigation, tab reload, window removal, synced storage, page capture, or page-content access.

## Residual risk

Chrome does not expose unsaved forms, editors, uploads, calls, captures, or other in-page state without much broader access. `lastAccessed` is activation time, not proof of inactivity inside a page. Users should pin any tab Auto Guard must never touch.

Chrome also has no atomic conditional-discard operation. A small race remains after the final observation. The code minimizes that interval and confirms the result but cannot remove the race completely.

`chrome.system.memory` exposes physical capacity and availability only. It does not prove Chrome caused pressure, measure Windows commit, or identify per-tab RAM. Oldest-first selection is deterministic but may not recover the most memory. Chrome can reload a discarded page later.

## Source review checklist

Before loading a modified copy, verify that:

- Auto Guard still starts disabled and requires current consent;
- required permissions are exactly `storage`, with no host permissions or content scripts;
- optional permissions are exactly `alarms`, `system.memory`, and `tabs`;
- the worker imports only local `guard-core.js`;
- every automatic and manual discard uses an exact tab ID, a fresh fetch, strict immediate revalidation, and post-call confirmation;
- disable, re-enable, and automatic-permission removal synchronously invalidate any active cycle before cleanup begins;
- permission removal clears stored consent so permission regrant alone cannot resume Auto Guard;
- automatic candidates exclude incognito, highlighted, and loading tabs;
- the automatic cycle cap and cooldown remain bounded;
- storage remains local, sanitized, and bounded; and
- there is no networking, native messaging, process control, tab closing, or page injection.
