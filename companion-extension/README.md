# Chrome RAM Watch: Safe Tab Discard

This optional Manifest V3 v0.2 companion lets you review and explicitly discard inactive Chrome tabs. Discarding unloads page content from memory while keeping the tab in the tab strip. Chrome reloads the page when you activate the tab.

The extension does not measure RAM. Use the main Chrome RAM Watch script for diagnosis, then use this companion only when you choose to unload specific inactive tabs.

## Safety contract

The extension:

- never discards a tab automatically;
- never closes a tab;
- never kills a process;
- never runs a background worker, timer, or scheduled task;
- never sends network requests or telemetry;
- never requests host permissions;
- never injects code into pages or reads page contents;
- never persists titles, URLs, selections, or results; and
- never treats missing tab state as safe.

Only tabs that meet every condition appear in the candidate list:

- inactive in their Chrome window;
- unpinned;
- explicitly reported as inaudible;
- not already discarded;
- explicitly reported as auto-discardable; and
- last activated at least as long ago as the selected threshold.

Tabs with a missing or invalid `lastAccessed` value are excluded. Chrome 121 or later is required because `tabs.Tab.lastAccessed` was added in Chrome 121.

## Install locally

1. Open `chrome://extensions` in Chrome.
2. Turn on **Developer mode**.
3. Select **Load unpacked**.
4. Choose this `companion-extension` folder.
5. Pin **Chrome RAM Watch: Safe Tab Discard** if you want quick access.

No permission is required at install time. The manifest declares `tabs` only as an optional runtime permission.

The permitted read-only tab calls are `chrome.tabs.query()` and `chrome.tabs.get()`. Optional permission management is limited to `chrome.permissions.contains()`, `chrome.permissions.request()`, and `chrome.permissions.remove()`. The only tab or page-state mutation is the exact, explicitly confirmed `chrome.tabs.discard(tabId)` call.

## Use the review flow

1. Open the extension popup in the Chrome window you want to review. The popup scans only that current window and only while it is open. Open it separately in every other Chrome window you want to review.
2. Choose an inactivity threshold.
3. Optional: select **Show titles and URLs**. Chrome asks whether to grant the optional `tabs` permission. Without it, the full workflow uses exact tab IDs and does not show titles or URLs.
4. Select one or more eligible tabs.
5. Select **Review selected tabs**. The extension re-fetches every selection and removes tabs that no longer meet the safety rules.
6. Review the exact tab IDs and, if permission is enabled, titles and committed URLs. Read the unsaved-work warning.
7. Select **Discard selected tabs** as the separate final action.
8. Keep the popup open until the results appear. Before every discard call, the extension re-fetches the tab and applies the same strict safety check again. It then fetches the tab once more and reports success only if Chrome returns `discarded: true`.

Use **Hide titles and URLs** to remove the optional `tabs` permission.

## Important limitations

- The extension cannot inspect forms, editors, drafts, uploads, or unsaved page state because it has no host permissions or content scripts. Treat the review warning seriously.
- A protected safety state can change after any observation. Chrome does not provide an atomic "discard only if these properties still match" operation. The extension minimizes that race by placing its final synchronous safety check directly before `chrome.tabs.discard(tabId)`. Here, a changed tab means that its exact ID or a protected active, pinned, audible, discarded, auto-discardable, or inactivity state changed. A title or URL change alone is not treated as a protected-state change.
- Review and discard are bound to the exact Chrome tab ID. Optional titles and URLs are display labels, not an atomic page-identity lock, so they can change if the same tab navigates.
- Chrome decides the actual memory effect. This extension does not estimate or claim a specific amount of RAM recovered.
- A discarded tab can reload itself if it becomes active or Chrome otherwise restores it. The result screen reports only the state confirmed immediately after the request.
- Incognito tabs are visible only if Chrome allows this extension in incognito mode through Chrome's extension settings. Open the popup separately in each incognito window you want to review. Every incognito candidate is labeled **Incognito** from Chrome's `tab.incognito` value.

## Local validation

From this folder, run:

```powershell
node --check .\popup.js
node -e "JSON.parse(require('fs').readFileSync('manifest.json', 'utf8')); console.log('manifest ok')"
```

The pure safety helpers in `popup.js` are available through guarded CommonJS exports when the file is loaded by Node. Chrome never uses that export path. This makes the eligibility rules testable without a browser DOM.

## Chrome API references

- [Chrome Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs)
- [Chrome Permissions API](https://developer.chrome.com/docs/extensions/reference/api/permissions)
- [Declare extension permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)

See [SECURITY.md](SECURITY.md) for the full permission and data-flow disclosure.
