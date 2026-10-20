import Foundation
import Testing
@testable import WiredInKit

@Suite struct ControlTests {
    /// Unix socket paths are limited to 104 bytes, so keep them short.
    func socketPath() -> String { "/tmp/wiredin-test-\(UUID().uuidString.prefix(8)).sock" }

    let report = SignReport(
        name: "cu.usbserial-TEST", id: "2938475202", firmware: 0.4,
        status: SignStatus(color: .red, brightness: 1, isOn: true))

    @Test func roundTrip() async throws {
        let path = socketPath()
        let server = try ControlServer(path: path) { [report] request in
            guard case .color(let color) = request else { return ControlResponse(error: "unexpected \(request)") }
            var r = report
            r.status?.color = color
            return ControlResponse(signs: [r])
        }
        defer { server.stop() }

        let response = try await Task.detached { try ControlClient.send(.color(.blue), path: path) }.value
        #expect(response.error == nil)
        #expect(response.signs.first?.status?.color == .blue)
        #expect(response.signs.first?.id == "2938475202")
    }

    @Test func handlerErrorsReachTheClient() async throws {
        let path = socketPath()
        let server = try ControlServer(path: path) { _ in ControlResponse(error: "No preset") }
        defer { server.stop() }
        let response = try await Task.detached { try ControlClient.send(.preset("nope"), path: path) }.value
        #expect(response == ControlResponse(error: "No preset"))
    }

    @Test func noAppRunning() {
        #expect(throws: SignError.closed) { try ControlClient.send(.list, path: socketPath()) }
    }

    @Test func staleSocketFromCrashedApp() throws {
        let path = socketPath()
        // Bind a socket, then close it without unlinking: connect gets ECONNREFUSED.
        var address = try ControlSocket.address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = ControlSocket.withSockaddr(&address) { bind(fd, $0, $1) }
        close(fd)
        defer { unlink(path) }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(throws: SignError.closed) { try ControlClient.send(.list, path: path) }

        // A new server replaces the stale file.
        let server = try ControlServer(path: path) { _ in ControlResponse() }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func malformedRequest() async throws {
        let path = socketPath()
        let server = try ControlServer(path: path) { _ in ControlResponse() }
        defer { server.stop() }
        let reply = try await Task.detached { () throws -> String in
            var address = try ControlSocket.address(for: path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            _ = ControlSocket.withSockaddr(&address) { connect(fd, $0, $1) }
            _ = ControlSocket.writeLine(fd, Data("not json".utf8))
            return String(decoding: ControlSocket.readLine(fd) ?? Data(), as: UTF8.self)
        }.value
        #expect(reply.contains("Malformed request"))
    }

    @Test func requestsSurviveJSON() throws {
        let requests: [ControlRequest] = [
            .list, .status, .power(false), .color(.green), .brightness(0.4), .mode(.colorCycle), .preset("Wired In"),
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        }
    }
}
