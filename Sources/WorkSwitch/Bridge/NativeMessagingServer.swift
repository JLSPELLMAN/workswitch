import BridgeShared
import Foundation

/// Unix domain socket server that accepts connections from the native messaging relay.
///
/// One connection per Chrome profile: Chrome launches a separate host process for each
/// profile running the extension, so simultaneous connections are the mechanism by which
/// multiple profiles are supported. Tab and window IDs are only unique *within* a profile,
/// which is why every connection gets its own namespace.
final class NativeMessagingServer {

    struct ConnectionID: Hashable {
        let value: Int
    }

    /// Callbacks are delivered on the main queue.
    var onConnect: ((ConnectionID) -> Void)?
    var onDisconnect: ((ConnectionID) -> Void)?
    var onMessage: ((ConnectionID, BridgeProtocol.Inbound) -> Void)?

    private let socketPath = BridgeSocket.defaultPath
    private var listenFD: Int32 = -1
    private var nextConnectionID = 1
    private var connections: [ConnectionID: Int32] = [:]

    private let queue = DispatchQueue(label: "com.lorenzospellman.workswitch.bridge")
    private let lock = NSLock()

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: BridgeSocket.supportDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[WorkSwitch] Bridge: cannot create support directory: \(error)")
            return
        }

        // A socket file left behind by a crash would make bind() fail with EADDRINUSE.
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("[WorkSwitch] Bridge: socket() failed: \(errnoText())")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            NSLog("[WorkSwitch] Bridge: socket path too long: \(socketPath)")
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { destination in
                for (index, byte) in pathBytes.enumerated() { destination[index] = CChar(byte) }
                destination[pathBytes.count] = 0
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            NSLog("[WorkSwitch] Bridge: bind() failed: \(errnoText())")
            close(listenFD)
            listenFD = -1
            return
        }

        // Only this user's processes may connect.
        chmod(socketPath, 0o600)

        guard listen(listenFD, 8) == 0 else {
            NSLog("[WorkSwitch] Bridge: listen() failed: \(errnoText())")
            close(listenFD)
            listenFD = -1
            return
        }

        NSLog("[WorkSwitch] Bridge listening at \(socketPath)")
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        let openConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()

        for fd in openConnections { close(fd) }
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(socketPath)
    }

    // MARK: - Accept

    private func acceptLoop() {
        while listenFD >= 0 {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            lock.lock()
            let id = ConnectionID(value: nextConnectionID)
            nextConnectionID += 1
            connections[id] = clientFD
            lock.unlock()

            NSLog("[WorkSwitch] Bridge: extension connected (connection \(id.value))")
            DispatchQueue.main.async { [weak self] in self?.onConnect?(id) }

            // One reader thread per connection. There are at most a handful (one per Chrome
            // profile), and a blocking read per connection is far simpler than multiplexing.
            let thread = Thread { [weak self] in self?.readLoop(id: id, fd: clientFD) }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    // MARK: - Read

    private func readLoop(id: ConnectionID, fd: Int32) {
        while true {
            guard let header = readExactly(fd, 4) else { break }
            let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard length > 0, length <= BridgeSocket.maxFrameBytes else {
                NSLog("[WorkSwitch] Bridge: bad frame length \(length), dropping connection")
                break
            }
            guard let body = readExactly(fd, Int(length)) else { break }

            do {
                let message = try BridgeProtocol.Inbound.decode(body)
                DispatchQueue.main.async { [weak self] in self?.onMessage?(id, message) }
            } catch {
                NSLog("[WorkSwitch] Bridge: undecodable message: \(error)")
            }
        }

        lock.lock()
        connections[id] = nil
        lock.unlock()
        close(fd)

        NSLog("[WorkSwitch] Bridge: extension disconnected (connection \(id.value))")
        DispatchQueue.main.async { [weak self] in self?.onDisconnect?(id) }
    }

    // MARK: - Send

    func send(_ message: BridgeProtocol.Outbound, to id: ConnectionID) -> Bool {
        lock.lock()
        let fd = connections[id]
        lock.unlock()
        guard let fd else { return false }

        do {
            let body = try JSONEncoder().encode(message)
            var length = UInt32(body.count)
            var frame = Data(bytes: &length, count: 4)
            frame.append(body)
            return writeAll(fd, frame)
        } catch {
            NSLog("[WorkSwitch] Bridge: encode failed: \(error)")
            return false
        }
    }

    // MARK: - Socket helpers

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
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

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
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

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
