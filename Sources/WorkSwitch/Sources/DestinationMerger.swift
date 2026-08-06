import Foundation

/// Combines native-window and Chrome-tab destinations into the single list the overlay shows.
enum DestinationMerger {

    /// Chrome's own windows are still real macOS windows, so without this they would appear
    /// twice: once as "Google Chrome — <active tab title>" and again as the tab itself.
    ///
    /// When the extension is connected the tabs are strictly better destinations — they
    /// carry the URL, the domain, and can be activated exactly — so native Chrome windows
    /// are suppressed. If the extension is not connected the native windows are kept, which
    /// means an unconfigured or stopped extension degrades to Milestone 1 behaviour instead
    /// of hiding Chrome entirely.
    static func merge(
        nativeWindows: [Destination],
        chromeTabs: [Destination],
        isExtensionConnected: Bool
    ) -> [Destination] {
        guard isExtensionConnected, !chromeTabs.isEmpty else {
            return nativeWindows + chromeTabs
        }

        let filteredNative = nativeWindows.filter { !isChromeWindow($0) }
        return filteredNative + chromeTabs
    }

    /// Matches Chrome and its channel variants (Beta, Dev, Canary), which use bundle IDs
    /// prefixed with the stable one.
    static func isChromeWindow(_ destination: Destination) -> Bool {
        guard destination.type == .nativeWindow else { return false }
        guard let bundleID = destination.bundleID else {
            return destination.appName.hasPrefix("Google Chrome")
        }
        return bundleID.hasPrefix(ChromeTabStore.chromeBundleID)
    }
}
