import Foundation
import Testing
@testable import WiredInKit

/// Simulates sign firmware: answers commands with info/status packets.
final class FakeSign: SignTransport, @unchecked Sendable {
    let kind: SignTransportKind
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private(set) var sent: [String] = []
    var silent = false
    /// Ignores this many `!mode` commands, as the real firmware sometimes does.
    var modeCommandsToDrop = 0
    var color = (0, 0, 0), on = true, brightness = 255, mode = 0

    init(kind: SignTransportKind = .serial) {
        self.kind = kind
        (incoming, continuation) = AsyncStream.makeStream()
    }

    var statusPacket: String {
        String(format: "$c:%03d,%03d,%03d/o:%d/b:%03d/m:%d;", color.0, color.1, color.2, on ? 1 : 0, brightness, mode)
    }

    func send(_ data: Data) throws {
        let command = String(decoding: data, as: UTF8.self)
        lock.withLock { sent.append(command) }
        guard !silent else { return }
        let body = command.dropFirst().dropLast()
        if body.hasPrefix("mode"), modeCommandsToDrop > 0 {
            modeCommandsToDrop -= 1
            return
        }
        var reply = statusPacket
        if body == "info" {
            reply = "$WiredIn:1.1/uid:FAKE01;"
        } else if body.hasPrefix("on") {
            on = body.hasSuffix("1")
        } else if body.hasPrefix("rgb") {
            let digits = Array(body.dropFirst(3)).map(String.init).joined()
            let n = digits.count == 12 ? String(digits.dropFirst(3)) : digits
            let v = stride(from: 0, to: 9, by: 3).map { Int(n.dropFirst($0).prefix(3))! }
            color = (v[0], v[1], v[2])
        } else if body.hasPrefix("brt") {
            brightness = Int(body.dropFirst(3))!
        } else if body.hasPrefix("mode") {
            mode = Int(body.dropFirst(4))!
        } else if body == "stat", mode == 1 {
            // The cycle moves on between polls.
            color = ((color.0 + 10) % 256, color.1, color.2)
        }
        reply = body == "info" ? reply : statusPacket
        // Deliver in two chunks to exercise framing.
        let split = reply.index(reply.startIndex, offsetBy: reply.count / 2)
        continuation.yield(Data(("\r\n" + reply[..<split]).utf8))
        continuation.yield(Data((reply[split...] + "\r\n").utf8))
    }

    /// The physical on/off button: the firmware toggles power and reports it unprompted.
    func pressButton() {
        on.toggle()
        continuation.yield(Data((statusPacket + "\0").utf8))
    }

    func close() { continuation.finish() }
}

@Suite struct SessionTests {
    @Test func identify() async throws {
        let session = SignSession(transport: FakeSign())
        let info = try await session.identify()
        #expect(info.uniqueIdentifier == "FAKE01")
        #expect(info.version == 1.1)
    }

    @Test func setCommandsReturnStatus() async throws {
        let sign = FakeSign()
        let session = SignSession(transport: sign)
        var status = try await session.setColor(SignColor(red255: 10, green255: 20, blue255: 30))
        #expect(status.color.bytes == (10, 20, 30))
        status = try await session.setPower(false)
        #expect(!status.isOn)
        status = try await session.setBrightness(0.5)
        #expect(status.brightness == 127.0 / 255)
        status = try await session.setMode(.colorCycle)
        #expect(status.mode == 1)
        #expect(sign.sent == ["!rgb010020030;", "!on0;", "!brt127;", "!mode1;"])
        #expect(await session.lastStatus == status)
    }

    @Test func timesOut() async {
        let sign = FakeSign()
        sign.silent = true
        let session = SignSession(transport: sign)
        await #expect(throws: SignError.timeout) {
            try await session.status(timeout: .milliseconds(50))
        }
    }

    @Test func identifyRetriesThenGivesUp() async {
        let sign = FakeSign()
        sign.silent = true
        let session = SignSession(transport: sign)
        await #expect(throws: SignError.notASign) {
            try await session.identify(timeout: .milliseconds(30), attempts: 2)
        }
        #expect(sign.sent == ["!info;", "!info;"])
    }

    @Test func closingFailsPendingRequests() async {
        let sign = FakeSign()
        sign.silent = true
        let session = SignSession(transport: sign)
        let pending = Task { try await session.status(timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(20))
        sign.close()
        await #expect(throws: SignError.closed) { try await pending.value }
    }

    @Test func setModeRetriesWhenIgnored() async throws {
        let sign = FakeSign()
        sign.modeCommandsToDrop = 2
        let session = SignSession(transport: sign)
        let status = try await session.setMode(.colorCycle, timeout: .milliseconds(30))
        #expect(status.mode == 1)
        #expect(sign.sent == ["!mode1;", "!mode1;", "!mode1;"])
    }

    @Test func setModeGivesUpAfterAttempts() async {
        let sign = FakeSign()
        sign.modeCommandsToDrop = 3
        let session = SignSession(transport: sign)
        await #expect(throws: SignError.timeout) {
            try await session.setMode(.solid, timeout: .milliseconds(20))
        }
        #expect(sign.sent.count == 3)
    }

    @Test func requestsWaitForThePreviousReply() async {
        let sign = FakeSign()
        sign.silent = true
        let session = SignSession(transport: sign)
        async let first = try? session.status(timeout: .milliseconds(60))
        async let second = try? session.setPower(false, timeout: .milliseconds(60))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(sign.sent.count == 1)
        _ = await (first, second)
        #expect(sign.sent.count == 2)
    }

    @Test func buttonPressIsReportedAsUnsolicited() async throws {
        let sign = FakeSign()
        let session = SignSession(transport: sign)
        var updates = session.statusUpdates.makeAsyncIterator()

        try await session.setColor(.red)
        #expect(await updates.next() == StatusUpdate(status: SignStatus(color: .red, brightness: 1, isOn: true), isUnsolicited: false))

        sign.pressButton()
        #expect(await updates.next() == StatusUpdate(status: SignStatus(color: .red, brightness: 1, isOn: false), isUnsolicited: true))
        #expect(await session.lastStatus?.isOn == false)
    }

    @Test func pollingFollowsTheColorCycle() async throws {
        let sign = FakeSign()
        let session = SignSession(transport: sign)
        try await session.setMode(.colorCycle)
        var updates = session.statusUpdates.makeAsyncIterator()
        _ = await updates.next()  // reply to !mode1;

        let poll = Task { await session.pollStatus(every: .milliseconds(5)) }
        var reds: [Int] = []
        for _ in 0..<3 {
            if let update = await updates.next() { reds.append(update.status.color.bytes.red) }
        }
        poll.cancel()
        await poll.value
        #expect(reds == [10, 20, 30])
        #expect(sign.sent.filter { $0 == "!stat;" }.count >= 3)
    }

    @Test func pollingStopsWhenSessionCloses() async {
        let session = SignSession(transport: FakeSign())
        let poll = Task { await session.pollStatus(every: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(20))
        await session.close()
        await poll.value
    }

    @Test func bluetoothDialect() async throws {
        let sign = FakeSign(kind: .bluetooth)
        let session = SignSession(transport: sign)
        try await session.setColor(.green)
        #expect(sign.sent == ["!rgb255000255000;"])
    }
}
