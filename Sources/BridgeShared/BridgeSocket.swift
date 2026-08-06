import Foundation

/// Constants shared by the WorkSwitch app (socket server) and the relay binary (client).
public enum BridgeSocket {

    public static let hostName = "com.lorenzospellman.workswitch"

    /// Directory holding the app's local state. Milestone 3's SQLite database lands here too.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WorkSwitch", isDirectory: true)
    }

    /// Unix domain socket the relay connects to.
    ///
    /// `sockaddr_un.sun_path` is only 104 bytes on macOS, so this stays short deliberately.
    public static var defaultPath: String {
        supportDirectory.appendingPathComponent("bridge.sock").path
    }

    /// Chrome's inbound frame limit. Anything larger means the stream has desynced.
    public static let maxFrameBytes: UInt32 = 64 * 1024 * 1024
}
