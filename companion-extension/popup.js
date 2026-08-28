(function () {
  "use strict";

  const MINUTE_MS = 60 * 1000;
  const DEFAULT_THRESHOLD_MINUTES = 60;
  const ALLOWED_THRESHOLDS = new Set([15, 30, 60, 120, 240, 480, 1440]);

  const INELIGIBLE = Object.freeze({
    INVALID_TAB_ID: "invalid-tab-id",
    TAB_ID_MISMATCH: "tab-id-mismatch",
    ACTIVE: "active",
    ACTIVE_UNKNOWN: "active-unknown",
    PINNED: "pinned",
    PINNED_UNKNOWN: "pinned-unknown",
    AUDIBLE: "audible",
    AUDIBLE_UNKNOWN: "audible-unknown",
    ALREADY_DISCARDED: "already-discarded",
    DISCARDED_UNKNOWN: "discarded-unknown",
    NOT_AUTO_DISCARDABLE: "not-auto-discardable",
    AUTO_DISCARDABLE_UNKNOWN: "auto-discardable-unknown",
    LAST_ACCESSED_INVALID: "last-accessed-invalid",
    THRESHOLD_INVALID: "threshold-invalid",
    TOO_RECENT: "too-recent"
  });

  /**
   * Return null only when every safety property is explicitly eligible.
   * Unknown or malformed state is never treated as safe.
   */
  function getIneligibilityReason(tab, thresholdMinutes, nowMilliseconds) {
    const now = nowMilliseconds === undefined ? Date.now() : nowMilliseconds;

    if (!tab || !Number.isInteger(tab.id) || tab.id < 0) {
      return INELIGIBLE.INVALID_TAB_ID;
    }

    if (tab.active !== false) {
      return tab.active === true ? INELIGIBLE.ACTIVE : INELIGIBLE.ACTIVE_UNKNOWN;
    }

    if (tab.pinned !== false) {
      return tab.pinned === true ? INELIGIBLE.PINNED : INELIGIBLE.PINNED_UNKNOWN;
    }

    if (tab.audible !== false) {
      return tab.audible === true ? INELIGIBLE.AUDIBLE : INELIGIBLE.AUDIBLE_UNKNOWN;
    }

    if (tab.discarded !== false) {
      return tab.discarded === true
        ? INELIGIBLE.ALREADY_DISCARDED
        : INELIGIBLE.DISCARDED_UNKNOWN;
    }

    if (tab.autoDiscardable !== true) {
      return tab.autoDiscardable === false
        ? INELIGIBLE.NOT_AUTO_DISCARDABLE
        : INELIGIBLE.AUTO_DISCARDABLE_UNKNOWN;
    }

    if (!Number.isFinite(thresholdMinutes) || thresholdMinutes <= 0) {
      return INELIGIBLE.THRESHOLD_INVALID;
    }

    if (
      !Number.isFinite(now) ||
      now <= 0 ||
      !Number.isFinite(tab.lastAccessed) ||
      tab.lastAccessed <= 0 ||
      tab.lastAccessed > now
    ) {
      return INELIGIBLE.LAST_ACCESSED_INVALID;
    }

    if (now - tab.lastAccessed < thresholdMinutes * MINUTE_MS) {
      return INELIGIBLE.TOO_RECENT;
    }

    return null;
  }

  /**
   * Return a new, oldest-first array without mutating the source array.
   */
  function filterEligibleTabs(tabs, thresholdMinutes, nowMilliseconds) {
    if (!Array.isArray(tabs)) {
      return [];
    }

    const now = nowMilliseconds === undefined ? Date.now() : nowMilliseconds;
    return tabs
      .filter((tab) => getIneligibilityReason(tab, thresholdMinutes, now) === null)
      .slice()
      .sort((left, right) => {
        const ageOrder = left.lastAccessed - right.lastAccessed;
        return ageOrder !== 0 ? ageOrder : left.id - right.id;
      });
  }

  /**
   * Apply the eligibility rules and bind the result to the requested tab ID.
   */
  function getRevalidationReason(tab, expectedTabId, thresholdMinutes, nowMilliseconds) {
    if (
      !Number.isInteger(expectedTabId) ||
      expectedTabId < 0 ||
      !tab ||
      tab.id !== expectedTabId
    ) {
      return INELIGIBLE.TAB_ID_MISMATCH;
    }

    return getIneligibilityReason(tab, thresholdMinutes, nowMilliseconds);
  }

  function normalizeThresholdMinutes(value) {
    const parsed = Number.parseInt(String(value), 10);
    return ALLOWED_THRESHOLDS.has(parsed) ? parsed : DEFAULT_THRESHOLD_MINUTES;
  }

  const testableApi = Object.freeze({
    ALLOWED_THRESHOLDS,
    DEFAULT_THRESHOLD_MINUTES,
    INELIGIBLE,
    filterEligibleTabs,
    getIneligibilityReason,
    getRevalidationReason,
    normalizeThresholdMinutes
  });

  if (typeof module !== "undefined" && module.exports) {
    module.exports = testableApi;
  }

  if (typeof document === "undefined" || typeof chrome === "undefined") {
    return;
  }

  const guardCore = globalThis.ChromeRamWatchGuardCore;
  if (!guardCore) {
    throw new Error("Chrome RAM Watch Auto Guard core is unavailable.");
  }

  const AUTO_PERMISSIONS = Object.freeze(["alarms", "system.memory"]);

  const elements = {
    autoStateBadge: document.querySelector("#auto-state-badge"),
    autoMemoryThreshold: document.querySelector("#auto-memory-threshold"),
    autoAgeThreshold: document.querySelector("#auto-age-threshold"),
    autoRiskLabel: document.querySelector("#auto-risk-label"),
    autoRiskConsent: document.querySelector("#auto-risk-consent"),
    autoToggleButton: document.querySelector("#auto-toggle-button"),
    autoCheckButton: document.querySelector("#auto-check-button"),
    autoStatus: document.querySelector("#auto-status"),
    autoAvailableMemory: document.querySelector("#auto-available-memory"),
    autoPressureStreak: document.querySelector("#auto-pressure-streak"),
    autoLastAction: document.querySelector("#auto-last-action"),
    autoLogContainer: document.querySelector("#auto-log-container"),
    autoLogList: document.querySelector("#auto-log-list"),
    scanPanel: document.querySelector("#scan-panel"),
    reviewPanel: document.querySelector("#review-panel"),
    resultsPanel: document.querySelector("#results-panel"),
    scanHeading: document.querySelector("#scan-heading"),
    reviewHeading: document.querySelector("#review-heading"),
    resultsHeading: document.querySelector("#results-heading"),
    threshold: document.querySelector("#age-threshold"),
    detailsPermissionButton: document.querySelector("#details-permission-button"),
    detailsPermissionNote: document.querySelector("#details-permission-note"),
    refreshButton: document.querySelector("#refresh-button"),
    scanStatus: document.querySelector("#scan-status"),
    selectAll: document.querySelector("#select-all"),
    selectionCount: document.querySelector("#selection-count"),
    emptyMessage: document.querySelector("#empty-message"),
    tabList: document.querySelector("#tab-list"),
    reviewButton: document.querySelector("#review-button"),
    reviewSummary: document.querySelector("#review-summary"),
    reviewList: document.querySelector("#review-list"),
    reviewSkippedContainer: document.querySelector("#review-skipped-container"),
    reviewSkippedList: document.querySelector("#review-skipped-list"),
    reviewStatus: document.querySelector("#review-status"),
    backButton: document.querySelector("#back-button"),
    discardButton: document.querySelector("#discard-button"),
    resultsSummary: document.querySelector("#results-summary"),
    resultsList: document.querySelector("#results-list"),
    scanAgainButton: document.querySelector("#scan-again-button")
  };

  const state = {
    autoBusy: false,
    autoEnabled: false,
    busy: false,
    eligibleTabs: [],
    selectedTabIds: new Set(),
    hasTabDetails: false,
    reviewTabs: [],
    reviewThresholdMinutes: DEFAULT_THRESHOLD_MINUTES
  };

  function setStatus(element, message, kind) {
    element.textContent = message;
    if (kind) {
      element.dataset.kind = kind;
    } else {
      delete element.dataset.kind;
    }
  }

  function errorMessage(error) {
    if (error instanceof Error && error.message) {
      return error.message;
    }

    if (error && typeof error.message === "string") {
      return error.message;
    }

    return String(error || "Unknown Chrome API error");
  }

  function plural(count, singular, pluralForm) {
    return count === 1 ? singular : pluralForm;
  }

  function formatThreshold(thresholdMinutes) {
    if (thresholdMinutes < 60) {
      return `${thresholdMinutes} ${plural(thresholdMinutes, "minute", "minutes")}`;
    }

    if (thresholdMinutes < 1440) {
      const hours = thresholdMinutes / 60;
      return `${hours} ${plural(hours, "hour", "hours")}`;
    }

    const days = thresholdMinutes / 1440;
    return `${days} ${plural(days, "day", "days")}`;
  }

  function formatAge(lastAccessed, nowMilliseconds) {
    const now = nowMilliseconds === undefined ? Date.now() : nowMilliseconds;
    const totalMinutes = Math.max(0, Math.floor((now - lastAccessed) / MINUTE_MS));

    if (totalMinutes < 60) {
      return `${totalMinutes} ${plural(totalMinutes, "minute", "minutes")} ago`;
    }

    if (totalMinutes < 1440) {
      const hours = Math.floor(totalMinutes / 60);
      const minutes = totalMinutes % 60;
      return minutes === 0
        ? `${hours} ${plural(hours, "hour", "hours")} ago`
        : `${hours}h ${minutes}m ago`;
    }

    const days = Math.floor(totalMinutes / 1440);
    const hours = Math.floor((totalMinutes % 1440) / 60);
    return hours === 0
      ? `${days} ${plural(days, "day", "days")} ago`
      : `${days}d ${hours}h ago`;
  }

  function describeReason(reason, thresholdMinutes) {
    const descriptions = {
      [INELIGIBLE.INVALID_TAB_ID]: "the tab ID is unavailable",
      [INELIGIBLE.TAB_ID_MISMATCH]: "Chrome did not return the exact requested tab ID",
      [INELIGIBLE.ACTIVE]: "the tab became active",
      [INELIGIBLE.ACTIVE_UNKNOWN]: "the active state could not be verified",
      [INELIGIBLE.PINNED]: "the tab became pinned",
      [INELIGIBLE.PINNED_UNKNOWN]: "the pinned state could not be verified",
      [INELIGIBLE.AUDIBLE]: "the tab started producing audio",
      [INELIGIBLE.AUDIBLE_UNKNOWN]: "the audio state could not be verified",
      [INELIGIBLE.ALREADY_DISCARDED]: "the tab was already discarded",
      [INELIGIBLE.DISCARDED_UNKNOWN]: "the discarded state could not be verified",
      [INELIGIBLE.NOT_AUTO_DISCARDABLE]: "Chrome marks the tab as not auto-discardable",
      [INELIGIBLE.AUTO_DISCARDABLE_UNKNOWN]: "the auto-discardable state could not be verified",
      [INELIGIBLE.LAST_ACCESSED_INVALID]: "the last-used time could not be verified",
      [INELIGIBLE.THRESHOLD_INVALID]: "the age threshold is invalid",
      [INELIGIBLE.TOO_RECENT]: `the tab was used within the last ${formatThreshold(thresholdMinutes)}`
    };

    return descriptions[reason] || "the tab no longer meets every safety condition";
  }

  function getThresholdMinutes() {
    const threshold = normalizeThresholdMinutes(elements.threshold.value);
    elements.threshold.value = String(threshold);
    return threshold;
  }

  async function hasTabDetailsPermission() {
    return chrome.permissions.contains({ permissions: ["tabs"] });
  }

  function snapshotTab(tab) {
    return {
      id: tab.id,
      index: tab.index,
      windowId: tab.windowId,
      incognito: tab.incognito === true,
      lastAccessed: tab.lastAccessed,
      title: state.hasTabDetails && typeof tab.title === "string" ? tab.title : null,
      url: state.hasTabDetails && typeof tab.url === "string" ? tab.url : null
    };
  }

  function tabTitle(tab) {
    if (state.hasTabDetails) {
      return typeof tab.title === "string" && tab.title.length > 0 ? tab.title : "(no title)";
    }

    return `Tab ${tab.id}`;
  }

  function appendTabCopy(container, tab) {
    const copy = document.createElement("span");
    copy.className = "tab-copy";

    const title = document.createElement("span");
    title.className = "tab-title";
    title.textContent = tabTitle(tab);

    const id = document.createElement("span");
    id.className = "tab-id";
    id.textContent = `Tab ID ${tab.id}`;

    copy.append(title, id);

    if (tab.incognito === true) {
      const incognito = document.createElement("span");
      incognito.className = "tab-badge";
      incognito.textContent = "Incognito";
      copy.append(incognito);
    }

    if (state.hasTabDetails) {
      const url = document.createElement("span");
      url.className = "tab-url";
      url.textContent = typeof tab.url === "string" && tab.url.length > 0 ? tab.url : "(no committed URL)";
      copy.append(url);
    }

    if (Number.isFinite(tab.lastAccessed)) {
      const meta = document.createElement("span");
      meta.className = "tab-meta";
      const position = Number.isInteger(tab.index) ? tab.index + 1 : "unknown";
      meta.textContent = `Window ${tab.windowId}, position ${position}, last used ${formatAge(tab.lastAccessed)}`;
      copy.append(meta);
    }

    container.append(copy);
  }

  function updatePermissionDisplay() {
    if (state.hasTabDetails) {
      elements.detailsPermissionButton.textContent = "Hide titles and URLs";
      elements.detailsPermissionNote.textContent =
        "Optional tabs permission is on. Titles and committed URLs are shown only in this popup and are not stored.";
    } else {
      elements.detailsPermissionButton.textContent = "Show titles and URLs";
      elements.detailsPermissionNote.textContent =
        "Optional: grant the tabs permission only if you want titles and URLs shown. Tab IDs work without it.";
    }
  }

  function formatTimestamp(timestamp) {
    if (!Number.isInteger(timestamp) || timestamp <= 0) {
      return "None";
    }

    return new Date(timestamp).toLocaleString();
  }

  function describeAutoReason(reason) {
    const descriptions = {
      "user-consent": "Auto Guard was enabled.",
      "pressure-normal": "Available memory is above the configured trigger.",
      "pressure-sample-recorded": "Low memory was recorded, but the sustained-pressure gate is not complete yet.",
      "pressure-confirmed": "Sustained low memory was confirmed.",
      "cooldown-active": "The global cooldown is still active.",
      "memory-invalid": "Physical-memory data was unavailable, so no tab was touched.",
      "tab-query-invalid": "Chrome did not return a valid tab list, so no tab was touched.",
      "no-eligible-tabs": "No tab met every automatic safety rule.",
      "pressure-recovered": "Available memory recovered before the next tab.",
      "discard-call-cap-reached": "The two-attempt cycle limit was reached.",
      "candidates-exhausted": "Every bounded candidate was handled.",
      "confirmed-discarded": "Chrome confirmed the tab was discarded.",
      "eligible-under-pressure": "Intent recorded before exact final revalidation.",
      "config-changed": "Settings changed during the cycle, so the remaining work stopped.",
      "permissions-changed": "Permissions changed during the cycle, so the remaining work stopped.",
      "consent-cancelled": "Consent changed during the cycle, so no later discard was allowed.",
      "discard-response-unconfirmed": "Chrome did not confirm the exact discarded tab, so the cycle stopped.",
      "confirmation-failed": "The final discarded state could not be confirmed, so the cycle stopped.",
      "tab-get-failed": "The exact tab could not be re-fetched, so the cycle stopped."
    };

    if (descriptions[reason]) {
      return descriptions[reason];
    }

    if (Object.values(INELIGIBLE).includes(reason) || Object.values(guardCore.INELIGIBLE).includes(reason)) {
      return `The tab was skipped because its protected state changed (${reason}).`;
    }

    return reason ? `Auto Guard stopped safely (${reason}).` : "No automatic action has run yet.";
  }

  function renderAutoLog(log) {
    const safeLog = Array.isArray(log) ? log.slice(-6).reverse() : [];
    const fragment = document.createDocumentFragment();
    let itemCount = 0;

    for (const entry of safeLog) {
      if (!entry || !Number.isInteger(entry.tabId)) {
        continue;
      }

      const item = document.createElement("li");
      item.className = "result-item";
      item.dataset.result = entry.status === "discarded"
        ? "discarded"
        : entry.status === "skipped"
          ? "skipped"
          : entry.status === "failed"
            ? "failed"
            : "intent";

      const title = document.createElement("strong");
      title.textContent = `Tab ID ${entry.tabId}`;

      const detail = document.createElement("span");
      detail.className = "result-item__status";
      const memoryText = Number.isFinite(entry.availablePercent)
        ? ` Available RAM: ${entry.availablePercent.toFixed(1)}%.`
        : "";
      detail.textContent = `${formatTimestamp(entry.timestamp)}. ${describeAutoReason(entry.reason)}${memoryText}`;

      item.append(title, detail);
      fragment.append(item);
      itemCount += 1;
    }

    elements.autoLogList.replaceChildren(fragment);
    elements.autoLogContainer.hidden = itemCount === 0;
  }

  function renderAutoStatus(autoStatus, responseOk) {
    const status = autoStatus && typeof autoStatus === "object" ? autoStatus : null;
    const enabled = Boolean(status && status.enabled === true);
    const config = status && status.config && typeof status.config === "object"
      ? status.config
      : null;
    const autoState = status && status.state && typeof status.state === "object"
      ? status.state
      : {};

    state.autoEnabled = enabled;
    elements.autoStateBadge.textContent = enabled ? "On" : "Off";
    elements.autoStateBadge.dataset.state = enabled ? "on" : "off";
    elements.autoToggleButton.textContent = enabled ? "Disable Auto Guard" : "Enable Auto Guard";
    elements.autoToggleButton.classList.toggle("button--danger", enabled);
    elements.autoToggleButton.classList.toggle("button--primary", !enabled);
    elements.autoRiskLabel.hidden = enabled;

    if (config && guardCore.ALLOWED_TRIGGER_PERCENTAGES.has(config.triggerPercent)) {
      elements.autoMemoryThreshold.value = String(config.triggerPercent);
    }
    if (config && guardCore.ALLOWED_INACTIVITY_MINUTES.has(config.inactivityMinutes)) {
      elements.autoAgeThreshold.value = String(config.inactivityMinutes);
    }

    if (!enabled) {
      elements.autoRiskConsent.checked = false;
    }

    elements.autoAvailableMemory.textContent = Number.isFinite(autoState.lastAvailablePercent)
      ? `${autoState.lastAvailablePercent.toFixed(1)}%`
      : "Not checked";
    const requiredSamples = Number.isInteger(autoState.requiredSamples)
      ? autoState.requiredSamples
      : guardCore.REQUIRED_PRESSURE_SAMPLES;
    const pressureStreak = Number.isInteger(autoState.pressureStreak)
      ? autoState.pressureStreak
      : 0;
    elements.autoPressureStreak.textContent = `${pressureStreak} of ${requiredSamples}`;
    elements.autoLastAction.textContent = formatTimestamp(autoState.lastActionAt);
    renderAutoLog(status && status.log);

    if (!responseOk) {
      setStatus(
        elements.autoStatus,
        "Auto Guard is off because its permission, configuration, alarm, or stored state could not be verified.",
        "warning"
      );
    } else if (!enabled) {
      setStatus(elements.autoStatus, "Auto Guard is off. No background cleanup is running.", null);
    } else if (autoState.lastResult) {
      setStatus(
        elements.autoStatus,
        `Auto Guard is on. ${describeAutoReason(autoState.lastResult.reason)}`,
        autoState.lastResult.status === "failed" ? "warning" : "success"
      );
    } else {
      setStatus(elements.autoStatus, "Auto Guard is on and waiting for its next memory check.", "success");
    }

    updateControls();
  }

  async function hasAutoPermissions() {
    try {
      return await chrome.permissions.contains({ permissions: AUTO_PERMISSIONS.slice() });
    } catch (_error) {
      return false;
    }
  }

  async function refreshAutoStatus() {
    state.autoBusy = true;
    updateControls();

    try {
      if (!await hasAutoPermissions()) {
        renderAutoStatus(null, true);
        return;
      }

      const response = await chrome.runtime.sendMessage({ type: "auto-guard:get-status" });
      renderAutoStatus(response && response.status, Boolean(response && response.ok));
    } catch (error) {
      renderAutoStatus(null, false);
      setStatus(elements.autoStatus, `Could not read Auto Guard status: ${errorMessage(error)}`, "error");
    } finally {
      state.autoBusy = false;
      updateControls();
    }
  }

  async function enableAutoGuard() {
    if (state.autoBusy || state.autoEnabled || !elements.autoRiskConsent.checked) {
      return;
    }

    const triggerPercent = Number.parseInt(elements.autoMemoryThreshold.value, 10);
    const inactivityMinutes = Number.parseInt(elements.autoAgeThreshold.value, 10);
    const config = guardCore.createConfig(triggerPercent, inactivityMinutes);
    if (!config) {
      setStatus(elements.autoStatus, "Auto Guard settings are invalid. Nothing was enabled.", "error");
      return;
    }

    state.autoBusy = true;
    updateControls();
    setStatus(elements.autoStatus, "Requesting the two optional Auto Guard capabilities...", null);

    try {
      const granted = await chrome.permissions.request({ permissions: AUTO_PERMISSIONS.slice() });
      if (!granted) {
        renderAutoStatus(null, true);
        setStatus(elements.autoStatus, "Auto Guard permission was not granted. It remains off.", "warning");
        return;
      }

      const response = await chrome.runtime.sendMessage({
        type: "auto-guard:enable",
        payload: {
          consentVersion: guardCore.CONSENT_VERSION,
          inactivityMinutes: config.inactivityMinutes,
          triggerPercent: config.triggerPercent
        }
      });
      if (!response || !response.ok || !response.status || response.status.enabled !== true) {
        await chrome.permissions.remove({ permissions: AUTO_PERMISSIONS.slice() });
        renderAutoStatus(null, false);
        return;
      }

      renderAutoStatus(response.status, true);
      setStatus(elements.autoStatus, "Auto Guard is on. The first memory check is scheduled in two minutes.", "success");
    } catch (error) {
      try {
        await chrome.permissions.remove({ permissions: AUTO_PERMISSIONS.slice() });
      } catch (_removeError) {
        // The next status check still fails closed if cleanup is incomplete.
      }
      renderAutoStatus(null, false);
      setStatus(elements.autoStatus, `Could not enable Auto Guard: ${errorMessage(error)}`, "error");
    } finally {
      state.autoBusy = false;
      updateControls();
    }
  }

  async function disableAutoGuard() {
    if (state.autoBusy || !state.autoEnabled) {
      return;
    }

    state.autoBusy = true;
    updateControls();
    setStatus(elements.autoStatus, "Stopping Auto Guard and clearing its local state...", null);

    try {
      const response = await chrome.runtime.sendMessage({ type: "auto-guard:disable" });
      const removed = await chrome.permissions.remove({ permissions: AUTO_PERMISSIONS.slice() });
      renderAutoStatus(response && response.status, Boolean(response && response.ok));
      setStatus(
        elements.autoStatus,
        removed
          ? "Auto Guard is off. Its alarm, automatic state, journal, and two optional permissions were removed."
          : "Auto Guard is off, but Chrome did not confirm removal of every optional capability.",
        removed ? null : "warning"
      );
    } catch (error) {
      setStatus(elements.autoStatus, `Could not fully disable Auto Guard: ${errorMessage(error)}`, "error");
    } finally {
      state.autoBusy = false;
      updateControls();
    }
  }

  async function checkAutoGuardNow() {
    if (state.autoBusy || !state.autoEnabled) {
      return;
    }

    state.autoBusy = true;
    updateControls();
    setStatus(elements.autoStatus, "Checking physical memory and protected tab state...", null);

    try {
      const response = await chrome.runtime.sendMessage({ type: "auto-guard:check-now" });
      renderAutoStatus(response && response.status, Boolean(response && response.ok));
    } catch (error) {
      setStatus(elements.autoStatus, `Auto Guard check failed closed: ${errorMessage(error)}`, "error");
    } finally {
      state.autoBusy = false;
      updateControls();
    }
  }

  function updateControls() {
    const selectedCount = state.selectedTabIds.size;
    const allSelected = state.eligibleTabs.length > 0 && selectedCount === state.eligibleTabs.length;

    elements.autoMemoryThreshold.disabled = state.autoBusy || state.autoEnabled;
    elements.autoAgeThreshold.disabled = state.autoBusy || state.autoEnabled;
    elements.autoRiskConsent.disabled = state.autoBusy || state.autoEnabled;
    elements.autoToggleButton.disabled = state.autoBusy || (
      !state.autoEnabled && !elements.autoRiskConsent.checked
    );
    elements.autoCheckButton.disabled = state.autoBusy || !state.autoEnabled;

    elements.threshold.disabled = state.busy;
    elements.detailsPermissionButton.disabled = state.busy;
    elements.refreshButton.disabled = state.busy;
    elements.selectAll.disabled = state.busy || state.eligibleTabs.length === 0;
    elements.selectAll.checked = allSelected;
    elements.selectAll.indeterminate = selectedCount > 0 && !allSelected;
    elements.reviewButton.disabled = state.busy || selectedCount === 0;
    elements.reviewButton.textContent = selectedCount === 0
      ? "Review selected tabs"
      : `Review ${selectedCount} selected ${plural(selectedCount, "tab", "tabs")}`;
    elements.backButton.disabled = state.busy;
    elements.discardButton.disabled = state.busy || state.reviewTabs.length === 0;
    elements.scanAgainButton.disabled = state.busy;
    elements.selectionCount.textContent = `${selectedCount} selected`;

    for (const checkbox of elements.tabList.querySelectorAll('input[type="checkbox"]')) {
      checkbox.disabled = state.busy;
    }
  }

  function showPanel(name) {
    elements.scanPanel.hidden = name !== "scan";
    elements.reviewPanel.hidden = name !== "review";
    elements.resultsPanel.hidden = name !== "results";
  }

  function focusPanelHeading(name) {
    const heading = {
      scan: elements.scanHeading,
      review: elements.reviewHeading,
      results: elements.resultsHeading
    }[name];

    if (heading) {
      heading.focus();
    }
  }

  function renderEligibleTabs() {
    const fragment = document.createDocumentFragment();

    for (const tab of state.eligibleTabs) {
      const item = document.createElement("li");
      item.className = "tab-item";

      const label = document.createElement("label");
      label.className = "tab-choice";

      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.dataset.tabId = String(tab.id);
      checkbox.checked = state.selectedTabIds.has(tab.id);

      label.append(checkbox);
      appendTabCopy(label, tab);
      item.append(label);
      fragment.append(item);
    }

    elements.tabList.replaceChildren(fragment);
    elements.emptyMessage.hidden = state.eligibleTabs.length !== 0;
    updateControls();
  }

  async function refreshEligibleTabs(options) {
    const preserveSelection = Boolean(options && options.preserveSelection);
    const previousSelection = preserveSelection ? new Set(state.selectedTabIds) : new Set();

    state.busy = true;
    updateControls();
    setStatus(elements.scanStatus, "Checking current tab state...", null);

    try {
      state.hasTabDetails = await hasTabDetailsPermission();
      updatePermissionDisplay();
      renderEligibleTabs();

      const thresholdMinutes = getThresholdMinutes();
      const candidateTabs = await chrome.tabs.query({
        currentWindow: true,
        active: false,
        pinned: false,
        audible: false,
        discarded: false,
        autoDiscardable: true
      });

      state.eligibleTabs = filterEligibleTabs(candidateTabs, thresholdMinutes, Date.now());
      const eligibleIds = new Set(state.eligibleTabs.map((tab) => tab.id));
      state.selectedTabIds = new Set(
        [...previousSelection].filter((tabId) => eligibleIds.has(tabId))
      );

      renderEligibleTabs();
      const count = state.eligibleTabs.length;
      setStatus(
        elements.scanStatus,
        `${count} eligible ${plural(count, "tab", "tabs")} in this Chrome window, inactive for at least ${formatThreshold(thresholdMinutes)}.`,
        count > 0 ? "success" : null
      );
    } catch (error) {
      state.eligibleTabs = [];
      state.selectedTabIds.clear();
      renderEligibleTabs();
      setStatus(elements.scanStatus, `Could not inspect tabs: ${errorMessage(error)}`, "error");
    } finally {
      state.busy = false;
      updateControls();
    }
  }

  async function toggleDetailsPermission() {
    if (state.busy) {
      return;
    }

    state.busy = true;
    updateControls();

    try {
      if (state.hasTabDetails) {
        const removed = await chrome.permissions.remove({ permissions: ["tabs"] });
        state.hasTabDetails = removed ? false : await hasTabDetailsPermission();
        setStatus(
          elements.scanStatus,
          removed ? "Titles and URLs are hidden." : "Chrome did not remove the optional tabs permission.",
          removed ? null : "warning"
        );
      } else {
        // This request is called directly from the button click user gesture.
        const granted = await chrome.permissions.request({ permissions: ["tabs"] });
        state.hasTabDetails = granted;
        setStatus(
          elements.scanStatus,
          granted ? "Titles and URLs are now visible." : "Permission was not granted. Tab IDs remain available.",
          granted ? "success" : "warning"
        );
      }

      updatePermissionDisplay();
    } catch (error) {
      setStatus(elements.scanStatus, `Could not change permission: ${errorMessage(error)}`, "error");
    } finally {
      state.busy = false;
      updateControls();
    }

    await refreshEligibleTabs({ preserveSelection: true });
  }

  function renderReviewTabs(reviewedTabs, skippedTabs, thresholdMinutes) {
    const reviewFragment = document.createDocumentFragment();

    for (const tab of reviewedTabs) {
      const item = document.createElement("li");
      item.className = "tab-item";
      appendTabCopy(item, tab);
      reviewFragment.append(item);
    }

    elements.reviewList.replaceChildren(reviewFragment);
    elements.reviewSummary.textContent =
      `${reviewedTabs.length} ${plural(reviewedTabs.length, "tab is", "tabs are")} ready for a separate final click. The threshold is ${formatThreshold(thresholdMinutes)}.`;

    const skippedFragment = document.createDocumentFragment();
    for (const skipped of skippedTabs) {
      const item = document.createElement("li");
      item.className = "result-item";

      const title = document.createElement("strong");
      title.textContent = `Tab ID ${skipped.id}`;

      const detail = document.createElement("span");
      detail.className = "result-item__status";
      detail.textContent = skipped.message;

      item.append(title, detail);
      skippedFragment.append(item);
    }

    elements.reviewSkippedList.replaceChildren(skippedFragment);
    elements.reviewSkippedContainer.hidden = skippedTabs.length === 0;
    setStatus(
      elements.reviewStatus,
      skippedTabs.length > 0
        ? `${skippedTabs.length} selected ${plural(skippedTabs.length, "tab was", "tabs were")} left out after the review recheck.`
        : "Every listed tab passed the review recheck.",
      skippedTabs.length > 0 ? "warning" : "success"
    );
  }

  async function reviewSelection() {
    if (state.busy || state.selectedTabIds.size === 0) {
      return;
    }

    state.busy = true;
    updateControls();
    setStatus(elements.scanStatus, "Rechecking selected tabs for review...", null);

    const thresholdMinutes = getThresholdMinutes();
    const orderedIds = state.eligibleTabs
      .map((tab) => tab.id)
      .filter((tabId) => state.selectedTabIds.has(tabId));
    const reviewedTabs = [];
    const skippedTabs = [];

    try {
      state.hasTabDetails = await hasTabDetailsPermission();
      updatePermissionDisplay();

      for (const tabId of orderedIds) {
        try {
          const tab = await chrome.tabs.get(tabId);
          const reason = getRevalidationReason(tab, tabId, thresholdMinutes, Date.now());

          if (reason === null) {
            reviewedTabs.push(snapshotTab(tab));
          } else {
            skippedTabs.push({
              id: tabId,
              message: `Left out because ${describeReason(reason, thresholdMinutes)}.`
            });
          }
        } catch (error) {
          skippedTabs.push({
            id: tabId,
            message: `Left out because the tab could not be re-fetched: ${errorMessage(error)}.`
          });
        }
      }

      if (reviewedTabs.length === 0) {
        state.selectedTabIds.clear();
        renderEligibleTabs();
        setStatus(
          elements.scanStatus,
          "No selected tabs still meet every safety condition. Refresh before choosing again.",
          "warning"
        );
        return;
      }

      state.reviewTabs = reviewedTabs;
      state.reviewThresholdMinutes = thresholdMinutes;
      showPanel("review");
      renderReviewTabs(reviewedTabs, skippedTabs, thresholdMinutes);
      focusPanelHeading("review");
    } catch (error) {
      setStatus(elements.scanStatus, `Could not prepare review: ${errorMessage(error)}`, "error");
    } finally {
      state.busy = false;
      updateControls();
    }
  }

  function createResultItem(result) {
    const item = document.createElement("li");
    item.className = "result-item";
    item.dataset.result = result.status;

    const title = document.createElement("strong");
    title.textContent = result.title;

    const id = document.createElement("span");
    id.className = "tab-id";
    id.textContent = `Tab ID ${result.id}`;

    const incognito = document.createElement("span");
    incognito.className = "tab-badge";
    incognito.textContent = "Incognito";

    const detail = document.createElement("span");
    detail.className = "result-item__status";
    detail.textContent = result.message;

    item.append(title, id);
    if (result.incognito === true) {
      item.append(incognito);
    }
    item.append(detail);
    return item;
  }

  function renderResults(results) {
    const fragment = document.createDocumentFragment();
    for (const result of results) {
      fragment.append(createResultItem(result));
    }
    elements.resultsList.replaceChildren(fragment);

    const discardedCount = results.filter((result) => result.status === "discarded").length;
    const skippedCount = results.filter((result) => result.status === "skipped").length;
    const failedCount = results.filter((result) => result.status === "failed").length;

    elements.resultsSummary.textContent =
      `${discardedCount} confirmed discarded. ${skippedCount} skipped after revalidation. ${failedCount} failed or unconfirmed.`;
  }

  async function discardReviewedTabs() {
    if (state.busy || state.reviewTabs.length === 0) {
      return;
    }

    state.busy = true;
    updateControls();
    setStatus(elements.reviewStatus, "Revalidating each tab immediately before discard...", null);

    const reviewedTabs = state.reviewTabs.slice();
    const thresholdMinutes = state.reviewThresholdMinutes;
    const results = [];

    for (const reviewedTab of reviewedTabs) {
      const fallbackTitle = reviewedTab.title || `Tab ${reviewedTab.id}`;
      const resultIdentity = {
        id: reviewedTab.id,
        title: fallbackTitle,
        incognito: reviewedTab.incognito === true
      };
      let currentTab;

      try {
        currentTab = await chrome.tabs.get(reviewedTab.id);
      } catch (error) {
        results.push({
          ...resultIdentity,
          status: "skipped",
          message: `Skipped because the tab could not be re-fetched: ${errorMessage(error)}.`
        });
        continue;
      }

      // Keep the final pure state check directly adjacent to the discard call.
      // Chrome has no atomic conditional-discard API, so unknown state is a skip.
      const reason = getRevalidationReason(
        currentTab,
        reviewedTab.id,
        thresholdMinutes,
        Date.now()
      );
      if (reason !== null) {
        results.push({
          ...resultIdentity,
          status: "skipped",
          message: `Skipped because ${describeReason(reason, thresholdMinutes)}.`
        });
        continue;
      }

      let discardResponse;
      try {
        discardResponse = await chrome.tabs.discard(reviewedTab.id);
      } catch (error) {
        results.push({
          ...resultIdentity,
          status: "failed",
          message: `Chrome rejected the discard request: ${errorMessage(error)}.`
        });
        continue;
      }

      if (
        !discardResponse ||
        discardResponse.id !== reviewedTab.id ||
        discardResponse.discarded !== true
      ) {
        results.push({
          ...resultIdentity,
          status: "failed",
          message: "Chrome did not return the exact tab with discarded status. The response was rejected."
        });
        continue;
      }

      try {
        const confirmedTab = await chrome.tabs.get(reviewedTab.id);
        if (confirmedTab.discarded === true) {
          results.push({
            ...resultIdentity,
            status: "discarded",
            message: "Confirmed discarded. The tab remains open and will reload when activated."
          });
        } else {
          results.push({
            ...resultIdentity,
            status: "failed",
            message: "Discard was not confirmed because Chrome did not report discarded status."
          });
        }
      } catch (error) {
        results.push({
          ...resultIdentity,
          status: "failed",
          message: `Discard status could not be confirmed: ${errorMessage(error)}.`
        });
      }
    }

    state.reviewTabs = [];
    state.selectedTabIds.clear();
    state.busy = false;
    showPanel("results");
    renderResults(results);
    updateControls();
    focusPanelHeading("results");
  }

  elements.autoRiskConsent.addEventListener("change", () => {
    updateControls();
  });

  elements.autoToggleButton.addEventListener("click", () => {
    if (state.autoEnabled) {
      void disableAutoGuard();
    } else {
      void enableAutoGuard();
    }
  });

  elements.autoCheckButton.addEventListener("click", () => {
    void checkAutoGuardNow();
  });

  elements.tabList.addEventListener("change", (event) => {
    const checkbox = event.target.closest('input[type="checkbox"][data-tab-id]');
    if (!checkbox) {
      return;
    }

    const tabId = Number.parseInt(checkbox.dataset.tabId, 10);
    if (!Number.isInteger(tabId)) {
      return;
    }

    if (checkbox.checked) {
      state.selectedTabIds.add(tabId);
    } else {
      state.selectedTabIds.delete(tabId);
    }
    updateControls();
  });

  elements.selectAll.addEventListener("change", () => {
    state.selectedTabIds = elements.selectAll.checked
      ? new Set(state.eligibleTabs.map((tab) => tab.id))
      : new Set();
    renderEligibleTabs();
  });

  elements.threshold.addEventListener("change", () => {
    void refreshEligibleTabs({ preserveSelection: false });
  });

  elements.refreshButton.addEventListener("click", () => {
    void refreshEligibleTabs({ preserveSelection: true });
  });

  elements.detailsPermissionButton.addEventListener("click", () => {
    void toggleDetailsPermission();
  });

  elements.reviewButton.addEventListener("click", () => {
    void reviewSelection();
  });

  elements.backButton.addEventListener("click", () => {
    state.reviewTabs = [];
    setStatus(elements.reviewStatus, "", null);
    showPanel("scan");
    updateControls();
    focusPanelHeading("scan");
  });

  elements.discardButton.addEventListener("click", () => {
    void discardReviewedTabs();
  });

  elements.scanAgainButton.addEventListener("click", () => {
    showPanel("scan");
    focusPanelHeading("scan");
    void refreshEligibleTabs({ preserveSelection: false });
  });

  showPanel("scan");
  focusPanelHeading("scan");
  void refreshAutoStatus();
  void refreshEligibleTabs({ preserveSelection: false });
}());
