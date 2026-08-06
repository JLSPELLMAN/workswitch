import BridgeShared
import Foundation

// WorkSwitch native messaging relay.
//
// Chrome launches a native messaging host as its own child process and talks to it over
// stdin/stdout. WorkSwitch, however, is a long-running menu-bar app that Chrome does not
// own — so it cannot be the host itself. This binary is the host: Chrome spawns it, and it
// pumps bytes between its stdio pipes and a Unix domain socket owned by the running app.
//
// It deliberately does no parsing. Native messaging framing (4-byte little-endian length +
// JSON) is used verbatim on the socket side too, so frames pass through untouched and all
// protocol logic lives in one place — the Swift app.

let socketPath = BridgeSocket.defaultPath

/// Chrome reads stderr for diagnostics, so logging there is safe. Writing anything to
/// stdout that is not a valid frame would corrupt the stream.
@Sendable func log(_ message: String) {
    FileHandle.standardError.write(Data("[workswitch-bridge] \(message)\n".utf8))
}

// MARK: - Connect to the app

let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketFD >= 0 else {
    log("socket() failed: \(String(cString: strerror(errno)))")
    exit(1)
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    log("socket path too long: \(socketPath)")
    exit(1)
}
withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { destination in
        for (index, byte) in pathBytes.enumerated() { destination[index] = CChar(byte) }
        destination[pathBytes.count] = 0
    }
}

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

guard connected == 0 else {
    // WorkSwitch is not running. Exiting cleanly makes Chrome report a normal disconnect,
    // and the extension's backoff will retry until the app comes up.
    log("WorkSwitch is not running (socket \(socketPath)): \(String(cString: strerror(errno)))")
    close(socketFD)
    exit(0)
}

log("connected to WorkSwitch at \(socketPath)")

// MARK: - Byte pump

/// Reads exactly `count` bytes, or returns nil at end of stream.
@Sendable func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    guard count > 0 else { return Data() }
    var buffer = Data(count: count)
    var received = 0
    while received < count {
        let result: Int = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base.advanced(by: received), count - received)
        }
        if result == 0 { return nil }
        if result < 0 {
            if errno == EINTR { continue }
            return nil
        }
        received += result
    }
    return buffer
}

@Sendable func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    while sent < data.count {
        let result: Int = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base.advanced(by: sent), data.count - sent)
        }
        if result <= 0 {
            if result < 0 && errno == EINTR { continue }
            return false
        }
        sent += result
    }
    return true
}

/// Copies length-prefixed frames from one descriptor to the other until either closes.
/// The prefix is re-emitted as-is, so no re-framing or parsing happens.
@Sendable func pump(from source: Int32, to destination: Int32, label: String) {
    while true {
        guard let header = readExactly(source, 4) else { break }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

        // Chrome's own cap is 64 MB inbound; anything larger means a desynced stream.
        guard length <= BridgeSocket.maxFrameBytes else {
            log("\(label): frame length \(length) out of range, closing")
            break
        }

        guard let body = readExactly(source, Int(length)) else { break }
        guard writeAll(destination, header), writeAll(destination, body) else { break }
    }
    log("\(label): stream closed")
}

let stdinFD = FileHandle.standardInput.fileDescriptor
let stdoutFD = FileHandle.standardOutput.fileDescriptor

// Chrome → app runs on a background thread; app → Chrome runs on the main thread. When
// either direction ends the process exits, which tears down the other side with it.
let outbound = Thread {
    pump(from: stdinFD, to: socketFD, label: "chrome→app")
    shutdown(socketFD, SHUT_WR)
    exit(0)
}
outbound.stackSize = 512 * 1024
outbound.start()

pump(from: socketFD, to: stdoutFD, label: "app→chrome")
exit(0)
