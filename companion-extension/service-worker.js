(function () {
  "use strict";

  const isCommonJs = typeof module !== "undefined" && Boolean(module.exports);
  let core;

  if (isCommonJs) {
    core = require("./guard-core.js");
  } else {
    importScripts("guard-core.js");
    core = globalThis.ChromeRamWatchGuardCore;
  }

  if (!core) {
    throw new Error("Chrome RAM Watch Auto Guard core is unavailable.");
  }

  const ALARM_NAME = "chrome-ram-watch-auto-guard";
  const ALARM_PERIOD_MINUTES = 2;
  const CONFIG_STORAGE_KEY = "autoGuardConfig";
  const STATE_STORAGE_KEY = "autoGuardState";
  const AUDIT_STORAGE_KEY = "autoGuardAuditLog";
  const AUTO_STORAGE_KEYS = Object.freeze([
    CONFIG_STORAGE_KEY,
    STATE_STORAGE_KEY,
    AUDIT_STORAGE_KEY
  ]);
  const AUTOMATIC_OPTIONAL_PERMISSIONS = Object.freeze(["alarms", "system.memory"]);
  const REQUIRED_PERMISSIONS = Object.freeze(["alarms", "storage", "system.memory"]);

  const NORMAL_SKIP_REASONS = new Set([
    core.INELIGIBLE.ACTIVE,
    core.INELIGIBLE.PINNED,
    core.INELIGIBLE.AUDIBLE,
    core.INELIGIBLE.ALREADY_DISCARDED,
    core.INELIGIBLE.NOT_AUTO_DISCARDABLE,
    core.INELIGIBLE.INCOGNITO,
    core.INELIGIBLE.HIGHLIGHTED,
    core.INELIGIBLE.NOT_COMPLETE,
    core.INELIGIBLE.TOO_RECENT
  ]);

  let activeCyclePromise = null;
  let alarmListenerRegistered = false;
  let permissionRemovalListenerRegistered = false;
  let consentEpoch = 0;
  let activeConsentTransition = null;
  let consentTransitionTail = Promise.resolve();

  function beginConsentTransition() {
    consentEpoch += 1;
    activeConsentTransition = consentEpoch;
    return consentEpoch;
  }

  function finishConsentTransition(transitionEpoch) {
    if (consentEpoch === transitionEpoch && activeConsentTransition === transitionEpoch) {
      activeConsentTransition = null;
    }
  }

  function isConsentEpochCurrent(capturedEpoch) {
    return capturedEpoch === consentEpoch && activeConsentTransition === null;
  }

  function isTransitionCurrent(transitionEpoch) {
    return transitionEpoch === consentEpoch && activeConsentTransition === transitionEpoch;
  }

  function getConsentEpoch() {
    return consentEpoch;
  }

  function queueConsentTransition(transitionEpoch, operation) {
    const queued = consentTransitionTail
      .catch(() => undefined)
      .then(async () => {
        if (!isTransitionCurrent(transitionEpoch)) {
          return { ok: false, status: disabledStatus() };
        }
        return operation();
      });
    consentTransitionTail = queued.then(() => undefined, () => undefined);
    return queued;
  }

  async function waitForActiveCycle() {
    const pendingCycle = activeCyclePromise;
    if (!pendingCycle) {
      return;
    }

    try {
      await pendingCycle;
    } catch (_error) {
      // A consent transition still proceeds to its fail-closed cleanup.
    }
  }

  function getNow(nowProvider) {
    const provider = typeof nowProvider === "function" ? nowProvider : Date.now;
    try {
      const value = provider();
      return Number.isInteger(value) && value > 0 ? value : null;
    } catch (_error) {
      return null;
    }
  }

  function createResult(cycle, status, reason, discardCalls, confirmedDiscards, skippedCount) {
    return core.createLastResult(
      cycle,
      status,
      reason,
      discardCalls,
      confirmedDiscards,
      skippedCount
    );
  }

  function isStrictAuditLog(log) {
    return Array.isArray(log) &&
      log.length <= core.MAX_AUDIT_ENTRIES &&
      log.every(core.isValidAuditEntry);
  }

  function createAuditEntry(timestamp, cycle, config, tabId, status, reason, availablePercent) {
    return {
      availablePercent,
      configRevision: config.configRevision,
      cycle,
      reason,
      status,
      tabId,
      timestamp
    };
  }

  function statusState(state) {
    const source = core.isValidState(state) ? state : core.createInitialState();
    return {
      lastAvailablePercent: source.lastAvailablePercent,
      pressureStreak: source.pressureStreak,
      requiredSamples: core.REQUIRED_PRESSURE_SAMPLES,
      lastCheckAt: source.lastCheckAt,
      lastActionAt: source.lastActionAt,
      lastResult: source.lastResult === null ? null : { ...source.lastResult }
    };
  }

  function disabledStatus() {
    return {
      enabled: false,
      config: null,
      state: statusState(core.createInitialState()),
      log: []
    };
  }

  async function containsPermissions(chromeApi, permissions) {
    if (!chromeApi || !chromeApi.permissions || typeof chromeApi.permissions.contains !== "function") {
      return false;
    }

    try {
      return await chromeApi.permissions.contains({ permissions }) === true;
    } catch (_error) {
      return false;
    }
  }

  async function hasRequiredPermissions(chromeApi) {
    return containsPermissions(chromeApi, REQUIRED_PERMISSIONS.slice());
  }

  function hasStorageApi(chromeApi) {
    return Boolean(
      chromeApi && chromeApi.storage && chromeApi.storage.local &&
      typeof chromeApi.storage.local.get === "function" &&
      typeof chromeApi.storage.local.set === "function" &&
      typeof chromeApi.storage.local.remove === "function"
    );
  }

  async function readBundle(chromeApi) {
    if (!hasStorageApi(chromeApi)) {
      return null;
    }

    try {
      const stored = await chromeApi.storage.local.get(AUTO_STORAGE_KEYS.slice());
      if (!core.isPlainObject(stored)) {
        return null;
      }

      return {
        config: stored[CONFIG_STORAGE_KEY],
        state: stored[STATE_STORAGE_KEY],
        log: stored[AUDIT_STORAGE_KEY]
      };
    } catch (_error) {
      return null;
    }
  }

  function isStrictBundle(bundle) {
    return Boolean(
      bundle &&
      core.isValidConfig(bundle.config) &&
      core.isValidState(bundle.state) &&
      isStrictAuditLog(bundle.log)
    );
  }

  async function setStorage(chromeApi, values) {
    if (!hasStorageApi(chromeApi)) {
      return false;
    }

    try {
      await chromeApi.storage.local.set(values);
      return true;
    } catch (_error) {
      return false;
    }
  }

  async function removeAutoStorage(chromeApi) {
    if (!hasStorageApi(chromeApi)) {
      return false;
    }

    try {
      await chromeApi.storage.local.remove(AUTO_STORAGE_KEYS.slice());
      return true;
    } catch (_error) {
      return false;
    }
  }

  async function clearAlarm(chromeApi) {
    if (!chromeApi || !chromeApi.alarms || typeof chromeApi.alarms.clear !== "function") {
      return false;
    }

    try {
      await chromeApi.alarms.clear(ALARM_NAME);
      return true;
    } catch (_error) {
      return false;
    }
  }

  async function createAlarm(chromeApi) {
    if (!chromeApi || !chromeApi.alarms || typeof chromeApi.alarms.create !== "function") {
      return false;
    }

    try {
      await chromeApi.alarms.create(ALARM_NAME, {
        delayInMinutes: ALARM_PERIOD_MINUTES,
        periodInMinutes: ALARM_PERIOD_MINUTES
      });
      return true;
    } catch (_error) {
      return false;
    }
  }

  async function getExactAlarm(chromeApi) {
    if (!chromeApi || !chromeApi.alarms || typeof chromeApi.alarms.get !== "function") {
      return null;
    }

    try {
      const alarm = await chromeApi.alarms.get(ALARM_NAME);
      return alarm && alarm.name === ALARM_NAME ? alarm : null;
    } catch (_error) {
      return null;
    }
  }

  async function readMemory(chromeApi) {
    if (
      !chromeApi || !chromeApi.system || !chromeApi.system.memory ||
      typeof chromeApi.system.memory.getInfo !== "function"
    ) {
      return null;
    }

    try {
      const info = await chromeApi.system.memory.getInfo();
      const availablePercent = core.getAvailablePercent(info);
      return availablePercent === null ? null : { info, availablePercent };
    } catch (_error) {
      return null;
    }
  }

  async function persistState(chromeApi, state) {
    if (!core.isValidState(state)) {
      return false;
    }

    return setStorage(chromeApi, { [STATE_STORAGE_KEY]: state });
  }

  async function persistStateAndLog(chromeApi, state, log) {
    if (!core.isValidState(state) || !isStrictAuditLog(log)) {
      return false;
    }

    return setStorage(chromeApi, {
      [STATE_STORAGE_KEY]: state,
      [AUDIT_STORAGE_KEY]: log
    });
  }

  async function resetContinuity(
    chromeApi,
    state,
    cycle,
    reason,
    nowMilliseconds,
    availablePercent
  ) {
    const resetState = core.resetPressureContinuity(state);
    resetState.lastAvailablePercent = Number.isFinite(availablePercent) ? availablePercent : null;
    resetState.lastCheckAt = nowMilliseconds;
    resetState.lastResult = createResult(cycle, "no-action", reason, 0, 0, 0);
    return persistState(chromeApi, resetState);
  }

  async function resetAfterInvalidStorage(chromeApi, cycle, reason, nowMilliseconds) {
    const replacement = core.createInitialState();
    replacement.lastCheckAt = nowMilliseconds;
    replacement.lastResult = createResult(cycle, "no-action", reason, 0, 0, 0);
    return setStorage(chromeApi, {
      [STATE_STORAGE_KEY]: replacement,
      [AUDIT_STORAGE_KEY]: []
    });
  }

  async function queryNormalWindowTabs(chromeApi) {
    if (!chromeApi || !chromeApi.tabs || typeof chromeApi.tabs.query !== "function") {
      return null;
    }

    try {
      const tabs = await chromeApi.tabs.query({
        windowType: "normal",
        active: false,
        pinned: false,
        audible: false,
        discarded: false,
        autoDiscardable: true,
        highlighted: false,
        status: "complete"
      });
      return Array.isArray(tabs) ? tabs : null;
    } catch (_error) {
      return null;
    }
  }

  async function appendOutcome(
    chromeApi,
    expectedConfigSignature,
    cycle,
    tabId,
    status,
    reason,
    availablePercent,
    nowMilliseconds,
    discardCalls,
    confirmedDiscards,
    skippedCount,
    markAction
  ) {
    const bundle = await readBundle(chromeApi);
    if (
      !isStrictBundle(bundle) ||
      core.configSignature(bundle.config) !== expectedConfigSignature
    ) {
      return false;
    }

    const entry = createAuditEntry(
      nowMilliseconds,
      cycle,
      bundle.config,
      tabId,
      status,
      reason,
      availablePercent
    );
    const nextLog = core.appendAuditEntry(bundle.log, entry);
    if (nextLog === null) {
      return false;
    }

    const nextState = { ...bundle.state };
    if (markAction) {
      nextState.lastActionAt = nowMilliseconds;
    }
    nextState.lastAvailablePercent = availablePercent;
    nextState.lastCheckAt = nowMilliseconds;
    nextState.lastResult = createResult(
      cycle,
      status === "discarded" ? "running" : status,
      reason,
      discardCalls,
      confirmedDiscards,
      skippedCount
    );
    return persistStateAndLog(chromeApi, nextState, nextLog);
  }

  async function reserveIntent(
    chromeApi,
    bundle,
    cycle,
    tabId,
    availablePercent,
    nowMilliseconds,
    discardCalls,
    confirmedDiscards,
    skippedCount
  ) {
    const nextState = core.resetPressureContinuity(bundle.state);
    nextState.cooldownUntil = Math.max(
      nextState.cooldownUntil,
      nowMilliseconds + core.COOLDOWN_MS
    );
    nextState.lastAvailablePercent = availablePercent;
    nextState.lastCheckAt = nowMilliseconds;
    nextState.lastResult = createResult(
      cycle,
      "running",
      "intent-reserved",
      discardCalls,
      confirmedDiscards,
      skippedCount
    );

    const intentEntry = createAuditEntry(
      nowMilliseconds,
      cycle,
      bundle.config,
      tabId,
      "intent",
      "eligible-under-pressure",
      availablePercent
    );
    const nextLog = core.appendAuditEntry(bundle.log, intentEntry);
    if (nextLog === null) {
      return false;
    }

    return persistStateAndLog(chromeApi, nextState, nextLog);
  }

  async function finalizeCycle(
    chromeApi,
    expectedConfigSignature,
    cycle,
    reason,
    nowMilliseconds,
    discardCalls,
    confirmedDiscards,
    skippedCount
  ) {
    const bundle = await readBundle(chromeApi);
    if (
      !isStrictBundle(bundle) ||
      core.configSignature(bundle.config) !== expectedConfigSignature
    ) {
      return false;
    }

    const nextState = core.resetPressureContinuity(bundle.state);
    nextState.lastResult = createResult(
      cycle,
      "completed",
      reason,
      discardCalls,
      confirmedDiscards,
      skippedCount
    );
    nextState.lastCheckAt = nowMilliseconds;
    return persistState(chromeApi, nextState);
  }

  async function runAutoGuardCycle(chromeApi, nowProvider, capturedConsentEpoch = consentEpoch) {
    if (!isConsentEpochCurrent(capturedConsentEpoch)) {
      return { ok: false, reason: "consent-cancelled" };
    }

    const cycle = getNow(nowProvider);
    if (cycle === null) {
      return { ok: false, reason: "invalid-clock" };
    }

    if (!await hasRequiredPermissions(chromeApi)) {
      if (await containsPermissions(chromeApi, ["storage"])) {
        await resetAfterInvalidStorage(chromeApi, cycle, "permissions-unavailable", cycle);
      }
      return { ok: false, reason: "permissions-unavailable" };
    }
    if (!isConsentEpochCurrent(capturedConsentEpoch)) {
      return { ok: false, reason: "consent-cancelled" };
    }

    let bundle = await readBundle(chromeApi);
    if (!isConsentEpochCurrent(capturedConsentEpoch)) {
      return { ok: false, reason: "consent-cancelled" };
    }
    if (!bundle) {
      await resetAfterInvalidStorage(chromeApi, cycle, "storage-unavailable", cycle);
      return { ok: false, reason: "storage-unavailable" };
    }

    if (!core.isValidConfig(bundle.config)) {
      await resetAfterInvalidStorage(chromeApi, cycle, "config-invalid", cycle);
      await clearAlarm(chromeApi);
      return { ok: false, reason: "config-invalid" };
    }

    if (!core.isValidState(bundle.state) || !isStrictAuditLog(bundle.log)) {
      await resetAfterInvalidStorage(chromeApi, cycle, "stored-state-invalid", cycle);
      return { ok: false, reason: "stored-state-invalid" };
    }

    const expectedConfigSignature = core.configSignature(bundle.config);
    const memory = await readMemory(chromeApi);
    if (!isConsentEpochCurrent(capturedConsentEpoch)) {
      return { ok: false, reason: "consent-cancelled" };
    }
    if (!memory) {
      await resetContinuity(
        chromeApi,
        bundle.state,
        cycle,
        "memory-invalid",
        cycle,
        null
      );
      return { ok: false, reason: "memory-invalid" };
    }

    if (bundle.state.cooldownUntil > cycle) {
      await resetContinuity(
        chromeApi,
        bundle.state,
        cycle,
        "cooldown-active",
        cycle,
        memory.availablePercent
      );
      return { ok: true, reason: "cooldown-active" };
    }

    if (!core.isLowMemory(memory.info, bundle.config.triggerPercent)) {
      await resetContinuity(
        chromeApi,
        bundle.state,
        cycle,
        "pressure-normal",
        cycle,
        memory.availablePercent
      );
      return { ok: true, reason: "pressure-normal" };
    }

    const pressureStreak = core.nextPressureStreak(bundle.state, cycle);
    const pressureState = {
      ...bundle.state,
      lastAvailablePercent: memory.availablePercent,
      lastCheckAt: cycle,
      lastLowSampleAt: cycle,
      lastResult: createResult(
        cycle,
        pressureStreak < core.REQUIRED_PRESSURE_SAMPLES ? "waiting" : "ready",
        pressureStreak < core.REQUIRED_PRESSURE_SAMPLES
          ? "pressure-sample-recorded"
          : "pressure-confirmed",
        0,
        0,
        0
      ),
      pressureStreak
    };
    if (!await persistState(chromeApi, pressureState)) {
      return { ok: false, reason: "storage-update-failed" };
    }
    if (!isConsentEpochCurrent(capturedConsentEpoch)) {
      return { ok: false, reason: "consent-cancelled" };
    }

    if (pressureStreak < core.REQUIRED_PRESSURE_SAMPLES) {
      return { ok: true, reason: "pressure-sample-recorded" };
    }

    const queriedTabs = await queryNormalWindowTabs(chromeApi);
    if (!isConsentEpochCurrent(capturedConsentEpoch)) {
      return { ok: false, reason: "consent-cancelled" };
    }
    if (!queriedTabs) {
      await resetContinuity(
        chromeApi,
        pressureState,
        cycle,
        "tab-query-invalid",
        cycle,
        memory.availablePercent
      );
      return { ok: false, reason: "tab-query-invalid" };
    }

    const candidates = core.filterAutoEligibleTabs(
      queriedTabs,
      bundle.config.inactivityMinutes,
      cycle
    );
    if (candidates.length === 0) {
      await resetContinuity(
        chromeApi,
        pressureState,
        cycle,
        "no-eligible-tabs",
        cycle,
        memory.availablePercent
      );
      return { ok: true, reason: "no-eligible-tabs" };
    }

    let discardCalls = 0;
    let confirmedDiscards = 0;
    let skippedCount = 0;

    for (const candidate of candidates) {
      if (discardCalls >= core.MAX_DISCARD_CALLS_PER_CYCLE) {
        break;
      }

      const targetNow = getNow(nowProvider);
      if (targetNow === null) {
        return { ok: false, reason: "invalid-clock" };
      }

      if (!await hasRequiredPermissions(chromeApi)) {
        await resetAfterInvalidStorage(chromeApi, cycle, "permissions-changed", targetNow);
        return { ok: false, reason: "permissions-changed" };
      }
      if (!isConsentEpochCurrent(capturedConsentEpoch)) {
        return { ok: false, reason: "consent-cancelled" };
      }

      bundle = await readBundle(chromeApi);
      if (!isConsentEpochCurrent(capturedConsentEpoch)) {
        return { ok: false, reason: "consent-cancelled" };
      }
      if (!isStrictBundle(bundle)) {
        await resetAfterInvalidStorage(chromeApi, cycle, "stored-state-changed", targetNow);
        return { ok: false, reason: "stored-state-changed" };
      }

      if (core.configSignature(bundle.config) !== expectedConfigSignature) {
        await resetContinuity(
          chromeApi,
          bundle.state,
          cycle,
          "config-changed",
          targetNow,
          bundle.state.lastAvailablePercent
        );
        return { ok: false, reason: "config-changed" };
      }

      const currentMemory = await readMemory(chromeApi);
      if (!isConsentEpochCurrent(capturedConsentEpoch)) {
        return { ok: false, reason: "consent-cancelled" };
      }
      if (!currentMemory) {
        await resetContinuity(
          chromeApi,
          bundle.state,
          cycle,
          "memory-invalid",
          targetNow,
          null
        );
        return { ok: false, reason: "memory-invalid" };
      }

      if (!core.isLowMemory(currentMemory.info, bundle.config.triggerPercent)) {
        await resetContinuity(
          chromeApi,
          bundle.state,
          cycle,
          "pressure-recovered",
          targetNow,
          currentMemory.availablePercent
        );
        return { ok: true, reason: "pressure-recovered" };
      }

      if (!await reserveIntent(
        chromeApi,
        bundle,
        cycle,
        candidate.id,
        currentMemory.availablePercent,
        targetNow,
        discardCalls,
        confirmedDiscards,
        skippedCount
      )) {
        return { ok: false, reason: "intent-storage-failed" };
      }
      if (!isConsentEpochCurrent(capturedConsentEpoch)) {
        return { ok: false, reason: "consent-cancelled" };
      }

      if (!await hasRequiredPermissions(chromeApi)) {
        await resetAfterInvalidStorage(chromeApi, cycle, "permissions-changed", targetNow);
        return { ok: false, reason: "permissions-changed" };
      }

      const reservedBundle = await readBundle(chromeApi);
      if (!isConsentEpochCurrent(capturedConsentEpoch)) {
        return { ok: false, reason: "consent-cancelled" };
      }
      if (
        !isStrictBundle(reservedBundle) ||
        core.configSignature(reservedBundle.config) !== expectedConfigSignature
      ) {
        if (reservedBundle && core.isValidState(reservedBundle.state)) {
          await resetContinuity(
            chromeApi,
            reservedBundle.state,
            cycle,
            "config-changed",
            targetNow,
            currentMemory.availablePercent
          );
        }
        return { ok: false, reason: "config-changed" };
      }

      let currentTab;
      try {
        currentTab = await chromeApi.tabs.get(candidate.id);
      } catch (_error) {
        await appendOutcome(
          chromeApi,
          expectedConfigSignature,
          cycle,
          candidate.id,
          "failed",
          "tab-get-failed",
          currentMemory.availablePercent,
          targetNow,
          discardCalls,
          confirmedDiscards,
          skippedCount,
          false
        );
        return { ok: false, reason: "tab-get-failed" };
      }
      if (!isConsentEpochCurrent(capturedConsentEpoch)) {
        return { ok: false, reason: "consent-cancelled" };
      }

      const ineligibilityReason = core.getAutoIneligibilityReason(
        currentTab,
        candidate.id,
        bundle.config.inactivityMinutes,
        targetNow
      );
      if (ineligibilityReason !== null) {
        if (!NORMAL_SKIP_REASONS.has(ineligibilityReason)) {
          await appendOutcome(
            chromeApi,
            expectedConfigSignature,
            cycle,
            candidate.id,
            "failed",
            ineligibilityReason,
            currentMemory.availablePercent,
            targetNow,
            discardCalls,
            confirmedDiscards,
            skippedCount,
            false
          );
          return { ok: false, reason: ineligibilityReason };
        }

        skippedCount += 1;
        if (!await appendOutcome(
          chromeApi,
          expectedConfigSignature,
          cycle,
          candidate.id,
          "skipped",
          ineligibilityReason,
          currentMemory.availablePercent,
          targetNow,
          discardCalls,
          confirmedDiscards,
          skippedCount,
          false
        )) {
          return { ok: false, reason: "skip-storage-failed" };
        }
        continue;
      }

      // This synchronous epoch check is intentionally adjacent to discard.
      // Disable, re-enable, or permission removal invalidates the captured
      // consent before any later discard call can be issued.
      if (!isConsentEpochCurrent(capturedConsentEpoch)) {
        return { ok: false, reason: "consent-cancelled" };
      }
      let discardPromise;
      try {
        discardPromise = chromeApi.tabs.discard(candidate.id);
        discardCalls += 1;
      } catch (_error) {
        discardCalls += 1;
        await appendOutcome(
          chromeApi,
          expectedConfigSignature,
          cycle,
          candidate.id,
          "failed",
          "discard-call-failed",
          currentMemory.availablePercent,
          targetNow,
          discardCalls,
          confirmedDiscards,
          skippedCount,
          false
        );
        return { ok: false, reason: "discard-call-failed" };
      }

      let discardResponse;
      try {
        discardResponse = await discardPromise;
      } catch (_error) {
        await appendOutcome(
          chromeApi,
          expectedConfigSignature,
          cycle,
          candidate.id,
          "failed",
          "discard-call-failed",
          currentMemory.availablePercent,
          targetNow,
          discardCalls,
          confirmedDiscards,
          skippedCount,
          false
        );
        return { ok: false, reason: "discard-call-failed" };
      }

      if (
        !discardResponse ||
        discardResponse.id !== candidate.id ||
        discardResponse.discarded !== true
      ) {
        await appendOutcome(
          chromeApi,
          expectedConfigSignature,
          cycle,
          candidate.id,
          "failed",
          "discard-response-unconfirmed",
          currentMemory.availablePercent,
          targetNow,
          discardCalls,
          confirmedDiscards,
          skippedCount,
          false
        );
        return { ok: false, reason: "discard-response-unconfirmed" };
      }

      let confirmedTab;
      try {
        confirmedTab = await chromeApi.tabs.get(candidate.id);
      } catch (_error) {
        await appendOutcome(
          chromeApi,
          expectedConfigSignature,
          cycle,
          candidate.id,
          "failed",
          "confirmation-failed",
          currentMemory.availablePercent,
          targetNow,
          discardCalls,
          confirmedDiscards,
          skippedCount,
          false
        );
        return { ok: false, reason: "confirmation-failed" };
      }

      if (
        !confirmedTab ||
        confirmedTab.id !== candidate.id ||
        confirmedTab.discarded !== true
      ) {
        await appendOutcome(
          chromeApi,
          expectedConfigSignature,
          cycle,
          candidate.id,
          "failed",
          "confirmation-failed",
          currentMemory.availablePercent,
          targetNow,
          discardCalls,
          confirmedDiscards,
          skippedCount,
          false
        );
        return { ok: false, reason: "confirmation-failed" };
      }

      confirmedDiscards += 1;
      if (!await appendOutcome(
        chromeApi,
        expectedConfigSignature,
        cycle,
        candidate.id,
        "discarded",
        "confirmed-discarded",
        currentMemory.availablePercent,
        targetNow,
        discardCalls,
        confirmedDiscards,
        skippedCount,
        true
      )) {
        return { ok: false, reason: "outcome-storage-failed" };
      }
    }

    const completionNow = getNow(nowProvider);
    if (completionNow === null) {
      return { ok: false, reason: "invalid-clock" };
    }
    const completionReason = discardCalls >= core.MAX_DISCARD_CALLS_PER_CYCLE
      ? "discard-call-cap-reached"
      : "candidates-exhausted";
    if (!await finalizeCycle(
      chromeApi,
      expectedConfigSignature,
      cycle,
      completionReason,
      completionNow,
      discardCalls,
      confirmedDiscards,
      skippedCount
    )) {
      return { ok: false, reason: "final-storage-failed" };
    }

    return {
      ok: true,
      reason: completionReason,
      discardCalls,
      confirmedDiscards,
      skippedCount
    };
  }

  function runAutoGuardLocked(chromeApi, nowProvider) {
    if (activeCyclePromise) {
      return activeCyclePromise;
    }

    if (activeConsentTransition !== null) {
      return Promise.resolve({ ok: false, reason: "consent-cancelled" });
    }

    const capturedConsentEpoch = consentEpoch;
    activeCyclePromise = runAutoGuardCycle(chromeApi, nowProvider, capturedConsentEpoch)
      .finally(() => {
        activeCyclePromise = null;
      });
    return activeCyclePromise;
  }

  async function getStatus(chromeApi) {
    if (!await hasRequiredPermissions(chromeApi)) {
      return { ok: true, status: disabledStatus() };
    }

    const bundle = await readBundle(chromeApi);
    if (!isStrictBundle(bundle)) {
      return { ok: false, status: disabledStatus() };
    }

    const alarm = await getExactAlarm(chromeApi);
    return {
      ok: Boolean(alarm),
      status: {
        enabled: Boolean(alarm),
        config: { ...bundle.config },
        state: statusState(bundle.state),
        log: core.sanitizeAuditLog(bundle.log)
      }
    };
  }

  function extractEnablePayload(message) {
    const expectedKeys = ["consentVersion", "inactivityMinutes", "triggerPercent"];
    if (!core.hasExactKeys(message.payload, expectedKeys)) {
      return null;
    }

    const payload = message.payload;
    if (
      payload.consentVersion !== core.CONSENT_VERSION ||
      typeof payload.inactivityMinutes !== "number" ||
      typeof payload.triggerPercent !== "number"
    ) {
      return null;
    }

    return payload;
  }

  async function disarmWithinTransition(chromeApi, transitionEpoch) {
    await waitForActiveCycle();
    if (!isTransitionCurrent(transitionEpoch)) {
      return { ok: false, status: disabledStatus() };
    }

    const alarmCleared = await clearAlarm(chromeApi);
    if (!isTransitionCurrent(transitionEpoch)) {
      return { ok: false, status: disabledStatus() };
    }

    const storageCleared = await removeAutoStorage(chromeApi);
    return {
      ok: alarmCleared && storageCleared,
      status: disabledStatus()
    };
  }

  function enableAutoGuard(chromeApi, message, nowProvider) {
    const transitionEpoch = beginConsentTransition();
    const nowMilliseconds = getNow(nowProvider);
    const payload = extractEnablePayload(message);
    const config = payload
      ? core.createConfig(payload.triggerPercent, payload.inactivityMinutes)
      : null;

    return queueConsentTransition(transitionEpoch, async () => {
      await waitForActiveCycle();
      if (!isTransitionCurrent(transitionEpoch)) {
        return { ok: false, status: disabledStatus() };
      }

      if (nowMilliseconds === null || !payload || !config) {
        await disarmWithinTransition(chromeApi, transitionEpoch);
        return { ok: false, status: disabledStatus() };
      }

      if (!await hasRequiredPermissions(chromeApi)) {
        await disarmWithinTransition(chromeApi, transitionEpoch);
        return { ok: false, status: disabledStatus() };
      }
      if (!isTransitionCurrent(transitionEpoch)) {
        return { ok: false, status: disabledStatus() };
      }

      const state = core.createInitialState();
      state.lastResult = createResult(nowMilliseconds, "enabled", "user-consent", 0, 0, 0);
      if (!await setStorage(chromeApi, {
        [CONFIG_STORAGE_KEY]: config,
        [STATE_STORAGE_KEY]: state,
        [AUDIT_STORAGE_KEY]: []
      })) {
        return { ok: false, status: disabledStatus() };
      }
      if (!isTransitionCurrent(transitionEpoch)) {
        return { ok: false, status: disabledStatus() };
      }

      if (!await createAlarm(chromeApi)) {
        await disarmWithinTransition(chromeApi, transitionEpoch);
        return { ok: false, status: disabledStatus() };
      }
      if (!isTransitionCurrent(transitionEpoch)) {
        return { ok: false, status: disabledStatus() };
      }

      registerAlarmListener(chromeApi, nowProvider);
      return getStatus(chromeApi);
    }).finally(() => {
      finishConsentTransition(transitionEpoch);
    });
  }

  function disableAutoGuard(chromeApi) {
    const transitionEpoch = beginConsentTransition();
    return queueConsentTransition(
      transitionEpoch,
      () => disarmWithinTransition(chromeApi, transitionEpoch)
    ).finally(() => {
      finishConsentTransition(transitionEpoch);
    });
  }

  async function ensureAlarm(chromeApi) {
    if (!await hasRequiredPermissions(chromeApi)) {
      return false;
    }

    const bundle = await readBundle(chromeApi);
    if (!isStrictBundle(bundle)) {
      return false;
    }

    if (await getExactAlarm(chromeApi)) {
      return true;
    }

    return createAlarm(chromeApi);
  }

  async function handleMessage(chromeApi, message, nowProvider) {
    if (!core.isPlainObject(message) || typeof message.type !== "string") {
      return { ok: false, status: disabledStatus() };
    }

    switch (message.type) {
      case "auto-guard:get-status":
        return getStatus(chromeApi);
      case "auto-guard:enable":
        return enableAutoGuard(chromeApi, message, nowProvider);
      case "auto-guard:disable":
        return disableAutoGuard(chromeApi);
      case "auto-guard:check-now":
        await runAutoGuardLocked(chromeApi, nowProvider);
        return getStatus(chromeApi);
      default:
        return { ok: false, status: disabledStatus() };
    }
  }

  function registerAlarmListener(chromeApi, nowProvider) {
    if (
      alarmListenerRegistered ||
      !chromeApi || !chromeApi.alarms || !chromeApi.alarms.onAlarm ||
      typeof chromeApi.alarms.onAlarm.addListener !== "function"
    ) {
      return false;
    }

    chromeApi.alarms.onAlarm.addListener((alarm) => {
      if (alarm && alarm.name === ALARM_NAME) {
        void runAutoGuardLocked(chromeApi, nowProvider);
      }
    });
    alarmListenerRegistered = true;
    return true;
  }

  function hasRemovedAutomaticPermission(removedPermissions) {
    return Boolean(
      removedPermissions &&
      Array.isArray(removedPermissions.permissions) &&
      removedPermissions.permissions.some((permission) => (
        REQUIRED_PERMISSIONS.includes(permission)
      ))
    );
  }

  function disarmForPermissionRemoval(chromeApi) {
    const transitionEpoch = beginConsentTransition();
    return queueConsentTransition(
      transitionEpoch,
      () => disarmWithinTransition(chromeApi, transitionEpoch)
    ).finally(() => {
      finishConsentTransition(transitionEpoch);
    });
  }

  function registerPermissionRemovalListener(chromeApi) {
    if (
      permissionRemovalListenerRegistered ||
      !chromeApi || !chromeApi.permissions || !chromeApi.permissions.onRemoved ||
      typeof chromeApi.permissions.onRemoved.addListener !== "function"
    ) {
      return false;
    }

    chromeApi.permissions.onRemoved.addListener((removedPermissions) => {
      if (hasRemovedAutomaticPermission(removedPermissions)) {
        // Invalidate consent synchronously before any cleanup await. A pending
        // tab.get therefore cannot be followed by a later discard call.
        void disarmForPermissionRemoval(chromeApi);
      }
    });
    permissionRemovalListenerRegistered = true;
    return true;
  }

  function registerWorker(chromeApi, nowProvider) {
    registerAlarmListener(chromeApi, nowProvider);
    registerPermissionRemovalListener(chromeApi);

    if (
      chromeApi && chromeApi.runtime && chromeApi.runtime.onMessage &&
      typeof chromeApi.runtime.onMessage.addListener === "function"
    ) {
      chromeApi.runtime.onMessage.addListener((message, _sender, sendResponse) => {
        void handleMessage(chromeApi, message, nowProvider)
          .then(sendResponse)
          .catch(() => sendResponse({ ok: false, status: disabledStatus() }));
        return true;
      });
    }

    const ensure = () => {
      void ensureAlarm(chromeApi);
    };

    if (
      chromeApi && chromeApi.runtime && chromeApi.runtime.onStartup &&
      typeof chromeApi.runtime.onStartup.addListener === "function"
    ) {
      chromeApi.runtime.onStartup.addListener(ensure);
    }

    if (
      chromeApi && chromeApi.runtime && chromeApi.runtime.onInstalled &&
      typeof chromeApi.runtime.onInstalled.addListener === "function"
    ) {
      chromeApi.runtime.onInstalled.addListener(ensure);
    }

    void ensureAlarm(chromeApi);
  }

  const exportedApi = Object.freeze({
    ALARM_NAME,
    ALARM_PERIOD_MINUTES,
    AUDIT_STORAGE_KEY,
    AUTOMATIC_OPTIONAL_PERMISSIONS,
    AUTO_STORAGE_KEYS,
    CONFIG_STORAGE_KEY,
    REQUIRED_PERMISSIONS,
    STATE_STORAGE_KEY,
    clearAlarm,
    createAlarm,
    disabledStatus,
    disableAutoGuard,
    disarmForPermissionRemoval,
    enableAutoGuard,
    ensureAlarm,
    getConsentEpoch,
    getStatus,
    handleMessage,
    queryNormalWindowTabs,
    registerPermissionRemovalListener,
    registerWorker,
    runAutoGuardCycle,
    runAutoGuardLocked
  });

  if (isCommonJs) {
    module.exports = exportedApi;
  } else {
    registerWorker(chrome, Date.now);
  }
}());
