"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repositoryRoot = path.resolve(__dirname, "..");
const extensionRoot = path.join(repositoryRoot, "companion-extension");
const manifestPath = path.join(extensionRoot, "manifest.json");
const popupPath = path.join(extensionRoot, "popup.html");
const scriptPath = path.join(extensionRoot, "popup.js");
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
    "description",
    "manifest_version",
    "minimum_chrome_version",
    "name",
    "optional_permissions",
    "version"
  ],
  "The companion manifest gained an unreviewed capability."
);
assert.equal(manifest.manifest_version, 3, "The companion must use Manifest V3.");
assert.equal(manifest.minimum_chrome_version, "121", "lastAccessed requires Chrome 121 or later.");
assert.match(manifest.version, /^\d+\.\d+\.\d+$/, "The extension version must be a three-part number.");
assert.deepEqual(
  manifest.optional_permissions,
  ["tabs"],
  "The only optional permission may be tabs, used for user-requested titles and URLs."
);
assert.equal(manifest.action.default_popup, "popup.html", "The action must open the local popup.");

for (const forbiddenKey of [
  "permissions",
  "host_permissions",
  "optional_host_permissions",
  "background",
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
const styleText = fs.readFileSync(stylePath, "utf8");
const companionReadmeText = fs.readFileSync(companionReadmePath, "utf8");
const readmeText = fs.readFileSync(readmePath, "utf8");
const contributingText = fs.readFileSync(contributingPath, "utf8");
const securityText = fs.readFileSync(securityPath, "utf8");
const bugReportText = fs.readFileSync(bugReportPath, "utf8");
const runtimeText = `${popupText}\n${scriptText}\n${styleText}`;

assert.match(popupText, /<link\s+rel="stylesheet"\s+href="popup\.css">/i);
assert.match(popupText, /<script\s+src="popup\.js"\s+defer><\/script>/i);
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
  ["importScripts", /\bimportScripts\s*\(/i],
  ["local storage", /\blocalStorage\b/i],
  ["session storage", /\bsessionStorage\b/i],
  ["IndexedDB", /\bindexedDB\b/i],
  ["Chrome storage", /\bchrome\.storage\b/i],
  ["runtime messaging", /\bchrome\.runtime\.(?:sendMessage|connect|sendNativeMessage|connectNative)\b/i],
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

const discardCalls = [...scriptText.matchAll(/chrome\.tabs\.discard\s*\(([^)]*)\)/g)];
assert.equal(discardCalls.length, 1, "There must be exactly one tab-discard call site.");
assert.equal(discardCalls[0][1].trim(), "reviewedTab.id", "Discard must always receive the exact reviewed tab ID.");

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
