import Darwin
import Foundation

/// Answers one waiting permission request. Safe to call from any thread; only the first call counts.
public final class AgentResponder: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var done = false
    private var watcher: DispatchSourceRead?

    init(fd: Int32) { self.fd = fd }

    public func reply(_ reply: AgentReply?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        if let reply, let data = try? JSONEncoder().encode(reply) {
            AgentSocketIO.writeAll(fd, data + Data([0x0A]))
        }
        if let watcher {
            // The cancel handler closes the descriptor once the source has let go of it.
            watcher.cancel()
            self.watcher = nil
        } else {
            close(fd)
        }
    }

    /// Fires `onClose` if the hook process goes away first (the user answered in the terminal / T3 Code).
    func watchForHangup(on queue: DispatchQueue, onClose: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            let n = recv(self.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                self.reply(nil)
                onClose()
            }
        }
        watcher = source
        source.resume()
    }
}

/// Unix-socket server the hooks talk to. Each connection carries one JSON line; permission requests keep
/// the connection open until `AgentResponder.reply` is called.
public final class AgentSocketServer: @unchecked Sendable {
    public typealias EventHandler = @Sendable (AgentEvent, AgentResponder?) -> Void

    public let path: String
    private let onEvent: EventHandler
    private let onHangup: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "cleantrash.agents.socket", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private let lock = NSLock()

    /// - Parameters:
    ///   - onHangup: called with the request ID when a waiting hook disconnects before we answered.
    public init(path: String, onEvent: @escaping EventHandler, onHangup: @escaping @Sendable (String) -> Void = { _ in }) {
        self.path = path
        self.onEvent = onEvent
        self.onHangup = onHangup
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard var address = AgentSocketIO.address(for: path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        chmod(path, 0o600)

        lock.lock()
        listenFD = fd
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "cleantrash.agents.accept"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // listening socket closed
            }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        AgentSocketIO.configure(client, receiveTimeout: 2)
        guard let line = AgentSocketIO.readLine(client),
              let event = try? JSONDecoder.agent.decode(AgentEvent.self, from: line) else {
            close(client)
            return
        }
        guard event.awaitsDecision else {
            close(client)
            onEvent(event, nil)
            return
        }
        let responder = AgentResponder(fd: client)
        let requestID = event.requestID
        responder.watchForHangup(on: queue) { [onHangup] in onHangup(requestID) }
        onEvent(event, responder)
    }
}

/// Client side used by `cleantrash-hook`.
public enum AgentSocketClient {
    /// Sends the event; for permission requests waits up to `replyTimeout` for the user's decision.
    /// Returns nil when the app isn't running, didn't answer, or the event needs no reply.
    public static func send(_ event: AgentEvent, to path: String = AgentBridgePaths.socketPath, replyTimeout: TimeInterval) -> AgentReply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard var address = AgentSocketIO.address(for: path) else { return nil }
        AgentSocketIO.configure(fd, receiveTimeout: max(replyTimeout, 1))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, let data = try? JSONEncoder.agent.encode(event) else { return nil }
        guard AgentSocketIO.writeAll(fd, data + Data([0x0A])) else { return nil }
        guard event.awaitsDecision, replyTimeout > 0, let line = AgentSocketIO.readLine(fd) else { return nil }
        return try? JSONDecoder().decode(AgentReply.self, from: line)
    }
}

enum AgentSocketIO {
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func configure(_ fd: Int32, receiveTimeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(receiveTimeout), tv_usec: Int32((receiveTimeout - floor(receiveTimeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return false }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, pointer, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= n
                pointer = pointer.advanced(by: n)
            }
            return true
        }
    }

    /// Reads up to the first newline (or EOF), capped at 1 MB.
    static func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 1_048_576 {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return buffer.isEmpty ? nil : buffer
    }
}

extension JSONEncoder {
    static var agent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var agent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
