import AppKit
import Foundation

/// Owns the socket server and the tab store, and is the single place the rest of the app
/// talks to for anything Chrome-related.
@MainActor
final class BridgeCoordinator {

    enum Status {
        case notConnected
        case connected(profiles: Int, tabs: Int)

        var menuTitle: String {
            switch self {
            case .notConnected:
                return "Chrome Extension: Not Connected"
            case .connected(let profiles, let tabs):
                let profileText = profiles == 1 ? "1 profile" : "\(profiles) profiles"
                return "Chrome Extension: Connected (\(profileText), \(tabs) tabs)"
            }
        }
    }

    private let server = NativeMessagingServer()
    private let store = ChromeTabStore()

    /// Both the menu bar item and the overlay need to react to connection and tab changes,
    /// so this is a list rather than a single slot — one observer would silently replace
    /// the other.
    private var changeObservers: [() -> Void] = []

    func addChangeObserver(_ observer: @escaping () -> Void) {
        changeObservers.append(observer)
    }

    private func notifyChange() {
        for observer in changeObservers { observer() }
    }

    var isConnected: Bool { store.isConnected }

    var status: Status {
        store.isConnected
            ? .connected(profiles: store.connectionCount, tabs: store.tabCount)
            : .notConnected
    }

    func start() {
        store.onChange = { [weak self] in self?.notifyChange() }

        server.onConnect = { [weak self] id in
            guard let self else { return }
            self.store.connectionOpened(id)
            // The extension sends its inventory on connect, but asking for it explicitly
            // makes the app the authority on having a snapshot: if the extension's service
            // worker was revived mid-flight, or its initial query failed, this repairs the
            // state instead of leaving an empty tab list. Rebuilding is idempotent.
            _ = self.server.send(.requestInventory, to: id)
            self.notifyChange()
        }
        server.onDisconnect = { [weak self] id in
            self?.store.connectionClosed(id)
            self?.notifyChange()
        }
        server.onMessage = { [weak self] id, message in
            self?.store.handle(message, from: id)
        }

        server.start()
    }

    func stop() {
        server.stop()
    }

    func destinations() -> [Destination] {
        store.destinations()
    }

    // MARK: - Activation

    @discardableResult
    func activate(_ destination: Destination) -> ActivationResult {
        guard let tabID = destination.tabID,
              let windowID = destination.browserWindowID
        else {
            return .failure("Destination is missing Chrome identifiers")
        }
        guard let connection = store.connection(for: destination) else {
            return .failure("No live extension connection for this tab")
        }

        let requestId = UUID().uuidString
        NSLog("[WorkSwitch] Bridge: requesting activation of tab \(tabID) in window \(windowID)")

        let sent = server.send(
            .activateTab(requestId: requestId, tabId: tabID, windowId: windowID),
            to: connection
        )
        guard sent else {
            return .failure("Extension connection dropped before the command was sent")
        }

        // The extension selects the tab and focuses its Chrome window, but that does not
        // make Chrome the frontmost *application* on macOS. Activating the app here closes
        // that gap. The short delay lets the tab switch land first, so Chrome does not come
        // forward showing the previously selected tab.
        let chromePID = destination.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if chromePID > 0, let app = NSRunningApplication(processIdentifier: chromePID) {
                app.activate()
            } else {
                NSRunningApplication
                    .runningApplications(withBundleIdentifier: ChromeTabStore.chromeBundleID)
                    .first?
                    .activate()
            }
        }

        return .success
    }
}
