/**
 * Wire protocol between the extension and the WorkSwitch macOS app.
 *
 * Frames are standard Chrome native messaging: a 4-byte little-endian length prefix
 * followed by UTF-8 JSON. The relay binary passes those frames through untouched, so this
 * is the only place the shape is defined on the JavaScript side; `BridgeProtocol.swift`
 * mirrors it.
 */

/** Tab metadata. Deliberately no page content — only what switching requires. */
export interface TabPayload {
  tabId: number;
  windowId: number;
  title: string;
  url: string;
  active: boolean;
  pinned: boolean;
  index: number;
  /** Milliseconds since epoch. Chrome 121+ only; omitted otherwise. */
  lastAccessed?: number;
}

export type ExtensionMessage =
  | { type: "hello"; extensionVersion: string; chromeVersion: string }
  | { type: "inventory"; tabs: TabPayload[]; focusedWindowId: number | null }
  | { type: "tab_updated"; tab: TabPayload }
  | { type: "tab_activated"; tabId: number; windowId: number }
  | { type: "tab_removed"; tabId: number }
  | { type: "window_removed"; windowId: number }
  | { type: "window_focus_changed"; windowId: number | null }
  | { type: "activate_result"; requestId: string; ok: boolean; error?: string };

export type HostMessage =
  | { type: "activate_tab"; requestId: string; tabId: number; windowId: number }
  | { type: "request_inventory" };

/** Chrome's sentinel for "no window focused". */
export const WINDOW_ID_NONE = -1;
