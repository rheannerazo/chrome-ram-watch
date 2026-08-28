"use strict";

const assert = require("node:assert/strict");
const path = require("node:path");

const repositoryRoot = path.resolve(__dirname, "..");
const core = require(path.join(repositoryRoot, "companion-extension", "guard-core.js"));
const worker = require(path.join(repositoryRoot, "companion-extension", "service-worker.js"));

const BASE_TIME = 2_000_000_000_000;
const LOW_MEMORY = Object.freeze({ capacity: 10_000, availableCapacity: 1_000 });
const NORMAL_MEMORY = Object.freeze({ capacity: 10_000, availableCapacity: 5_000 });

function clone(value) {
  if (value === undefined) {
    return undefined;
  }

  return JSON.parse(JSON.stringify(value));
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function nextTurn() {
  return new Promise((resolve) => setImmediate(resolve));
}

async function waitUntil(predicate, description) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) {
      return;
    }
    await nextTurn();
  }
  assert.fail(`Timed out waiting for ${description}`);
}

function eligibleTab(id, lastAccessed) {
  return {
    id,
    active: false,
    pinned: false,
    audible: false,
    discarded: false,
    autoDiscardable: true,
    incognito: false,
    highlighted: false,
    status: "complete",
    lastAccessed,
    title: `Private title ${id}`,
    url: `https://private.example/${id}`
  };
}

function initialStore(options = {}) {
  const state = options.state ? clone(options.state) : core.createInitialState();
  const config = options.config ? clone(options.config) : core.createConfig();
  const log = options.log ? clone(options.log) : [];

  return {
    [worker.CONFIG_STORAGE_KEY]: config,
    [worker.STATE_STORAGE_KEY]: state,
    [worker.AUDIT_STORAGE_KEY]: log
  };
}

function pressureReadyStore(nowMilliseconds, options = {}) {
  const state = core.createInitialState();
  state.lastAvailablePercent = 10;
  state.lastCheckAt = nowMilliseconds - 2 * core.MINUTE_MS;
  state.lastLowSampleAt = nowMilliseconds - 2 * core.MINUTE_MS;
  state.pressureStreak = core.REQUIRED_PRESSURE_SAMPLES - 1;
  return initialStore({ ...options, state });
}

function createChromeMock(options = {}) {
  const calls = [];
  const storageData = clone(options.store || {});
  const alarmData = new Map();
  const alarmListeners = [];
  const permissionAddedListeners = [];
  const permissionRemovedListeners = [];
  const discardedIds = new Set();
  const sourceTabs = clone(options.tabs || []);
  const tabsById = new Map(sourceTabs.map((tab) => [tab.id, tab]));
  const getCounts = new Map();
  let memoryIndex = 0;
  let storageGetCount = 0;
  let storageSetCount = 0;
  let permissionCount = 0;
  let queryCount = 0;
  let discardCount = 0;
  let automaticPermissionsGranted = options.permissionsGranted !== false;
  let storagePermissionGranted = options.storagePermissionGranted !== false;

  if (options.alarmExists) {
    alarmData.set(worker.ALARM_NAME, {
      name: worker.ALARM_NAME,
      periodInMinutes: worker.ALARM_PERIOD_MINUTES
    });
  }

  function shouldFail(setting, context) {
    if (typeof setting === "function") {
      return setting(context) === true;
    }

    return setting === true;
  }

  function nextMemory() {
    const sequence = Array.isArray(options.memorySequence) && options.memorySequence.length > 0
      ? options.memorySequence
      : [LOW_MEMORY];
    const item = sequence[Math.min(memoryIndex, sequence.length - 1)];
    memoryIndex += 1;
    if (typeof item === "function") {
      return item({ index: memoryIndex, calls, storageData });
    }
    if (item instanceof Error) {
      throw item;
    }
    return clone(item);
  }

  const chromeApi = {
    permissions: {
      async contains(request) {
        permissionCount += 1;
        const call = {
          op: "permissions.contains",
          request: clone(request),
          count: permissionCount
        };
        calls.push(call);
        if (shouldFail(options.permissionsError, call)) {
          throw new Error("permission failure");
        }
        if (typeof options.permissionsGranted === "function") {
          return options.permissionsGranted(call) === true;
        }
        const requested = Array.isArray(request.permissions) ? request.permissions : [];
        return requested.every((permission) => (
          permission === "storage" ? storagePermissionGranted : automaticPermissionsGranted
        ));
      },
      async request(request) {
        const call = { op: "permissions.request", request: clone(request) };
        calls.push(call);
        if (options.permissionRequestGranted === false) {
          return false;
        }
        automaticPermissionsGranted = true;
        return true;
      },
      async remove(request) {
        const call = { op: "permissions.remove", request: clone(request) };
        calls.push(call);
        automaticPermissionsGranted = false;
        return true;
      },
      onAdded: {
        addListener(listener) {
          calls.push({ op: "permissions.onAdded.addListener" });
          permissionAddedListeners.push(listener);
        }
      },
      onRemoved: {
        addListener(listener) {
          calls.push({ op: "permissions.onRemoved.addListener" });
          permissionRemovedListeners.push(listener);
        }
      }
    },
    storage: {
      local: {
        async get(keys) {
          storageGetCount += 1;
          const call = { op: "storage.get", keys: clone(keys), count: storageGetCount };
          calls.push(call);
          if (shouldFail(options.storageGetError, call)) {
            throw new Error("storage get failure");
          }

          if (!Array.isArray(keys)) {
            return clone(storageData);
          }

          const result = {};
          for (const key of keys) {
            if (Object.prototype.hasOwnProperty.call(storageData, key)) {
              result[key] = clone(storageData[key]);
            }
          }
          return result;
        },
        async set(values) {
          storageSetCount += 1;
          const call = { op: "storage.set", values: clone(values), count: storageSetCount };
          calls.push(call);
          if (shouldFail(options.storageSetError, call)) {
            throw new Error("storage set failure");
          }
          for (const [key, value] of Object.entries(values)) {
            storageData[key] = clone(value);
          }
        },
        async remove(keys) {
          const call = { op: "storage.remove", keys: clone(keys) };
          calls.push(call);
          if (shouldFail(options.storageRemoveError, call)) {
            throw new Error("storage remove failure");
          }
          for (const key of keys) {
            delete storageData[key];
          }
        }
      }
    },
    alarms: {
      async create(name, alarmInfo) {
        const call = { op: "alarms.create", name, alarmInfo: clone(alarmInfo) };
        calls.push(call);
        if (shouldFail(options.alarmCreateError, call)) {
          throw new Error("alarm create failure");
        }
        alarmData.set(name, { name, ...clone(alarmInfo) });
      },
      async get(name) {
        calls.push({ op: "alarms.get", name });
        return clone(alarmData.get(name));
      },
      async clear(name) {
        const call = { op: "alarms.clear", name };
        calls.push(call);
        if (shouldFail(options.alarmClearError, call)) {
          throw new Error("alarm clear failure");
        }
        const existed = alarmData.has(name);
        alarmData.delete(name);
        return existed;
      },
      onAlarm: {
        addListener(listener) {
          calls.push({ op: "alarms.onAlarm.addListener" });
          alarmListeners.push(listener);
        }
      }
    },
    system: {
      memory: {
        async getInfo() {
          const call = { op: "memory.getInfo", count: memoryIndex + 1 };
          calls.push(call);
          if (shouldFail(options.memoryError, call)) {
            throw new Error("memory failure");
          }
          return nextMemory();
        }
      }
    },
    tabs: {
      async query(queryInfo) {
        queryCount += 1;
        const call = { op: "tabs.query", queryInfo: clone(queryInfo), count: queryCount };
        calls.push(call);
        if (shouldFail(options.queryError, call)) {
          throw new Error("query failure");
        }
        if (typeof options.queryBehavior === "function") {
          return options.queryBehavior(call);
        }
        return clone(sourceTabs);
      },
      async get(tabId) {
        const count = (getCounts.get(tabId) || 0) + 1;
        getCounts.set(tabId, count);
        const call = { op: "tabs.get", tabId, count };
        calls.push(call);
        if (shouldFail(options.getError, call)) {
          throw new Error("tab get failure");
        }
        if (typeof options.getBehavior === "function") {
          const value = await options.getBehavior({
            ...call,
            calls,
            discardedIds,
            sourceTab: clone(tabsById.get(tabId))
          });
          return clone(value);
        }
        const source = tabsById.get(tabId);
        if (!source) {
          throw new Error("unknown tab");
        }
        return { ...clone(source), discarded: discardedIds.has(tabId) || source.discarded === true };
      },
      async discard(tabId) {
        discardCount += 1;
        const call = { op: "tabs.discard", tabId, count: discardCount };
        calls.push(call);
        if (typeof options.discardBehavior === "function") {
          const value = await options.discardBehavior({
            ...call,
            calls,
            discardedIds,
            sourceTab: clone(tabsById.get(tabId))
          });
          return clone(value);
        }
        if (shouldFail(options.discardError, call)) {
          throw new Error("discard failure");
        }
        discardedIds.add(tabId);
        const source = tabsById.get(tabId) || { id: tabId };
        return { ...clone(source), id: tabId, discarded: true };
      }
    },
    runtime: {
      onMessage: { addListener() {} },
      onStartup: { addListener() {} },
      onInstalled: { addListener() {} }
    }
  };

  return {
    alarmData,
    alarmListeners,
    calls,
    chromeApi,
    discardedIds,
    async grantAutomaticPermissions(permissions = ["alarms", "system.memory"]) {
      automaticPermissionsGranted = true;
      const event = { permissions: permissions.slice() };
      calls.push({ op: "permissions.onAdded", event: clone(event) });
      for (const listener of permissionAddedListeners) {
        await listener(event);
      }
      await nextTurn();
    },
    async revokeAutomaticPermissions(permissions = ["alarms", "system.memory"]) {
      automaticPermissionsGranted = false;
      const event = { permissions: permissions.slice() };
      calls.push({ op: "permissions.onRemoved", event: clone(event) });
      for (const listener of permissionRemovedListeners) {
        await listener(event);
      }
      await nextTurn();
    },
    setAutomaticPermissions(granted) {
      automaticPermissionsGranted = granted === true;
    },
    storageData
  };
}

function auditEntry(index) {
  return {
    availablePercent: 10,
    configRevision: core.CONFIG_REVISION,
    cycle: index + 1,
    reason: "test-entry",
    status: "skipped",
    tabId: index,
    timestamp: BASE_TIME + index
  };
}

const tests = [];

function test(name, callback) {
  tests.push({ name, callback });
}

test("strict configuration rejects coercion, invalid choices, and excess keys", () => {
  const valid = core.createConfig(15, 240);
  assert.equal(core.isValidConfig(valid), true);
  assert.equal(core.createConfig("15", 240), null);
  assert.equal(core.createConfig(15, "240"), null);
  assert.equal(core.createConfig(11, 240), null);
  assert.equal(core.createConfig(15, 60), null);
  assert.equal(core.createConfig(Number.NaN, 240), null);
  assert.equal(core.isValidConfig({ ...valid, extra: true }), false);
  assert.equal(core.isValidConfig({ ...valid, consentVersion: "1" }), false);
});

test("the worker disables malformed stored configuration without mutation", async () => {
  const valid = core.createConfig(15, 240);
  const invalidConfigs = [
    { ...valid, triggerPercent: "15" },
    { ...valid, inactivityMinutes: 241 },
    { ...valid, extra: true }
  ];

  for (const config of invalidConfigs) {
    const mock = createChromeMock({
      alarmExists: true,
      store: initialStore({ config }),
      tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)]
    });
    const result = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME);
    assert.equal(result.reason, "config-invalid");
    assert.equal(mock.calls.some((call) => call.op === "tabs.discard"), false);
    assert.equal(mock.alarmData.has(worker.ALARM_NAME), false);
  }
});

test("RAM pressure uses the unrounded boundary and rejects invalid capacity", () => {
  assert.equal(core.isLowMemory({ capacity: 10_000, availableCapacity: 1_500 }, 15), true);
  assert.equal(core.getAvailablePercent({ capacity: 10_000, availableCapacity: 1_500.1 }), 15);
  assert.equal(core.isLowMemory({ capacity: 10_000, availableCapacity: 1_500.1 }, 15), false);

  for (const memoryInfo of [
    null,
    {},
    { capacity: 0, availableCapacity: 0 },
    { capacity: -1, availableCapacity: 0 },
    { capacity: Number.NaN, availableCapacity: 0 },
    { capacity: Number.POSITIVE_INFINITY, availableCapacity: 1 },
    { capacity: 100, availableCapacity: -1 },
    { capacity: 100, availableCapacity: 101 },
    { capacity: 100, availableCapacity: Number.NaN }
  ]) {
    assert.equal(core.getAvailablePercent(memoryInfo), null);
    assert.equal(core.isLowMemory(memoryInfo, 15), false);
  }
});

test("pressure continuity requires three samples and resets after a long gap", () => {
  const first = core.createInitialState();
  assert.equal(core.nextPressureStreak(first, BASE_TIME), 1);

  const second = {
    ...first,
    lastLowSampleAt: BASE_TIME,
    pressureStreak: 1
  };
  assert.equal(core.nextPressureStreak(second, BASE_TIME + core.MAX_PRESSURE_SAMPLE_GAP_MS), 2);

  const third = {
    ...second,
    lastLowSampleAt: BASE_TIME + core.MAX_PRESSURE_SAMPLE_GAP_MS,
    pressureStreak: 2
  };
  assert.equal(
    core.nextPressureStreak(third, BASE_TIME + 2 * core.MAX_PRESSURE_SAMPLE_GAP_MS),
    core.REQUIRED_PRESSURE_SAMPLES
  );
  assert.equal(
    core.nextPressureStreak(third, BASE_TIME + 2 * core.MAX_PRESSURE_SAMPLE_GAP_MS + 1),
    1
  );
});

test("automatic eligibility requires every protected state to be explicitly safe", () => {
  const baseline = eligibleTab(7, BASE_TIME - 240 * core.MINUTE_MS);
  assert.equal(core.getAutoIneligibilityReason(baseline, 7, 240, BASE_TIME), null);

  const cases = [
    ["active", true, core.INELIGIBLE.ACTIVE],
    ["active", undefined, core.INELIGIBLE.ACTIVE_UNKNOWN],
    ["pinned", true, core.INELIGIBLE.PINNED],
    ["pinned", undefined, core.INELIGIBLE.PINNED_UNKNOWN],
    ["audible", true, core.INELIGIBLE.AUDIBLE],
    ["audible", undefined, core.INELIGIBLE.AUDIBLE_UNKNOWN],
    ["discarded", true, core.INELIGIBLE.ALREADY_DISCARDED],
    ["discarded", undefined, core.INELIGIBLE.DISCARDED_UNKNOWN],
    ["autoDiscardable", false, core.INELIGIBLE.NOT_AUTO_DISCARDABLE],
    ["autoDiscardable", undefined, core.INELIGIBLE.AUTO_DISCARDABLE_UNKNOWN],
    ["incognito", true, core.INELIGIBLE.INCOGNITO],
    ["incognito", undefined, core.INELIGIBLE.INCOGNITO_UNKNOWN],
    ["highlighted", true, core.INELIGIBLE.HIGHLIGHTED],
    ["highlighted", undefined, core.INELIGIBLE.HIGHLIGHTED_UNKNOWN],
    ["status", "loading", core.INELIGIBLE.NOT_COMPLETE],
    ["status", undefined, core.INELIGIBLE.STATUS_UNKNOWN]
  ];

  for (const [field, value, expected] of cases) {
    assert.equal(
      core.getAutoIneligibilityReason({ ...baseline, [field]: value }, 7, 240, BASE_TIME),
      expected,
      `${field}=${String(value)} must fail closed`
    );
  }

  assert.equal(
    core.getAutoIneligibilityReason({ ...baseline, id: 8 }, 7, 240, BASE_TIME),
    core.INELIGIBLE.TAB_ID_MISMATCH
  );
  assert.equal(
    core.getAutoIneligibilityReason(
      { ...baseline, lastAccessed: baseline.lastAccessed + 1 },
      7,
      240,
      BASE_TIME
    ),
    core.INELIGIBLE.TOO_RECENT
  );
  assert.equal(
    core.getAutoIneligibilityReason({ ...baseline, lastAccessed: BASE_TIME + 1 }, 7, 240, BASE_TIME),
    core.INELIGIBLE.LAST_ACCESSED_INVALID
  );
});

test("eligible tabs are ordered oldest-first with a tab-ID tie break", () => {
  const tabs = [
    eligibleTab(3, BASE_TIME - 480 * core.MINUTE_MS),
    eligibleTab(2, BASE_TIME - 240 * core.MINUTE_MS),
    eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS),
    { ...eligibleTab(4, BASE_TIME - 600 * core.MINUTE_MS), active: true }
  ];
  assert.deepEqual(
    core.filterAutoEligibleTabs(tabs, 240, BASE_TIME).map((tab) => tab.id),
    [1, 3, 2]
  );
  assert.deepEqual(tabs.map((tab) => tab.id), [3, 2, 1, 4]);
});

test("disabled or missing-permission state never discards", async () => {
  const disabled = createChromeMock({
    store: {},
    tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)]
  });
  const disabledResult = await worker.runAutoGuardCycle(disabled.chromeApi, () => BASE_TIME);
  assert.equal(disabledResult.ok, false);
  assert.equal(disabled.calls.some((call) => call.op === "tabs.discard"), false);

  const missingPermission = createChromeMock({
    store: initialStore(),
    permissionsGranted: false,
    tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)]
  });
  const permissionResult = await worker.runAutoGuardCycle(missingPermission.chromeApi, () => BASE_TIME);
  assert.equal(permissionResult.reason, "permissions-unavailable");
  assert.equal(missingPermission.calls.some((call) => call.op === "tabs.discard"), false);
});

test("three sustained samples discard at most two tabs in deterministic order", async () => {
  const thirdTime = BASE_TIME + 4 * core.MINUTE_MS;
  const mock = createChromeMock({
    store: initialStore(),
    tabs: [
      eligibleTab(3, thirdTime - 600 * core.MINUTE_MS),
      eligibleTab(2, thirdTime - 500 * core.MINUTE_MS),
      eligibleTab(1, thirdTime - 600 * core.MINUTE_MS)
    ]
  });

  const first = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME);
  const second = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME + 2 * core.MINUTE_MS);
  const third = await worker.runAutoGuardCycle(mock.chromeApi, () => thirdTime);

  assert.equal(first.reason, "pressure-sample-recorded");
  assert.equal(second.reason, "pressure-sample-recorded");
  assert.deepEqual(
    mock.calls.filter((call) => call.op === "tabs.discard").map((call) => call.tabId),
    [1, 3]
  );
  assert.equal(third.ok, true);
  assert.equal(third.reason, "discard-call-cap-reached");
  assert.equal(third.discardCalls, core.MAX_DISCARD_CALLS_PER_CYCLE);
  assert.equal(third.confirmedDiscards, core.MAX_DISCARD_CALLS_PER_CYCLE);

  for (const discardCall of mock.calls.filter((call) => call.op === "tabs.discard")) {
    const discardIndex = mock.calls.indexOf(discardCall);
    const intentIndex = mock.calls.findIndex((call) => {
      const log = call.op === "storage.set" && call.values[worker.AUDIT_STORAGE_KEY];
      const latest = Array.isArray(log) ? log.at(-1) : null;
      return latest && latest.status === "intent" && latest.tabId === discardCall.tabId;
    });
    assert.ok(intentIndex >= 0 && intentIndex < discardIndex);
    assert.equal(mock.calls[discardIndex - 1].op, "tabs.get");
    assert.equal(mock.calls[discardIndex - 1].tabId, discardCall.tabId);
  }

  const statuses = mock.storageData[worker.AUDIT_STORAGE_KEY].map((entry) => entry.status);
  assert.deepEqual(statuses, ["intent", "discarded", "intent", "discarded"]);
});

test("intent is persisted before mutation and active-on-revalidation is skipped", async () => {
  const tab = eligibleTab(9, BASE_TIME - 480 * core.MINUTE_MS);
  const mock = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    tabs: [tab],
    getBehavior: ({ sourceTab }) => ({ ...sourceTab, active: true })
  });

  const result = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME);
  assert.equal(result.ok, true);
  assert.equal(result.skippedCount, 1);
  assert.equal(mock.calls.some((call) => call.op === "tabs.discard"), false);

  const intentSetIndex = mock.calls.findIndex((call) => {
    const log = call.op === "storage.set" && call.values[worker.AUDIT_STORAGE_KEY];
    return Array.isArray(log) && log.at(-1).status === "intent";
  });
  const finalGetIndex = mock.calls.findIndex((call) => call.op === "tabs.get");
  assert.ok(intentSetIndex >= 0 && finalGetIndex > intentSetIndex);
  assert.deepEqual(
    mock.storageData[worker.AUDIT_STORAGE_KEY].map((entry) => entry.status),
    ["intent", "skipped"]
  );
});

test("pressure recovery before mutation stops the cycle", async () => {
  const mock = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    memorySequence: [LOW_MEMORY, NORMAL_MEMORY],
    tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)]
  });
  const result = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME);
  assert.equal(result.ok, true);
  assert.equal(result.reason, "pressure-recovered");
  assert.equal(mock.calls.some((call) => call.op === "tabs.discard"), false);
  assert.equal(mock.storageData[worker.AUDIT_STORAGE_KEY].length, 0);
});

test("a wrong discard response aborts all remaining candidates", async () => {
  const mock = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    tabs: [
      eligibleTab(1, BASE_TIME - 600 * core.MINUTE_MS),
      eligibleTab(2, BASE_TIME - 500 * core.MINUTE_MS)
    ],
    discardBehavior: ({ tabId }) => ({ id: tabId + 100, discarded: true })
  });
  const result = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "discard-response-unconfirmed");
  assert.equal(mock.calls.filter((call) => call.op === "tabs.discard").length, 1);
  assert.equal(mock.storageData[worker.AUDIT_STORAGE_KEY].at(-1).reason, "discard-response-unconfirmed");
});

test("failed final confirmation aborts all remaining candidates", async () => {
  const mock = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    tabs: [
      eligibleTab(1, BASE_TIME - 600 * core.MINUTE_MS),
      eligibleTab(2, BASE_TIME - 500 * core.MINUTE_MS)
    ],
    getBehavior: ({ sourceTab }) => ({ ...sourceTab, discarded: false })
  });
  const result = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "confirmation-failed");
  assert.equal(mock.calls.filter((call) => call.op === "tabs.discard").length, 1);
  assert.equal(mock.storageData[worker.AUDIT_STORAGE_KEY].at(-1).reason, "confirmation-failed");
});

test("query, memory, and storage failures all fail closed", async () => {
  const queryFailure = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)],
    queryError: true
  });
  assert.equal(
    (await worker.runAutoGuardCycle(queryFailure.chromeApi, () => BASE_TIME)).reason,
    "tab-query-invalid"
  );
  assert.equal(queryFailure.calls.some((call) => call.op === "tabs.discard"), false);

  const memoryFailure = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)],
    memoryError: true
  });
  assert.equal(
    (await worker.runAutoGuardCycle(memoryFailure.chromeApi, () => BASE_TIME)).reason,
    "memory-invalid"
  );
  assert.equal(memoryFailure.calls.some((call) => call.op === "tabs.discard"), false);

  const readFailure = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    storageGetError: true,
    tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)]
  });
  assert.equal(
    (await worker.runAutoGuardCycle(readFailure.chromeApi, () => BASE_TIME)).reason,
    "storage-unavailable"
  );
  assert.equal(readFailure.calls.some((call) => call.op === "tabs.discard"), false);

  const intentFailure = createChromeMock({
    store: pressureReadyStore(BASE_TIME),
    tabs: [eligibleTab(1, BASE_TIME - 480 * core.MINUTE_MS)],
    storageSetError: (call) => {
      const log = call.values[worker.AUDIT_STORAGE_KEY];
      return Array.isArray(log) && log.at(-1).status === "intent";
    }
  });
  assert.equal(
    (await worker.runAutoGuardCycle(intentFailure.chromeApi, () => BASE_TIME)).reason,
    "intent-storage-failed"
  );
  assert.equal(intentFailure.calls.some((call) => call.op === "tabs.discard"), false);
});

test("audit output is private, sanitized, and bounded", async () => {
  const fullLog = Array.from({ length: core.MAX_AUDIT_ENTRIES }, (_value, index) => auditEntry(index));
  const tab = eligibleTab(7, BASE_TIME - 480 * core.MINUTE_MS);
  const mock = createChromeMock({
    store: pressureReadyStore(BASE_TIME, { log: fullLog }),
    tabs: [tab],
    discardBehavior: () => {
      throw new Error("SECRET title https://private.example/7");
    }
  });

  const result = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME);
  assert.equal(result.reason, "discard-call-failed");
  const log = mock.storageData[worker.AUDIT_STORAGE_KEY];
  assert.equal(log.length, core.MAX_AUDIT_ENTRIES);
  assert.equal(log.at(-2).status, "intent");
  assert.equal(log.at(-1).reason, "discard-call-failed");

  const serialized = JSON.stringify(log);
  assert.doesNotMatch(serialized, /SECRET|private\.example|"title"|"url"/i);
  for (const entry of log) {
    assert.equal(core.isValidAuditEntry(entry), true);
  }
});

test("disable cancels a cycle paused in the final tab revalidation", async () => {
  const tab = eligibleTab(31, BASE_TIME - 480 * core.MINUTE_MS);
  const getEntered = deferred();
  const releaseGet = deferred();
  const mock = createChromeMock({
    alarmExists: true,
    store: pressureReadyStore(BASE_TIME),
    tabs: [tab],
    getBehavior: async ({ count }) => {
      assert.equal(count, 1);
      getEntered.resolve();
      return releaseGet.promise;
    }
  });

  const epochBefore = worker.getConsentEpoch();
  const cyclePromise = worker.runAutoGuardLocked(mock.chromeApi, () => BASE_TIME);
  await getEntered.promise;

  const disablePromise = worker.handleMessage(
    mock.chromeApi,
    { type: "auto-guard:disable" },
    () => BASE_TIME
  );
  assert.ok(worker.getConsentEpoch() > epochBefore);

  releaseGet.resolve(tab);
  const cycleResult = await cyclePromise;
  const disableResult = await disablePromise;
  assert.equal(cycleResult.reason, "consent-cancelled");
  assert.equal(disableResult.ok, true);
  assert.equal(mock.calls.some((call) => call.op === "tabs.discard"), false);
  assert.equal(mock.alarmData.has(worker.ALARM_NAME), false);
  for (const key of worker.AUTO_STORAGE_KEYS) {
    assert.equal(Object.prototype.hasOwnProperty.call(mock.storageData, key), false);
  }
});

test("re-enable with a new configuration epoch cancels the old paused cycle", async () => {
  const tab = eligibleTab(32, BASE_TIME - 960 * core.MINUTE_MS);
  const getEntered = deferred();
  const releaseGet = deferred();
  const mock = createChromeMock({
    alarmExists: true,
    store: pressureReadyStore(BASE_TIME),
    tabs: [tab],
    getBehavior: async ({ count }) => {
      assert.equal(count, 1);
      getEntered.resolve();
      return releaseGet.promise;
    }
  });

  const cycleEpoch = worker.getConsentEpoch();
  const cyclePromise = worker.runAutoGuardLocked(mock.chromeApi, () => BASE_TIME);
  await getEntered.promise;

  const enablePromise = worker.handleMessage(mock.chromeApi, {
    type: "auto-guard:enable",
    payload: {
      consentVersion: core.CONSENT_VERSION,
      inactivityMinutes: 480,
      triggerPercent: 20
    }
  }, () => BASE_TIME + 1);
  assert.ok(worker.getConsentEpoch() > cycleEpoch);

  releaseGet.resolve(tab);
  const cycleResult = await cyclePromise;
  const enableResult = await enablePromise;
  assert.equal(cycleResult.reason, "consent-cancelled");
  assert.equal(mock.calls.some((call) => call.op === "tabs.discard"), false);
  assert.equal(enableResult.ok, true);
  assert.equal(enableResult.status.enabled, true);
  assert.deepEqual(mock.storageData[worker.CONFIG_STORAGE_KEY], core.createConfig(20, 480));
  assert.deepEqual(mock.storageData[worker.AUDIT_STORAGE_KEY], []);
});

test("permission removal during final revalidation disarms consent permanently", async () => {
  assert.deepEqual(worker.AUTOMATIC_OPTIONAL_PERMISSIONS, ["alarms", "system.memory"]);
  assert.equal(worker.AUTOMATIC_OPTIONAL_PERMISSIONS.includes("storage"), false);

  const tab = eligibleTab(33, BASE_TIME - 480 * core.MINUTE_MS);
  const getEntered = deferred();
  const releaseGet = deferred();
  const mock = createChromeMock({
    alarmExists: true,
    store: pressureReadyStore(BASE_TIME),
    tabs: [tab],
    getBehavior: async ({ count }) => {
      assert.equal(count, 1);
      getEntered.resolve();
      return releaseGet.promise;
    }
  });

  assert.equal(worker.registerPermissionRemovalListener(mock.chromeApi), true);
  const cycleEpoch = worker.getConsentEpoch();
  const cyclePromise = worker.runAutoGuardLocked(mock.chromeApi, () => BASE_TIME);
  await getEntered.promise;

  await mock.revokeAutomaticPermissions(["system.memory"]);
  assert.ok(worker.getConsentEpoch() > cycleEpoch);
  assert.equal(
    await mock.chromeApi.permissions.contains({ permissions: ["storage"] }),
    true,
    "Required storage must remain available when an automatic permission is removed."
  );

  releaseGet.resolve(tab);
  const cycleResult = await cyclePromise;
  assert.equal(cycleResult.reason, "consent-cancelled");
  assert.equal(mock.calls.some((call) => call.op === "tabs.discard"), false);

  await waitUntil(
    () => worker.AUTO_STORAGE_KEYS.every((key) => (
      !Object.prototype.hasOwnProperty.call(mock.storageData, key)
    )) && !mock.alarmData.has(worker.ALARM_NAME),
    "permission-removal cleanup"
  );

  await mock.grantAutomaticPermissions(worker.AUTOMATIC_OPTIONAL_PERMISSIONS);
  assert.equal(await worker.ensureAlarm(mock.chromeApi), false);
  assert.equal(mock.alarmData.has(worker.ALARM_NAME), false);

  const status = await worker.getStatus(mock.chromeApi);
  assert.equal(status.status.enabled, false);
  assert.equal(status.status.config, null);

  const resumedCycle = await worker.runAutoGuardCycle(mock.chromeApi, () => BASE_TIME + 1);
  assert.notEqual(resumedCycle.ok, true);
  assert.equal(mock.calls.some((call) => call.op === "tabs.discard"), false);
  assert.equal(mock.alarmData.has(worker.ALARM_NAME), false);
  assert.equal(
    Object.prototype.hasOwnProperty.call(mock.storageData, worker.CONFIG_STORAGE_KEY),
    false
  );
});

test("the run lock coalesces overlapping invocations", async () => {
  const mock = createChromeMock({ store: initialStore() });
  const first = worker.runAutoGuardLocked(mock.chromeApi, () => BASE_TIME);
  const second = worker.runAutoGuardLocked(mock.chromeApi, () => BASE_TIME);
  assert.strictEqual(second, first);
  const [firstResult, secondResult] = await Promise.all([first, second]);
  assert.deepEqual(secondResult, firstResult);
  assert.equal(mock.calls.filter((call) => call.op === "memory.getInfo").length, 1);
});

test("enable, status, and disable form a clean persisted roundtrip", async () => {
  const mock = createChromeMock({ store: {} });
  const now = () => BASE_TIME;
  const enableResponse = await worker.handleMessage(mock.chromeApi, {
    type: "auto-guard:enable",
    payload: {
      consentVersion: core.CONSENT_VERSION,
      inactivityMinutes: 240,
      triggerPercent: 15
    }
  }, now);

  assert.equal(enableResponse.ok, true);
  assert.equal(enableResponse.status.enabled, true);
  assert.equal(core.isValidConfig(mock.storageData[worker.CONFIG_STORAGE_KEY]), true);
  assert.equal(core.isValidState(mock.storageData[worker.STATE_STORAGE_KEY]), true);
  assert.deepEqual(mock.storageData[worker.AUDIT_STORAGE_KEY], []);
  assert.equal(mock.alarmData.has(worker.ALARM_NAME), true);

  const statusResponse = await worker.handleMessage(
    mock.chromeApi,
    { type: "auto-guard:get-status" },
    now
  );
  assert.equal(statusResponse.ok, true);
  assert.equal(statusResponse.status.enabled, true);
  assert.deepEqual(statusResponse.status.config, core.createConfig(15, 240));

  const disableResponse = await worker.handleMessage(
    mock.chromeApi,
    { type: "auto-guard:disable" },
    now
  );
  assert.equal(disableResponse.ok, true);
  assert.equal(disableResponse.status.enabled, false);
  assert.equal(mock.alarmData.has(worker.ALARM_NAME), false);
  for (const key of worker.AUTO_STORAGE_KEYS) {
    assert.equal(Object.prototype.hasOwnProperty.call(mock.storageData, key), false);
  }

  const removeCall = mock.calls.find((call) => call.op === "storage.remove");
  assert.deepEqual(removeCall.keys, worker.AUTO_STORAGE_KEYS);
});

async function main() {
  for (const { name, callback } of tests) {
    try {
      await callback();
    } catch (error) {
      error.message = `${name}: ${error.message}`;
      throw error;
    }
  }

  console.log(`All Chrome RAM Watch Auto Guard tests passed (${tests.length} cases).`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
