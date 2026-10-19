import Foundation

/// A POSIX serial port configured for the Wired In sign (57600 8N1, raw).
public final class SerialPort: SignTransport, @unchecked Sendable {
    public static let baudRate: speed_t = 57600

    public let path: String
    public let kind: SignTransportKind = .serial
    public let incoming: AsyncStream<Data>

    private let fd: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false

    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String) throws {
        self.path = path
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SignError.io("Could not open \(path): \(String(cString: strerror(errno)))") }

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            Darwin.close(fd)
            throw SignError.io("Could not read settings for \(path): \(String(cString: strerror(errno)))")
        }
        cfmakeraw(&options)
        cfsetspeed(&options, Self.baudRate)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            Darwin.close(fd)
            throw SignError.io("Could not configure \(path): \(String(cString: strerror(errno)))")
        }
        tcflush(fd, TCIOFLUSH)

        self.fd = fd
        self.queue = DispatchQueue(label: "WiredIn.SerialPort.\((path as NSString).lastPathComponent)")
        (incoming, continuation) = AsyncStream.makeStream()
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

        let continuation = self.continuation
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // Device unplugged.
                self?.close()
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
            continuation.finish()
        }
        source.resume()
    }

    deinit { close() }

    public func send(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw SignError.closed }
        var remaining = data[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { usleep(1000); continue }
                throw SignError.io("Write to \(path) failed: \(String(cString: strerror(errno)))")
            }
            remaining = remaining.dropFirst(written)
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        source.cancel()
    }

    /// Candidate serial devices, skipping the Bluetooth/AirPods/Wireless ports the
    /// original app ignored.
    public static func candidatePaths(in directory: String = "/dev") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { isCandidate(name: $0) }
            .sorted()
            .map { "\(directory)/\($0)" }
    }

    static func isCandidate(name: String) -> Bool {
        guard name.hasPrefix("cu.") else { return false }
        let lower = name.lowercased()
        return !["bluetooth", "airpods", "wireless", "debug-console"].contains { lower.contains($0) }
    }
}
