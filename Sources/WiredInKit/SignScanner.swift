import Foundation

/// A sign that answered `!info;`.
public struct ConnectedSign: Sendable, Identifiable {
    public var id: String { info.uniqueIdentifier }
    public let name: String
    public let info: SignInfo
    public let session: SignSession

    public init(name: String, info: SignInfo, session: SignSession) {
        self.name = name
        self.info = info
        self.session = session
    }
}

public enum SignScanner {
    /// Opens a port and asks it to identify. Returns nil if it isn't a sign.
    public static func probe(path: String, timeout: Duration = .milliseconds(1500)) async -> ConnectedSign? {
        guard let port = try? SerialPort(path: path) else { return nil }
        let session = SignSession(transport: port)
        do {
            let info = try await session.identify(timeout: timeout)
            return ConnectedSign(name: port.name, info: info, session: session)
        } catch {
            await session.close()
            return nil
        }
    }

    /// Probes all candidate serial ports concurrently.
    public static func scanSerialPorts(
        paths: [String] = SerialPort.candidatePaths(),
        skipping: Set<String> = [],
        timeout: Duration = .milliseconds(1500)
    ) async -> [ConnectedSign] {
        await withTaskGroup(of: ConnectedSign?.self) { group in
            for path in paths where !skipping.contains(path) {
                group.addTask { await probe(path: path, timeout: timeout) }
            }
            var signs: [ConnectedSign] = []
            for await sign in group {
                if let sign { signs.append(sign) }
            }
            return signs.sorted { $0.name < $1.name }
        }
    }
}
