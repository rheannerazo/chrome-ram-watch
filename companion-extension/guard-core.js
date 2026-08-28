(function (root, factory) {
  "use strict";

  const api = factory();

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  } else {
    root.ChromeRamWatchGuardCore = api;
  }
}(typeof globalThis !== "undefined" ? globalThis : self, function () {
  "use strict";

  const MINUTE_MS = 60 * 1000;
  const CONFIG_REVISION = 1;
  const STATE_REVISION = 1;
  const CONSENT_VERSION = 1;
  const DEFAULT_TRIGGER_PERCENT = 15;
  const DEFAULT_INACTIVITY_MINUTES = 240;
  const REQUIRED_PRESSURE_SAMPLES = 3;
  const MAX_PRESSURE_SAMPLE_GAP_MS = 5 * MINUTE_MS;
  const COOLDOWN_MS = 15 * MINUTE_MS;
  const MAX_DISCARD_CALLS_PER_CYCLE = 2;
  const MAX_AUDIT_ENTRIES = 20;
  const ALLOWED_TRIGGER_PERCENTAGES = new Set([10, 15, 20]);
  const ALLOWED_INACTIVITY_MINUTES = new Set([120, 240, 480, 1440]);

  const CONFIG_KEYS = Object.freeze([
    "configRevision",
    "consentVersion",
    "inactivityMinutes",
    "triggerPercent"
  ]);

  const STATE_KEYS = Object.freeze([
    "cooldownUntil",
    "lastActionAt",
    "lastAvailablePercent",
    "lastCheckAt",
    "lastLowSampleAt",
    "lastResult",
    "pressureStreak",
    "stateRevision"
  ]);

  const LAST_RESULT_KEYS = Object.freeze([
    "confirmedDiscards",
    "cycle",
    "discardCalls",
    "reason",
    "skippedCount",
    "status"
  ]);

  const AUDIT_KEYS = Object.freeze([
    "availablePercent",
    "configRevision",
    "cycle",
    "reason",
    "status",
    "tabId",
    "timestamp"
  ]);

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
    INCOGNITO: "incognito",
    INCOGNITO_UNKNOWN: "incognito-unknown",
    HIGHLIGHTED: "highlighted",
    HIGHLIGHTED_UNKNOWN: "highlighted-unknown",
    NOT_COMPLETE: "not-complete",
    STATUS_UNKNOWN: "status-unknown",
    LAST_ACCESSED_INVALID: "last-accessed-invalid",
    INACTIVITY_THRESHOLD_INVALID: "inactivity-threshold-invalid",
    TOO_RECENT: "too-recent"
  });

  function isPlainObject(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }

    const prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  }

  function hasExactKeys(value, expectedKeys) {
    if (!isPlainObject(value)) {
      return false;
    }

    const actualKeys = Object.keys(value).sort();
    const sortedExpectedKeys = expectedKeys.slice().sort();
    return actualKeys.length === sortedExpectedKeys.length &&
      actualKeys.every((key, index) => key === sortedExpectedKeys[index]);
  }

  function isTimestampOrNull(value) {
    return value === null || (Number.isInteger(value) && value > 0);
  }

  function isPercentageOrNull(value) {
    return value === null || (Number.isFinite(value) && value >= 0 && value <= 100);
  }

  function createConfig(triggerPercent, inactivityMinutes) {
    const normalizedTrigger = triggerPercent === undefined
      ? DEFAULT_TRIGGER_PERCENT
      : triggerPercent;
    const normalizedInactivity = inactivityMinutes === undefined
      ? DEFAULT_INACTIVITY_MINUTES
      : inactivityMinutes;

    if (
      !ALLOWED_TRIGGER_PERCENTAGES.has(normalizedTrigger) ||
      !ALLOWED_INACTIVITY_MINUTES.has(normalizedInactivity)
    ) {
      return null;
    }

    return {
      configRevision: CONFIG_REVISION,
      consentVersion: CONSENT_VERSION,
      inactivityMinutes: normalizedInactivity,
      triggerPercent: normalizedTrigger
    };
  }

  function isValidConfig(config) {
    return hasExactKeys(config, CONFIG_KEYS) &&
      config.configRevision === CONFIG_REVISION &&
      config.consentVersion === CONSENT_VERSION &&
      ALLOWED_TRIGGER_PERCENTAGES.has(config.triggerPercent) &&
      ALLOWED_INACTIVITY_MINUTES.has(config.inactivityMinutes);
  }

  function configSignature(config) {
    if (!isValidConfig(config)) {
      return null;
    }

    return [
      config.configRevision,
      config.consentVersion,
      config.triggerPercent,
      config.inactivityMinutes
    ].join(":");
  }

  function createLastResult(cycle, status, reason, discardCalls, confirmedDiscards, skippedCount) {
    return {
      confirmedDiscards,
      cycle,
      discardCalls,
      reason,
      skippedCount,
      status
    };
  }

  function isValidLastResult(result) {
    return result === null || (
      hasExactKeys(result, LAST_RESULT_KEYS) &&
      Number.isInteger(result.cycle) && result.cycle >= 0 &&
      typeof result.status === "string" && result.status.length > 0 && result.status.length <= 64 &&
      typeof result.reason === "string" && result.reason.length > 0 && result.reason.length <= 96 &&
      Number.isInteger(result.discardCalls) && result.discardCalls >= 0 &&
      result.discardCalls <= MAX_DISCARD_CALLS_PER_CYCLE &&
      Number.isInteger(result.confirmedDiscards) && result.confirmedDiscards >= 0 &&
      result.confirmedDiscards <= MAX_DISCARD_CALLS_PER_CYCLE &&
      Number.isInteger(result.skippedCount) && result.skippedCount >= 0
    );
  }

  function createInitialState() {
    return {
      cooldownUntil: 0,
      lastActionAt: null,
      lastAvailablePercent: null,
      lastCheckAt: null,
      lastLowSampleAt: null,
      lastResult: null,
      pressureStreak: 0,
      stateRevision: STATE_REVISION
    };
  }

  function isValidState(state) {
    return hasExactKeys(state, STATE_KEYS) &&
      state.stateRevision === STATE_REVISION &&
      Number.isInteger(state.cooldownUntil) && state.cooldownUntil >= 0 &&
      isTimestampOrNull(state.lastActionAt) &&
      isPercentageOrNull(state.lastAvailablePercent) &&
      isTimestampOrNull(state.lastCheckAt) &&
      isTimestampOrNull(state.lastLowSampleAt) &&
      Number.isInteger(state.pressureStreak) &&
      state.pressureStreak >= 0 && state.pressureStreak <= REQUIRED_PRESSURE_SAMPLES &&
      isValidLastResult(state.lastResult);
  }

  function resetPressureContinuity(state) {
    const source = isValidState(state) ? state : createInitialState();
    return {
      ...source,
      lastLowSampleAt: null,
      pressureStreak: 0
    };
  }

  function nextPressureStreak(state, nowMilliseconds) {
    if (!isValidState(state) || !Number.isInteger(nowMilliseconds) || nowMilliseconds <= 0) {
      return 1;
    }

    const gap = state.lastLowSampleAt === null
      ? Number.POSITIVE_INFINITY
      : nowMilliseconds - state.lastLowSampleAt;
    const isContinuous = gap >= 0 && gap <= MAX_PRESSURE_SAMPLE_GAP_MS;
    return isContinuous
      ? Math.min(REQUIRED_PRESSURE_SAMPLES, state.pressureStreak + 1)
      : 1;
  }

  function getAvailablePercent(memoryInfo) {
    if (
      !isPlainObject(memoryInfo) ||
      !Number.isFinite(memoryInfo.capacity) || memoryInfo.capacity <= 0 ||
      !Number.isFinite(memoryInfo.availableCapacity) || memoryInfo.availableCapacity < 0 ||
      memoryInfo.availableCapacity > memoryInfo.capacity
    ) {
      return null;
    }

    return Math.round((memoryInfo.availableCapacity / memoryInfo.capacity) * 10000) / 100;
  }

  function isLowMemory(memoryInfo, triggerPercent) {
    if (!ALLOWED_TRIGGER_PERCENTAGES.has(triggerPercent)) {
      return false;
    }

    if (getAvailablePercent(memoryInfo) === null) {
      return false;
    }

    const rawAvailablePercent = (memoryInfo.availableCapacity / memoryInfo.capacity) * 100;
    return rawAvailablePercent <= triggerPercent;
  }

  function getAutoIneligibilityReason(tab, expectedTabId, inactivityMinutes, nowMilliseconds) {
    if (!Number.isInteger(expectedTabId) || expectedTabId < 0 || !tab || tab.id !== expectedTabId) {
      return INELIGIBLE.TAB_ID_MISMATCH;
    }

    if (!Number.isInteger(tab.id) || tab.id < 0) {
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

    if (tab.incognito !== false) {
      return tab.incognito === true ? INELIGIBLE.INCOGNITO : INELIGIBLE.INCOGNITO_UNKNOWN;
    }

    if (tab.highlighted !== false) {
      return tab.highlighted === true
        ? INELIGIBLE.HIGHLIGHTED
        : INELIGIBLE.HIGHLIGHTED_UNKNOWN;
    }

    if (tab.status !== "complete") {
      return typeof tab.status === "string" ? INELIGIBLE.NOT_COMPLETE : INELIGIBLE.STATUS_UNKNOWN;
    }

    if (!ALLOWED_INACTIVITY_MINUTES.has(inactivityMinutes)) {
      return INELIGIBLE.INACTIVITY_THRESHOLD_INVALID;
    }

    if (
      !Number.isFinite(nowMilliseconds) || nowMilliseconds <= 0 ||
      !Number.isFinite(tab.lastAccessed) || tab.lastAccessed <= 0 ||
      tab.lastAccessed > nowMilliseconds
    ) {
      return INELIGIBLE.LAST_ACCESSED_INVALID;
    }

    if (nowMilliseconds - tab.lastAccessed < inactivityMinutes * MINUTE_MS) {
      return INELIGIBLE.TOO_RECENT;
    }

    return null;
  }

  function filterAutoEligibleTabs(tabs, inactivityMinutes, nowMilliseconds) {
    if (!Array.isArray(tabs)) {
      return [];
    }

    return tabs
      .filter((tab) => (
        tab && Number.isInteger(tab.id) &&
        getAutoIneligibilityReason(tab, tab.id, inactivityMinutes, nowMilliseconds) === null
      ))
      .slice()
      .sort((left, right) => {
        const ageOrder = left.lastAccessed - right.lastAccessed;
        return ageOrder !== 0 ? ageOrder : left.id - right.id;
      });
  }

  function isValidAuditEntry(entry) {
    return hasExactKeys(entry, AUDIT_KEYS) &&
      Number.isInteger(entry.timestamp) && entry.timestamp > 0 &&
      Number.isInteger(entry.cycle) && entry.cycle > 0 &&
      entry.configRevision === CONFIG_REVISION &&
      Number.isInteger(entry.tabId) && entry.tabId >= 0 &&
      typeof entry.status === "string" && entry.status.length > 0 && entry.status.length <= 32 &&
      typeof entry.reason === "string" && entry.reason.length > 0 && entry.reason.length <= 96 &&
      Number.isFinite(entry.availablePercent) &&
      entry.availablePercent >= 0 && entry.availablePercent <= 100;
  }

  function sanitizeAuditLog(log) {
    if (!Array.isArray(log)) {
      return [];
    }

    return log.filter(isValidAuditEntry).slice(-MAX_AUDIT_ENTRIES).map((entry) => ({ ...entry }));
  }

  function appendAuditEntry(log, entry) {
    if (!isValidAuditEntry(entry)) {
      return null;
    }

    return [...sanitizeAuditLog(log), { ...entry }].slice(-MAX_AUDIT_ENTRIES);
  }

  const api = {
    ALLOWED_INACTIVITY_MINUTES,
    ALLOWED_TRIGGER_PERCENTAGES,
    CONFIG_REVISION,
    CONSENT_VERSION,
    COOLDOWN_MS,
    DEFAULT_INACTIVITY_MINUTES,
    DEFAULT_TRIGGER_PERCENT,
    INELIGIBLE,
    MAX_AUDIT_ENTRIES,
    MAX_DISCARD_CALLS_PER_CYCLE,
    MAX_PRESSURE_SAMPLE_GAP_MS,
    MINUTE_MS,
    REQUIRED_PRESSURE_SAMPLES,
    STATE_REVISION,
    appendAuditEntry,
    configSignature,
    createConfig,
    createInitialState,
    createLastResult,
    filterAutoEligibleTabs,
    getAutoIneligibilityReason,
    getAvailablePercent,
    hasExactKeys,
    isLowMemory,
    isPlainObject,
    isValidAuditEntry,
    isValidConfig,
    isValidLastResult,
    isValidState,
    nextPressureStreak,
    resetPressureContinuity,
    sanitizeAuditLog
  };

  return Object.freeze(api);
}));
