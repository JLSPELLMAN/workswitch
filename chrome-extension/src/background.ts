/**
 * WorkSwitch tab bridge service worker.
 *
 * Keeps a native messaging port open to the WorkSwitch macOS app, pushes the tab inventory
 * and subsequent tab/window events, and handles activation commands coming back.
 */

import {
  ExtensionMessage,
  HostMessage,
  TabPayload,
  WINDOW_ID_NONE,
} from "./protocol.js";

const HOST_NAME = "com.lorenzospellman.workswitch";

/** Reconnect backoff, in milliseconds. */
const RECONNECT_MIN_MS = 1_000;
const RECONNECT_MAX_MS = 30_000;

/**
 * MV3 service workers are terminated when idle. An open native messaging port resets the
 * idle timer, but a quiet port does not, so a periodic alarm both revives the worker and
 * repairs a dropped connection. 0.5 minutes is the smallest interval Chrome honours.
 */
const KEEPALIVE_ALARM = "workswitch-keepalive";
const KEEPALIVE_MINUTES = 0.5;

let port: chrome.runtime.Port | null = null;
let reconnectDelay = RECONNECT_MIN_MS;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

function connect(): void {
  if (port) return;

  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (error) {
    console.warn("[WorkSwitch] connectNative threw:", error);
    scheduleReconnect();
    return;
  }

  port.onMessage.addListener((message: HostMessage) => {
    void handleHostMessage(message);
  });

  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError?.message ?? "host closed the connection";
    console.warn("[WorkSwitch] Disconnected from native host:", reason);
    port = null;
    scheduleReconnect();
  });

  console.log("[WorkSwitch] Connected to native host");
  reconnectDelay = RECONNECT_MIN_MS;

  send({
    type: "hello",
    extensionVersion: chrome.runtime.getManifest().version,
    chromeVersion: navigator.userAgent,
  });
  void sendInventory();
}

function scheduleReconnect(): void {
  if (reconnectTimer !== null) return;
  const delay = reconnectDelay;
  // Exponential backoff keeps a stopped WorkSwitch app from being hammered.
  reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function send(message: ExtensionMessage): void {
  if (!port) return;
  try {
    port.postMessage(message);
  } catch (error) {
    console.warn("[WorkSwitch] postMessage failed:", error);
    port = null;
    scheduleReconnect();
  }
}

// ---------------------------------------------------------------------------
// Tab collection
// ---------------------------------------------------------------------------

/**
 * Incognito tabs are never reported, per the project's privacy rules. The extension is not
 * granted incognito access by default, but this makes the guarantee explicit rather than
 * relying on a Chrome setting the user could change.
 */
function isReportable(tab: chrome.tabs.Tab): boolean {
  return tab.id !== undefined && tab.id !== chrome.tabs.TAB_ID_NONE && !tab.incognito;
}

function toPayload(tab: chrome.tabs.Tab): TabPayload | null {
  if (!isReportable(tab)) return null;

  const payload: TabPayload = {
    tabId: tab.id as number,
    windowId: tab.windowId,
    title: tab.title ?? "",
    url: tab.url ?? tab.pendingUrl ?? "",
    active: tab.active === true,
    pinned: tab.pinned === true,
    index: tab.index,
  };

  // `lastAccessed` landed in Chrome 121; older builds simply omit it and the app falls
  // back to its own activation history.
  const lastAccessed = (tab as chrome.tabs.Tab & { lastAccessed?: number }).lastAccessed;
  if (typeof lastAccessed === "number") {
    payload.lastAccessed = lastAccessed;
  }
  return payload;
}

async function sendInventory(): Promise<void> {
  try {
    const tabs = await chrome.tabs.query({});
    const payloads = tabs
      .map(toPayload)
      .filter((tab): tab is TabPayload => tab !== null);

    let focusedWindowId: number | null = null;
    try {
      const focused = await chrome.windows.getLastFocused();
      focusedWindowId = focused.id ?? null;
    } catch {
      // No Chrome window is focused; not an error.
    }

    send({ type: "inventory", tabs: payloads, focusedWindowId });
    console.log(`[WorkSwitch] Sent inventory: ${payloads.length} tabs`);
  } catch (error) {
    console.warn("[WorkSwitch] Failed to build inventory:", error);
  }
}

async function sendTab(tabId: number): Promise<void> {
  try {
    const tab = await chrome.tabs.get(tabId);
    const payload = toPayload(tab);
    if (payload) send({ type: "tab_updated", tab: payload });
  } catch {
    // The tab closed between the event and this lookup; onRemoved handles it.
  }
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

async function handleHostMessage(message: HostMessage): Promise<void> {
  switch (message.type) {
    case "request_inventory":
      await sendInventory();
      break;

    case "activate_tab":
      await activateTab(message);
      break;

    default:
      console.warn("[WorkSwitch] Unknown host message:", message);
  }
}

async function activateTab(
  command: Extract<HostMessage, { type: "activate_tab" }>,
): Promise<void> {
  const { requestId, tabId, windowId } = command;
  console.log(`[WorkSwitch] Tab activation requested: tab ${tabId} in window ${windowId}`);

  try {
    // Select the tab within its window first, then raise the window. Doing it in this
    // order means the window comes forward already showing the right tab, with no visible
    // flash of whatever tab was previously selected.
    await chrome.tabs.update(tabId, { active: true });
    if (windowId !== WINDOW_ID_NONE) {
      await chrome.windows.update(windowId, { focused: true, drawAttention: false });
    }
    send({ type: "activate_result", requestId, ok: true });
    console.log(`[WorkSwitch] Tab ${tabId} activated`);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`[WorkSwitch] Tab activation failed for ${tabId}: ${reason}`);
    send({ type: "activate_result", requestId, ok: false, error: reason });
    // The tab probably closed without us hearing about it; resync.
    await sendInventory();
  }
}

// ---------------------------------------------------------------------------
// Event wiring
// ---------------------------------------------------------------------------

chrome.tabs.onCreated.addListener((tab) => {
  const payload = toPayload(tab);
  if (payload) send({ type: "tab_updated", tab: payload });
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  // Navigation fires this repeatedly. Only the fields that affect the switcher matter.
  if (
    changeInfo.title === undefined &&
    changeInfo.url === undefined &&
    changeInfo.pinned === undefined &&
    changeInfo.status !== "complete"
  ) {
    return;
  }
  void sendTab(tabId);
});

chrome.tabs.onActivated.addListener(({ tabId, windowId }) => {
  send({ type: "tab_activated", tabId, windowId });
  void sendTab(tabId);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  send({ type: "tab_removed", tabId });
});

chrome.tabs.onMoved.addListener((tabId) => {
  void sendTab(tabId);
});

// A detached tab changes windows, so its record needs rebuilding.
chrome.tabs.onAttached.addListener((tabId) => {
  void sendTab(tabId);
});

chrome.windows.onCreated.addListener(() => {
  void sendInventory();
});

chrome.windows.onRemoved.addListener((windowId) => {
  send({ type: "window_removed", windowId });
});

chrome.windows.onFocusChanged.addListener((windowId) => {
  send({
    type: "window_focus_changed",
    windowId: windowId === WINDOW_ID_NONE ? null : windowId,
  });
});

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== KEEPALIVE_ALARM) return;
  if (!port) {
    connect();
  }
});

function bootstrap(): void {
  chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: KEEPALIVE_MINUTES });
  connect();
}

chrome.runtime.onStartup.addListener(bootstrap);
chrome.runtime.onInstalled.addListener(bootstrap);

// Also runs on every service worker revival, which is the common case in MV3.
bootstrap();
