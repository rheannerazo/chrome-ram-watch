# Security and privacy disclosure

## Permission model

| Capability | Manifest access | How it is used |
| --- | --- | --- |
| Read non-sensitive tab state and call `chrome.tabs.discard(tabId)` | No required permission | Candidate scan, review recheck, final revalidation, explicit discard, and status confirmation |
| Show titles and committed URLs | Optional `tabs` permission | Requested only after the user selects **Show titles and URLs** |
| Read or change website content | Not requested | Never used |
| Contact websites or services | No host permissions | Never used |
| Run in the background | No service worker or background page | Never used |

Chrome's optional `tabs` permission makes the sensitive `title`, `url`, `pendingUrl`, and `favIconUrl` tab fields available to the extension. This code displays only `title` and the committed `url`. It does not use, persist, or transmit those values. You can remove the permission from the popup by selecting **Hide titles and URLs**.

The operation target is always the exact numeric Chrome tab ID. Titles and URLs are display labels only. If a page navigates within the same tab after review, Chrome does not provide an atomic page-identity condition for the later discard call.

## Local data flow

All work happens inside the popup while it is open:

1. The popup queries Chrome for non-sensitive tab state.
2. A pure filter excludes any tab whose state is unsafe, unknown, too recent, or malformed.
3. Your checkbox selection exists only in popup memory.
4. The review action re-fetches and revalidates every selected tab.
5. The final discard action re-fetches each reviewed tab, verifies the exact tab ID, and runs the same safety function immediately before `chrome.tabs.discard(tabId)`.
6. The popup rejects an undefined, wrong-ID, or non-discarded API response. It then re-fetches the tab after the call and reports success only when `discarded === true`.
7. Closing the popup clears its in-memory state.

There is no remote code, external JavaScript dependency, `fetch`, `XMLHttpRequest`, WebSocket, beacon, analytics, telemetry, local storage, synced storage, content script, or background execution.

## Protected states

The filter requires all of these exact values:

- `active === false`
- `pinned === false`
- `audible === false`
- `discarded === false`
- `autoDiscardable === true`
- a finite, positive `lastAccessed` timestamp that is old enough for the chosen threshold

If any value is missing, malformed, or cannot be re-fetched, the tab is skipped. `autoDiscardable === false` is always a hard skip.

## What discard means

`chrome.tabs.discard(tabId)` asks Chrome to unload a tab's page content from memory. It does not close the tab. Chrome keeps the tab in the tab strip and normally reloads it when activated.

Discard can still lose unsaved in-page state. The extension cannot detect that state without broader page access, which it deliberately does not request. The review screen therefore shows an explicit warning before the final action.

## Race boundary

Chrome does not expose an atomic conditional-discard call. A tab can theoretically change in the short interval between the final `chrome.tabs.get(tabId)` result and `chrome.tabs.discard(tabId)`. The implementation reduces this interval by placing the pure safety check directly next to the discard call. Chrome also refuses to discard an active or already discarded tab, but this extension does not rely on that behavior as its only guard.

## Source review checklist

Before loading a modified copy, verify that:

- `manifest.json` has no `permissions`, `host_permissions`, `content_scripts`, or `background` entry;
- `optional_permissions` contains only `tabs`;
- `popup.html` loads only local `popup.css` and `popup.js`;
- `popup.js` contains no networking or storage calls;
- `chrome.permissions.request({ permissions: ["tabs"] })` remains inside the details-button click path;
- every `chrome.tabs.discard` call is preceded by a fresh `chrome.tabs.get` and strict safety check; and
- there is no call to `chrome.tabs.remove` or any process-management API.
