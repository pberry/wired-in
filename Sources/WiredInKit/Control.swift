import Foundation

/// A command the `wired` CLI asks the running app to perform.
public enum ControlRequest: Codable, Equatable, Sendable {
    case list
    case status
    case power(Bool)
    case color(SignColor)
    /// 0.0–1.0
    case brightness(Double)
    case mode(SignMode)
    /// Name, emoji or hex color, as accepted by `Preset.find`.
    case preset(String)
}

/// One sign as reported back to the CLI.
public struct SignReport: Codable, Equatable, Sendable {
    public var name: String
    public var id: String
    public var firmware: Double
    /// Nil if the sign didn't answer.
    public var status: SignStatus?

    public init(name: String, id: String, firmware: Double, status: SignStatus?) {
        self.name = name
        self.id = id
        self.firmware = firmware
        self.status = status
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var signs: [SignReport]
    public var error: String?

    public init(signs: [SignReport] = [], error: String? = nil) {
        self.signs = signs
        self.error = error
    }
}

/// Where the app listens for CLI requests.
public enum ControlSocket {
    public static var defaultPath: String {
        PresetStore.defaultURL.deletingLastPathComponent().appending(path: "control.sock").path
    }

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SignError.io("Socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Reads until a newline or EOF.
    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
            if let newline = data.firstIndex(of: UInt8(ascii: "\n")) { return data[..<newline] }
        }
        return data.isEmpty ? nil : data
    }

    static func writeLine(_ fd: Int32, _ data: Data) -> Bool {
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        var remaining = payload[...]
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            remaining = remaining.dropFirst(n)
        }
        return true
    }
}

/// Serves `ControlRequest`s on a Unix domain socket: one JSON request line and one
/// JSON response line per connection.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public let path: String
    private let fd: Int32
    private let source: DispatchSourceRead

    public init(path: String = ControlSocket.defaultPath, handler: @escaping Handler) throws {
        self.path = path
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var address = try ControlSocket.address(for: path)
        // A socket file left by a crashed app would make bind fail.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SignError.io("socket: \(String(cString: strerror(errno)))") }
        let bound = ControlSocket.withSockaddr(&address) { bind(fd, $0, $1) }
        guard bound == 0, listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw SignError.io("Could not listen on \(path): \(message)")
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "WiredIn.ControlServer"))
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            Task.detached {
                defer { Darwin.close(client) }
                let response: ControlResponse
                if let line = ControlSocket.readLine(client),
                   let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                    response = await handler(request)
                } else {
                    response = ControlResponse(error: "Malformed request")
                }
                if let data = try? JSONEncoder().encode(response) { _ = ControlSocket.writeLine(client, data) }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    deinit { stop() }

    public func stop() {
        guard !source.isCancelled else { return }
        source.cancel()
        unlink(path)
    }
}

public enum ControlClient {
    /// Sends a request to the running app. Throws `SignError.closed` if no app is listening.
    public static func send(
        _ request: ControlRequest, path: String = ControlSocket.defaultPath, timeout: TimeInterval = 10
    ) throws -> ControlResponse {
        var address = try ControlSocket.address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SignError.io("socket: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // ENOENT (no socket) or ECONNREFUSED (stale socket): the app isn't running.
        guard ControlSocket.withSockaddr(&address, { connect(fd, $0, $1) }) == 0 else { throw SignError.closed }
        guard ControlSocket.writeLine(fd, try JSONEncoder().encode(request)) else { throw SignError.closed }
        guard let line = ControlSocket.readLine(fd) else { throw SignError.timeout }
        return try JSONDecoder().decode(ControlResponse.self, from: line)
    }
}
