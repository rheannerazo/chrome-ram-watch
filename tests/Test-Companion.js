"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repositoryRoot = path.resolve(__dirname, "..");
const extensionRoot = path.join(repositoryRoot, "companion-extension");
const manifestPath = path.join(extensionRoot, "manifest.json");
const popupPath = path.join(extensionRoot, "popup.html");
const scriptPath = path.join(extensionRoot, "popup.js");
const guardCorePath = path.join(extensionRoot, "guard-core.js");
const serviceWorkerPath = path.join(extensionRoot, "service-worker.js");
const stylePath = path.join(extensionRoot, "popup.css");
const companionReadmePath = path.join(extensionRoot, "README.md");
const readmePath = path.join(repositoryRoot, "README.md");
const contributingPath = path.join(repositoryRoot, "CONTRIBUTING.md");
const securityPath = path.join(repositoryRoot, "SECURITY.md");
const bugReportPath = path.join(repositoryRoot, ".github", "ISSUE_TEMPLATE", "bug-report.yml");

for (const requiredPath of [
  manifestPath,
  popupPath,
  scriptPath,
  guardCorePath,
  serviceWorkerPath,
  stylePath,
  companionReadmePath,
  readmePath,
  contributingPath,
  securityPath,
  bugReportPath
]) {
  assert.equal(fs.existsSync(requiredPath), true, `Required companion file is missing: ${requiredPath}`);
}

const manifestText = fs.readFileSync(manifestPath, "utf8");
const manifest = JSON.parse(manifestText);
const manifestKeys = Object.keys(manifest).sort();

assert.deepEqual(
  manifestKeys,
  [
    "action",
    "background",
    "description",
    "manifest_version",
    "minimum_chrome_version",
    "name",
    "optional_permissions",
    "permissions",
    "version"
  ],
  "The companion manifest gained an unreviewed capability."
);
assert.equal(manifest.manifest_version, 3, "The companion must use Manifest V3.");
assert.equal(manifest.minimum_chrome_version, "121", "lastAccessed requires Chrome 121 or later.");
assert.equal(manifest.version, "0.3.0", "The companion version must match the v0.3 release.");
assert.deepEqual(
  manifest.background,
  { service_worker: "service-worker.js" },
  "The only background entry must be the reviewed Auto Guard service worker."
);
assert.deepEqual(
  manifest.permissions,
  ["storage"],
  "Only the non-warning local storage capability may be required."
);
assert.deepEqual(
  manifest.optional_permissions,
  ["alarms", "system.memory", "tabs"],
  "Only the two runtime Auto Guard capabilities and optional title or URL display may be declared."
);
assert.equal(manifest.action.default_popup, "popup.html", "The action must open the local popup.");

for (const forbiddenKey of [
  "host_permissions",
  "optional_host_permissions",
  "content_scripts",
  "externally_connectable",
  "web_accessible_resources",
  "update_url",
  "content_security_policy"
]) {
  assert.equal(
    Object.prototype.hasOwnProperty.call(manifest, forbiddenKey),
    false,
    `Forbidden manifest key is present: ${forbiddenKey}`
  );
}

const popupText = fs.readFileSync(popupPath, "utf8");
const scriptText = fs.readFileSync(scriptPath, "utf8");
const guardCoreText = fs.readFileSync(guardCorePath, "utf8");
const serviceWorkerText = fs.readFileSync(serviceWorkerPath, "utf8");
const styleText = fs.readFileSync(stylePath, "utf8");
const companionReadmeText = fs.readFileSync(companionReadmePath, "utf8");
const readmeText = fs.readFileSync(readmePath, "utf8");
const contributingText = fs.readFileSync(contributingPath, "utf8");
const securityText = fs.readFileSync(securityPath, "utf8");
const bugReportText = fs.readFileSync(bugReportPath, "utf8");
const runtimeText = `${popupText}\n${scriptText}\n${guardCoreText}\n${serviceWorkerText}\n${styleText}`;

assert.match(popupText, /<link\s+rel="stylesheet"\s+href="popup\.css">/i);
assert.match(popupText, /<script\s+src="popup\.js"\s+defer><\/script>/i);
assert.match(popupText, /<script\s+src="guard-core\.js"\s+defer><\/script>/i);
assert.equal(/<script(?![^>]*\bsrc=)[^>]*>/i.test(popupText), false, "Inline scripts are forbidden.");
assert.equal(/\son[a-z]+\s*=/i.test(popupText), false, "Inline event handlers are forbidden.");
assert.equal(/(?:src|href)\s*=\s*["'](?:https?:)?\/\//i.test(popupText), false, "Remote popup assets are forbidden.");

for (const headingId of ["scan-heading", "review-heading", "results-heading"]) {
  assert.match(
    popupText,
    new RegExp(`<h2\\s+id=["']${headingId}["']\\s+tabindex=["']-1["']>`, "i"),
    `${headingId} must accept programmatic focus after a panel transition.`
  );
}

for (const controlId of [
  "auto-memory-threshold",
  "auto-age-threshold",
  "auto-risk-consent",
  "auto-toggle-button",
  "auto-check-button",
  "auto-status",
  "auto-log-list"
]) {
  assert.match(popupText, new RegExp(`id=["']${controlId}["']`, "i"), `Missing Auto Guard control: ${controlId}`);
}
assert.match(popupText, /Auto Guard starts off/i, "The disabled-by-default trust boundary is not visible.");
assert.match(popupText, /Automatic discard can lose unfinished forms/i, "The automatic unsaved-work warning is missing.");

assert.match(
  scriptText,
  /chrome\.tabs\.query\(\{\s*currentWindow:\s*true,/,
  "Candidate scans must be limited to the popup's current Chrome window."
);
assert.match(scriptText, /tab\.incognito === true/, "Incognito labels must come from tab.incognito.");
assert.match(scriptText, /incognito\.textContent = "Incognito"/, "The visible Incognito label is missing.");

const renderEligibleStart = scriptText.indexOf("function renderEligibleTabs()");
const renderEligibleEnd = scriptText.indexOf("async function refreshEligibleTabs", renderEligibleStart);
const renderEligibleBody = scriptText.slice(renderEligibleStart, renderEligibleEnd);
assert.match(
  renderEligibleBody,
  /label\.append\(checkbox\);\s*appendTabCopy\(label, tab\);/,
  "Each checkbox must use the full visible tab copy as its accessible label."
);
assert.equal(
  /checkbox\.setAttribute\(["']aria-label["']/.test(renderEligibleBody),
  false,
  "A shorter aria-label must not override the identifying details in the visible label."
);

const focusColorMatch = styleText.match(/outline:\s*3px\s+solid\s+(#[0-9a-f]{6})\s*;/i);
assert.ok(focusColorMatch, "A three-pixel opaque hex focus outline is required.");
assert.equal(/outline:[^;]*rgba?\(/i.test(styleText), false, "The focus outline must be opaque.");

function relativeLuminance(hexColor) {
  const channels = hexColor.slice(1).match(/.{2}/g).map((channel) => Number.parseInt(channel, 16) / 255);
  const linear = channels.map((channel) => (
    channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
  ));
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrastRatio(left, right) {
  const lighter = Math.max(relativeLuminance(left), relativeLuminance(right));
  const darker = Math.min(relativeLuminance(left), relativeLuminance(right));
  return (lighter + 0.05) / (darker + 0.05);
}

for (const adjacentColor of ["#ffffff", "#f5f7fb", "#eef2f8"]) {
  assert.ok(
    contrastRatio(focusColorMatch[1], adjacentColor) >= 3,
    `Focus outline contrast fell below 3:1 against ${adjacentColor}.`
  );
}

const safetyApi = require(scriptPath);
const now = 2_000_000_000_000;
const minuteMilliseconds = 60_000;
const eligibleTab = {
  id: 7,
  active: false,
  pinned: false,
  audible: false,
  discarded: false,
  autoDiscardable: true,
  lastAccessed: now - 60 * minuteMilliseconds
};

assert.equal(safetyApi.getIneligibilityReason(eligibleTab, 60, now), null);
assert.equal(
  safetyApi.getIneligibilityReason(
    { ...eligibleTab, lastAccessed: eligibleTab.lastAccessed + 1 },
    60,
    now
  ),
  safetyApi.INELIGIBLE.TOO_RECENT,
  "The inactivity boundary must be inclusive and reject a tab one millisecond too recent."
);

const strictStateCases = [
  ["active", true, "ACTIVE"],
  ["active", undefined, "ACTIVE_UNKNOWN"],
  ["pinned", true, "PINNED"],
  ["pinned", undefined, "PINNED_UNKNOWN"],
  ["audible", true, "AUDIBLE"],
  ["audible", undefined, "AUDIBLE_UNKNOWN"],
  ["discarded", true, "ALREADY_DISCARDED"],
  ["discarded", undefined, "DISCARDED_UNKNOWN"],
  ["autoDiscardable", false, "NOT_AUTO_DISCARDABLE"],
  ["autoDiscardable", undefined, "AUTO_DISCARDABLE_UNKNOWN"]
];

for (const [field, value, reasonName] of strictStateCases) {
  assert.equal(
    safetyApi.getIneligibilityReason({ ...eligibleTab, [field]: value }, 60, now),
    safetyApi.INELIGIBLE[reasonName],
    `${field}=${String(value)} must fail closed.`
  );
}

assert.equal(
  safetyApi.getIneligibilityReason({ ...eligibleTab, id: -1 }, 60, now),
  safetyApi.INELIGIBLE.INVALID_TAB_ID
);
assert.equal(
  safetyApi.getIneligibilityReason({ ...eligibleTab, lastAccessed: now + 1 }, 60, now),
  safetyApi.INELIGIBLE.LAST_ACCESSED_INVALID
);
assert.equal(
  safetyApi.getIneligibilityReason(eligibleTab, 0, now),
  safetyApi.INELIGIBLE.THRESHOLD_INVALID
);
assert.equal(
  safetyApi.getRevalidationReason({ ...eligibleTab, id: 8 }, 7, 60, now),
  safetyApi.INELIGIBLE.TAB_ID_MISMATCH,
  "Final revalidation must be bound to the reviewed tab ID."
);
assert.equal(safetyApi.getRevalidationReason(eligibleTab, 7, 60, now), null);

const unsortedTabs = [
  { ...eligibleTab, id: 3, lastAccessed: now - 120 * minuteMilliseconds },
  { ...eligibleTab, id: 2, lastAccessed: now - 60 * minuteMilliseconds },
  { ...eligibleTab, id: 1, lastAccessed: now - 120 * minuteMilliseconds },
  { ...eligibleTab, id: 4, active: true }
];
assert.deepEqual(
  safetyApi.filterEligibleTabs(unsortedTabs, 60, now).map((tab) => tab.id),
  [1, 3, 2],
  "Eligible tabs must be oldest-first with a deterministic tab-ID tie break."
);
assert.deepEqual(
  unsortedTabs.map((tab) => tab.id),
  [3, 2, 1, 4],
  "Filtering must not mutate Chrome's source array."
);
assert.equal(safetyApi.normalizeThresholdMinutes("120"), 120);
assert.equal(safetyApi.normalizeThresholdMinutes("bogus"), safetyApi.DEFAULT_THRESHOLD_MINUTES);

const forbiddenRuntimePatterns = new Map([
  ["network fetch", /\bfetch\s*\(/i],
  ["XMLHttpRequest", /\bXMLHttpRequest\b/i],
  ["WebSocket", /\bWebSocket\b/i],
  ["EventSource", /\bEventSource\b/i],
  ["beacon", /\bsendBeacon\b/i],
  ["remote URL", /https?:\/\/|["'`]\/\/[A-Za-z0-9]/i],
  ["dynamic import", /\bimport\s*\(/i],
  ["local storage", /\blocalStorage\b/i],
  ["session storage", /\bsessionStorage\b/i],
  ["IndexedDB", /\bindexedDB\b/i],
  ["synced or managed Chrome storage", /\bchrome(?:Api)?\.storage\.(?:sync|managed)\b/i],
  ["native or persistent runtime connection", /\bchrome(?:Api)?\.runtime\.(?:connect|sendNativeMessage|connectNative)\b/i],
  ["scripting API", /\bchrome\.scripting\b/i],
  ["processes API", /\bchrome\.processes\b/i],
  ["tab closing or mutation", /\bchrome\.tabs\.(?:remove|reload|update|create|move|duplicate)\s*\(/i],
  ["window closing", /\bchrome\.windows\.remove\s*\(/i],
  ["timers", /\b(?:setInterval|setTimeout)\s*\(/i],
  ["eval", /\beval\s*\(/i],
  ["Function constructor", /\bnew\s+Function\s*\(/i],
  ["innerHTML sink", /\binnerHTML\b/i],
  ["outerHTML sink", /\bouterHTML\b/i],
  ["HTML insertion sink", /\binsertAdjacentHTML\b/i],
  ["document.write sink", /\bdocument\.write\s*\(/i]
]);

for (const [label, pattern] of forbiddenRuntimePatterns) {
  assert.equal(pattern.test(runtimeText), false, `Forbidden companion capability detected: ${label}`);
}

const importScriptsCalls = [...serviceWorkerText.matchAll(/importScripts\s*\(([^)]*)\)/g)];
assert.equal(importScriptsCalls.length, 1, "The service worker must import exactly one local script.");
assert.equal(importScriptsCalls[0][1].trim(), '"guard-core.js"', "Only the local guard core may be imported.");
assert.equal(/\bimportScripts\s*\(/.test(scriptText + guardCoreText), false, "Only the service worker may call importScripts.");
assert.match(serviceWorkerText, /chromeApi\.storage\.local\.get\(/, "Auto Guard must read only local storage.");
assert.match(serviceWorkerText, /chromeApi\.storage\.local\.set\(/, "Auto Guard must persist only to local storage.");
assert.match(serviceWorkerText, /chromeApi\.storage\.local\.remove\(/, "Auto Guard disable must clear local storage.");
assert.match(serviceWorkerText, /chromeApi\.system\.memory\.getInfo\(/, "Physical-memory measurement is missing.");
assert.match(serviceWorkerText, /chromeApi\.alarms\.onAlarm\.addListener\(/, "The named alarm listener is missing.");

const tabsMethods = [...scriptText.matchAll(/chrome\.tabs\.([A-Za-z][A-Za-z0-9_]*)/g)]
  .map((match) => match[1]);
assert.deepEqual(
  [...new Set(tabsMethods)].sort(),
  ["discard", "get", "query"],
  "Only query, get, and discard are allowed from chrome.tabs."
);
const permissionMethods = [...scriptText.matchAll(/chrome\.permissions\.([A-Za-z][A-Za-z0-9_]*)/g)]
  .map((match) => match[1]);
assert.deepEqual(
  [...new Set(permissionMethods)].sort(),
  ["contains", "remove", "request"],
  "Only contains, request, and remove are allowed from chrome.permissions."
);

const manualDiscardCalls = [...scriptText.matchAll(/chrome\.tabs\.discard\s*\(([^)]*)\)/g)];
assert.equal(manualDiscardCalls.length, 1, "The manual flow must have exactly one tab-discard call site.");
assert.equal(manualDiscardCalls[0][1].trim(), "reviewedTab.id", "Manual discard must use the exact reviewed tab ID.");
const automaticDiscardCalls = [...serviceWorkerText.matchAll(/chromeApi\.tabs\.discard\s*\(([^)]*)\)/g)];
assert.equal(automaticDiscardCalls.length, 1, "Auto Guard must have exactly one tab-discard call site.");
assert.equal(automaticDiscardCalls[0][1].trim(), "candidate.id", "Automatic discard must use the exact candidate tab ID.");

const reviewStart = scriptText.indexOf("async function reviewSelection()");
const reviewEnd = scriptText.indexOf("function createResultItem", reviewStart);
const discardStart = scriptText.indexOf("async function discardReviewedTabs()");
const discardEnd = scriptText.indexOf("elements.tabList.addEventListener", discardStart);
assert.ok(reviewStart >= 0 && reviewEnd > reviewStart, "Could not isolate the review function.");
assert.ok(discardStart >= 0 && discardEnd > discardStart, "Could not isolate the discard function.");

const reviewBody = scriptText.slice(reviewStart, reviewEnd);
const discardBody = scriptText.slice(discardStart, discardEnd);
assert.equal(/chrome\.tabs\.discard/.test(reviewBody), false, "The review action must never discard.");

const reviewShowIndex = reviewBody.indexOf('showPanel("review")');
const reviewRenderIndex = reviewBody.indexOf("renderReviewTabs(");
const reviewFocusIndex = reviewBody.indexOf('focusPanelHeading("review")');
assert.ok(
  reviewShowIndex >= 0 && reviewRenderIndex > reviewShowIndex && reviewFocusIndex > reviewRenderIndex,
  "The review panel must be shown before its live result is updated, then receive focus."
);

const finalGetIndex = discardBody.indexOf("currentTab = await chrome.tabs.get(reviewedTab.id)");
const revalidationIndex = discardBody.indexOf("const reason = getRevalidationReason(");
const discardIndex = discardBody.indexOf("discardResponse = await chrome.tabs.discard(reviewedTab.id)");
const confirmationIndex = discardBody.indexOf("const confirmedTab = await chrome.tabs.get(reviewedTab.id)");
assert.ok(finalGetIndex >= 0, "Final tab.get revalidation is missing.");
assert.ok(revalidationIndex > finalGetIndex, "The pure safety check must follow the fresh tab.get.");
assert.ok(discardIndex > revalidationIndex, "Discard must follow the pure safety check.");
assert.ok(confirmationIndex > discardIndex, "A post-discard tab.get confirmation is required.");
assert.equal(
  /\bawait\b/.test(discardBody.slice(revalidationIndex, discardIndex)),
  false,
  "No asynchronous gap is allowed between the passing safety check and discard."
);
assert.match(
  discardBody.slice(revalidationIndex, discardIndex),
  /if\s*\(reason !== null\)[\s\S]*?continue;/,
  "An unsafe revalidation result must skip the discard call."
);
assert.match(
  discardBody,
  /!discardResponse[\s\S]*?discardResponse\.id !== reviewedTab\.id[\s\S]*?discardResponse\.discarded !== true/,
  "The discard response must identify the exact tab and confirm discarded state."
);

const resultsShowIndex = discardBody.indexOf('showPanel("results")');
const resultsRenderIndex = discardBody.indexOf("renderResults(results)");
const resultsFocusIndex = discardBody.indexOf('focusPanelHeading("results")');
assert.ok(
  resultsShowIndex >= 0 && resultsRenderIndex > resultsShowIndex && resultsFocusIndex > resultsRenderIndex,
  "The results panel must be shown before its live result is updated, then receive focus."
);

const busyGuardIndex = discardBody.indexOf("if (state.busy || state.reviewTabs.length === 0)");
const busySetIndex = discardBody.indexOf("state.busy = true");
const firstAwaitIndex = discardBody.indexOf("await ");
assert.ok(busyGuardIndex >= 0 && busySetIndex > busyGuardIndex, "The final action needs a busy guard.");
assert.ok(firstAwaitIndex > busySetIndex, "The busy lock must be set synchronously before the first await.");

const autoCycleStart = serviceWorkerText.indexOf("async function runAutoGuardCycle(");
const autoCycleEnd = serviceWorkerText.indexOf("function runAutoGuardLocked(", autoCycleStart);
assert.ok(autoCycleStart >= 0 && autoCycleEnd > autoCycleStart, "Could not isolate the automatic cycle.");
const autoCycleBody = serviceWorkerText.slice(autoCycleStart, autoCycleEnd);
const autoIntentIndex = autoCycleBody.indexOf("if (!await reserveIntent(");
const autoFinalGetIndex = autoCycleBody.indexOf("currentTab = await chromeApi.tabs.get(candidate.id)");
const autoRevalidationIndex = autoCycleBody.indexOf("const ineligibilityReason = core.getAutoIneligibilityReason(");
const autoDiscardIndex = autoCycleBody.indexOf("discardPromise = chromeApi.tabs.discard(candidate.id)");
const autoConfirmationIndex = autoCycleBody.indexOf("confirmedTab = await chromeApi.tabs.get(candidate.id)");
assert.ok(autoIntentIndex >= 0, "An automatic intent must be persisted before mutation.");
assert.ok(autoFinalGetIndex > autoIntentIndex, "The exact final tab fetch must follow the persisted intent.");
assert.ok(autoRevalidationIndex > autoFinalGetIndex, "Automatic pure revalidation must follow the fresh exact-ID fetch.");
assert.ok(autoDiscardIndex > autoRevalidationIndex, "Automatic discard must follow strict revalidation.");
assert.ok(autoConfirmationIndex > autoDiscardIndex, "Automatic discard requires a fresh post-call confirmation.");
const autoImmediateCallStart = autoCycleBody.indexOf("let discardPromise;", autoRevalidationIndex);
assert.ok(autoImmediateCallStart > autoRevalidationIndex && autoImmediateCallStart < autoDiscardIndex);
assert.equal(
  /\bawait\b/.test(autoCycleBody.slice(autoImmediateCallStart, autoDiscardIndex)),
  false,
  "No asynchronous gap is allowed immediately before the automatic discard call."
);
assert.match(
  autoCycleBody,
  /!discardResponse[\s\S]*?discardResponse\.id !== candidate\.id[\s\S]*?discardResponse\.discarded !== true/,
  "Automatic discard must reject an undefined, wrong-ID, or unconfirmed response."
);
assert.match(
  serviceWorkerText,
  /if \(activeCyclePromise\) \{[\s\S]*?return activeCyclePromise;[\s\S]*?activeCyclePromise = runAutoGuardCycle/,
  "Overlapping automatic cycles must share one in-memory lock."
);

assert.match(
  scriptText,
  /elements\.reviewButton\.addEventListener\("click",\s*\(\) => \{\s*void reviewSelection\(\);/,
  "The review step must have its own click action."
);
assert.match(
  scriptText,
  /elements\.discardButton\.addEventListener\("click",\s*\(\) => \{\s*void discardReviewedTabs\(\);/,
  "The final discard step must have its own separate click action."
);

for (const documentation of [companionReadmeText, readmeText]) {
  assert.match(documentation, /scans only (?:that|this) current window/i, "Current-window scan scope is undocumented.");
  assert.match(documentation, /open (?:it|the popup) separately/i, "Per-window popup use is undocumented.");
  assert.match(documentation, /tab\.incognito/, "Incognito labels are not tied to tab.incognito in documentation.");
  assert.match(documentation, /chrome\.tabs\.query\(\)/, "Permitted read-only tabs.query is undocumented.");
  assert.match(documentation, /chrome\.tabs\.get\(\)/, "Permitted read-only tabs.get is undocumented.");
  assert.match(documentation, /only tab or page-state mutation/i, "The exact mutation boundary is undocumented.");
}

for (const documentation of [companionReadmeText, readmeText, securityText]) {
  assert.match(documentation, /changed tab means/i, "Protected-state change wording is missing.");
}

for (const documentation of [companionReadmeText, readmeText, contributingText, securityText]) {
  for (const method of ["contains", "request", "remove"]) {
    assert.match(
      documentation,
      new RegExp(`chrome\\.permissions\\.${method}\\(\\)`),
      `Permitted permissions.${method} is undocumented.`
    );
  }
}

assert.match(bugReportText, /label:\s*Command or exact UI steps/, "Bug reports must accept commands or UI steps.");
const chromeFieldStart = bugReportText.indexOf("id: chrome");
const commandFieldStart = bugReportText.indexOf("id: command", chromeFieldStart);
const chromeFieldText = bugReportText.slice(chromeFieldStart, commandFieldStart);
assert.ok(chromeFieldStart >= 0 && commandFieldStart > chromeFieldStart, "Could not isolate Chrome version field.");
assert.match(chromeFieldText, /cleanup-companion reports/i, "Chrome version requirement needs companion guidance.");
assert.match(chromeFieldText, /validations:\s*\r?\n\s*required:\s*true/, "Chrome version must be enforced.");

console.log("All Chrome RAM Watch companion tests passed.");
