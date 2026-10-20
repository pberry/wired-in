import Foundation

/// A byte pipe to a sign: serial port, BLE peripheral, or a test double.
public protocol SignTransport: AnyObject, Sendable {
    var kind: SignTransportKind { get }
    /// Bytes received from the sign, in order. Finishes when the transport closes.
    var incoming: AsyncStream<Data> { get }
    func send(_ data: Data) throws
    func close()
}

public enum SignError: Error, Equatable, LocalizedError {
    case timeout
    case notASign
    case closed
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: "The sign did not respond in time."
        case .notASign: "The device did not identify as a Wired In sign."
        case .closed: "The connection to the sign is closed."
        case .io(let message): message
        }
    }
}

/// A status packet, and whether the sign sent it on its own.
public struct StatusUpdate: Equatable, Sendable {
    public var status: SignStatus
    /// True when no request was waiting for it, e.g. the sign's own on/off
    /// button was pressed.
    public var isUnsolicited: Bool

    public init(status: SignStatus, isUnsolicited: Bool) {
        self.status = status
        self.isUnsolicited = isUnsolicited
    }
}

/// Request/response conversation with one sign.
///
/// Every set-command is answered with a status packet, and the sign also sends
/// one by itself when its button is pressed. The latest status is tracked here
/// and every packet is published through `statusUpdates`.
public actor SignSession {
    public nonisolated let transport: SignTransport
    public private(set) var info: SignInfo?
    public private(set) var lastStatus: SignStatus?
    public nonisolated let statusUpdates: AsyncStream<StatusUpdate>

    private enum Expecting { case info, status }
    private struct Waiter {
        let id: UUID
        let expecting: Expecting
        let continuation: CheckedContinuation<SignResponse, Error>
    }

    private var waiters: [Waiter] = []
    private var framer = PacketFramer()
    private var readerTask: Task<Void, Never>?
    private var isClosed = false
    private let statusContinuation: AsyncStream<StatusUpdate>.Continuation

    public init(transport: SignTransport) {
        self.transport = transport
        (statusUpdates, statusContinuation) = AsyncStream.makeStream()
    }

    deinit {
        readerTask?.cancel()
        statusContinuation.finish()
    }

    /// Begins reading from the transport. Called automatically by the first request.
    public func start() {
        guard readerTask == nil, !isClosed else { return }
        let stream = transport.incoming
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.ingest(chunk)
            }
            await self?.transportEnded()
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        transport.close()
        failAll(SignError.closed)
        statusContinuation.finish()
    }

    /// Sends `!info;` and waits for the identification packet. Retries once,
    /// because many USB serial boards reboot when the port is opened.
    @discardableResult
    public func identify(timeout: Duration = .milliseconds(1500), attempts: Int = 2) async throws -> SignInfo {
        for _ in 0..<max(attempts, 1) {
            do {
                guard case .info(let info) = try await request(.info, expecting: .info, timeout: timeout) else {
                    throw SignError.notASign
                }
                self.info = info
                return info
            } catch SignError.timeout {
                continue
            }
        }
        throw SignError.notASign
    }

    @discardableResult
    public func status(timeout: Duration = .milliseconds(500)) async throws -> SignStatus {
        try await statusRequest(.status, timeout: timeout)
    }

    @discardableResult
    public func setPower(_ on: Bool, timeout: Duration = .milliseconds(500)) async throws -> SignStatus {
        try await statusRequest(.power(on), timeout: timeout)
    }

    @discardableResult
    public func setColor(_ color: SignColor, timeout: Duration = .milliseconds(500)) async throws -> SignStatus {
        try await statusRequest(.color(color), timeout: timeout)
    }

    @discardableResult
    public func setBrightness(_ value: Double, timeout: Duration = .milliseconds(500)) async throws -> SignStatus {
        try await statusRequest(.brightness(value), timeout: timeout)
    }

    @discardableResult
    public func setMode(_ mode: SignMode, timeout: Duration = .milliseconds(500)) async throws -> SignStatus {
        try await statusRequest(.mode(mode), timeout: timeout)
    }

    /// Fires a command without waiting for the reply (BLE writes are not acknowledged).
    public func send(_ command: SignCommand) throws {
        guard !isClosed else { throw SignError.closed }
        start()
        try transport.send(command.data(for: transport.kind))
    }

    // MARK: - Internals

    private func statusRequest(_ command: SignCommand, timeout: Duration) async throws -> SignStatus {
        guard case .status(let status) = try await request(command, expecting: .status, timeout: timeout) else {
            throw SignError.timeout
        }
        return status
    }

    private func request(_ command: SignCommand, expecting: Expecting, timeout: Duration) async throws -> SignResponse {
        guard !isClosed else { throw SignError.closed }
        start()
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, expecting: expecting, continuation: continuation))
            do {
                try transport.send(command.data(for: transport.kind))
            } catch {
                resume(id: id, with: .failure(error))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resume(id: id, with: .failure(SignError.timeout))
            }
        }
    }

    private func resume(id: UUID, with result: Result<SignResponse, Error>) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(with: result)
    }

    private func ingest(_ data: Data) {
        for packet in framer.append(data) {
            let response = SignResponse(packet)
            let expecting: Expecting
            switch response {
            case .info: expecting = .info
            case .status: expecting = .status
            case .unknown: continue
            }
            let waiter = waiters.firstIndex { $0.expecting == expecting }.map { waiters.remove(at: $0) }
            if case .status(let status) = response {
                lastStatus = status
                statusContinuation.yield(StatusUpdate(status: status, isUnsolicited: waiter == nil))
            }
            waiter?.continuation.resume(returning: response)
        }
    }

    private func transportEnded() {
        isClosed = true
        failAll(SignError.closed)
        statusContinuation.finish()
    }

    private func failAll(_ error: Error) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }
}
