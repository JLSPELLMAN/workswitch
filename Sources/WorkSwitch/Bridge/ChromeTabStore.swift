import AppKit
import Foundation

/// Holds the live Chrome tab inventory reported by connected extensions, and normalizes it
/// into `Destination` values.
///
/// State is keyed by connection first, because tab and window IDs are only unique within a
/// Chrome profile — two profiles can both have a tab 5. Dropping a connection therefore
/// drops exactly that profile's tabs and nothing else.
@MainActor
final class ChromeTabStore {

    typealias ConnectionID = NativeMessagingServer.ConnectionID

    private struct ProfileState {
        var tabs: [Int: BridgeProtocol.TabPayload] = [:]
        var focusedWindowId: Int?
        var extensionVersion: String?
        /// Assigned in connection order; only surfaced when more than one profile is live.
        var label: String
    }

    private var profiles: [ConnectionID: ProfileState] = [:]
    private var profileCounter = 0

    /// Fires whenever the tab set changes, so the overlay can refresh if it is open.
    var onChange: (() -> Void)?

    var isConnected: Bool { !profiles.isEmpty }
    var connectionCount: Int { profiles.count }
    var tabCount: Int { profiles.values.reduce(0) { $0 + $1.tabs.count } }

    // MARK: - Connection lifecycle

    func connectionOpened(_ id: ConnectionID) {
        profileCounter += 1
        profiles[id] = ProfileState(label: "Profile \(profileCounter)")
        onChange?()
    }

    func connectionClosed(_ id: ConnectionID) {
        // Removes that profile's tabs wholesale, so nothing stale survives a disconnect.
        profiles[id] = nil
        if profiles.isEmpty { profileCounter = 0 }
        onChange?()
    }

    // MARK: - Events

    func handle(_ message: BridgeProtocol.Inbound, from id: ConnectionID) {
        guard profiles[id] != nil else { return }

        switch message {
        case .hello(let version):
            profiles[id]?.extensionVersion = version
            NSLog("[WorkSwitch] Bridge: extension v\(version) on connection \(id.value)")

        case .inventory(let tabs, let focusedWindowId):
            // Authoritative snapshot: replace rather than merge, so tabs closed while the
            // app was down cannot linger.
            var state = profiles[id]!
            state.tabs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabId, $0) })
            state.focusedWindowId = focusedWindowId
            profiles[id] = state
            NSLog("[WorkSwitch] Bridge: inventory received — \(tabs.count) tabs (connection \(id.value))")
            onChange?()

        case .tabUpdated(let tab):
            profiles[id]?.tabs[tab.tabId] = tab
            onChange?()

        case .tabActivated(let tabId, let windowId):
            // Mirror Chrome's own invariant: one active tab per window.
            if var state = profiles[id] {
                for (key, tab) in state.tabs where tab.windowId == windowId {
                    state.tabs[key] = tab.withActive(key == tabId)
                }
                state.focusedWindowId = windowId
                profiles[id] = state
            }
            onChange?()

        case .tabRemoved(let tabId):
            profiles[id]?.tabs[tabId] = nil
            onChange?()

        case .windowRemoved(let windowId):
            if var state = profiles[id] {
                state.tabs = state.tabs.filter { $0.value.windowId != windowId }
                if state.focusedWindowId == windowId { state.focusedWindowId = nil }
                profiles[id] = state
            }
            onChange?()

        case .windowFocusChanged(let windowId):
            profiles[id]?.focusedWindowId = windowId

        case .activateResult(_, let ok, let error):
            if !ok {
                NSLog("[WorkSwitch] Bridge: tab activation failed: \(error ?? "unknown reason")")
            }

        case .unknown(let type):
            NSLog("[WorkSwitch] Bridge: ignoring unknown message type '\(type)'")
        }
    }

    // MARK: - Normalization

    func destinations() -> [Destination] {
        // Profile labels only add noise when there is a single profile connected.
        let showProfileLabels = profiles.count > 1

        // Chrome tracks its own focused window regardless of whether Chrome is the frontmost
        // macOS app. A tab is only "where you are" when Chrome itself is frontmost —
        // otherwise the active tab would be wrongly demoted while you work in another app.
        let isChromeFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .map { $0.hasPrefix(Self.chromeBundleID) } ?? false

        return profiles.flatMap { connectionID, state -> [Destination] in
            state.tabs.values.map { tab in
                makeDestination(
                    tab: tab,
                    connectionID: connectionID,
                    profileLabel: showProfileLabels ? state.label : nil,
                    isWindowFocused: state.focusedWindowId == tab.windowId && isChromeFrontmost
                )
            }
        }
    }

    private func makeDestination(
        tab: BridgeProtocol.TabPayload,
        connectionID: ConnectionID,
        profileLabel: String?,
        isWindowFocused: Bool
    ) -> Destination {
        let host = URL(string: tab.url)?.host
        let lastAccessed = tab.lastAccessed.map { Date(timeIntervalSince1970: $0 / 1000.0) }

        return Destination(
            // The connection is part of the identity, so identical tab IDs in two profiles
            // stay distinct.
            id: "chrome:\(connectionID.value):\(tab.windowId):\(tab.tabId)",
            type: .browserTab,
            appName: "Google Chrome",
            bundleID: Self.chromeBundleID,
            title: tab.title,
            url: tab.url,
            domain: host.map(Self.prettyHost),
            browserProfile: profileLabel,
            tabID: tab.tabId,
            browserWindowID: tab.windowId,
            pid: chromePID ?? 0,
            windowID: nil,
            lastActivated: lastAccessed,
            isActive: tab.active && isWindowFocused,
            isPinned: tab.pinned,
            connectionID: connectionID
        )
    }

    /// `nonisolated` so the merger, which runs off the main actor, can read it.
    nonisolated static let chromeBundleID = "com.google.Chrome"

    /// Cached so the tab list does not scan the process table per row.
    private var cachedChromePID: pid_t?

    private var chromePID: pid_t? {
        if let cachedChromePID,
           NSRunningApplication(processIdentifier: cachedChromePID) != nil {
            return cachedChromePID
        }
        let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.chromeBundleID)
            .first?
            .processIdentifier
        cachedChromePID = pid
        return pid
    }

    private static func prettyHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Activation routing

    /// Which connection owns a destination, so activation goes to the right profile.
    func connection(for destination: Destination) -> ConnectionID? {
        destination.connectionID
    }
}

private extension BridgeProtocol.TabPayload {
    func withActive(_ active: Bool) -> BridgeProtocol.TabPayload {
        BridgeProtocol.TabPayload(
            tabId: tabId,
            windowId: windowId,
            title: title,
            url: url,
            active: active,
            pinned: pinned,
            index: index,
            lastAccessed: lastAccessed
        )
    }
}
