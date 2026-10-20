import Foundation
import Testing
@testable import WiredInKit

@Suite struct CommandEncodingTests {
    @Test func simpleCommands() {
        #expect(SignCommand.info.encoded() == "!info;")
        #expect(SignCommand.status.encoded() == "!stat;")
        #expect(SignCommand.power(true).encoded() == "!on1;")
        #expect(SignCommand.power(false).encoded() == "!on0;")
        #expect(SignCommand.mode(.solid).encoded() == "!mode0;")
        #expect(SignCommand.mode(.colorCycle).encoded() == "!mode1;")
    }

    @Test func colorIsZeroPaddedAndTruncated() {
        #expect(SignCommand.color(.red).encoded() == "!rgb255000000;")
        // 0.5 * 255 = 127.5 → truncates to 127, matching cvttsd2si in the original.
        #expect(SignCommand.color(SignColor(red: 0.5, green: 0.04, blue: 1)).encoded() == "!rgb127010255;")
    }

    @Test func bluetoothColorHasLiteral255Prefix() {
        #expect(SignCommand.color(.blue).encoded(for: .bluetooth) == "!rgb255000000255;")
    }

    @Test func brightnessIsClamped() {
        #expect(SignCommand.brightness(1).encoded() == "!brt255;")
        #expect(SignCommand.brightness(0.1).encoded() == "!brt025;")
        #expect(SignCommand.brightness(2).encoded() == "!brt255;")
        #expect(SignCommand.brightness(-1).encoded() == "!brt000;")
    }
}

@Suite struct ResponseParsingTests {
    @Test func info() {
        let info = SignInfo(response: "$WiredIn:1.2/uid:ABC123;")
        #expect(info == SignInfo(version: 1.2, uniqueIdentifier: "ABC123"))
    }

    @Test func infoRejectsOtherDevices() {
        #expect(SignInfo(response: "$Arduino:1.0/uid:X;") == nil)
        #expect(SignInfo(response: "WiredIn:1.0/uid:X") == nil)
        #expect(SignInfo(response: "$WiredIn:1.0;") == nil)
    }

    @Test func status() throws {
        let status = try #require(SignStatus(response: "$c:255,128,000/o:1/b:255/m:2;"))
        #expect(status.color.bytes == (255, 128, 0))
        #expect(status.isOn)
        #expect(status.brightness == 1)
        #expect(status.mode == 2)
    }

    @Test func statusWithoutModeOrWithExtraFields() throws {
        let s1 = try #require(SignStatus(response: "$c:0,0,255/o:0/b:051;"))
        #expect(!s1.isOn)
        #expect(s1.mode == 0)
        #expect(abs(s1.brightness - 0.2) < 0.001)

        let s2 = try #require(SignStatus(response: "$c:010,020,030/o:1/b:100/m:1/x:whatever;\r\n"))
        #expect(s2.color.bytes == (10, 20, 30))
    }

    @Test func malformedStatus() {
        #expect(SignStatus(response: "$c:1,2/o:1/b:3;") == nil)
        #expect(SignStatus(response: "$o:1/b:3/m:0;") == nil)
        #expect(SignStatus(response: "garbage") == nil)
    }

    @Test func responseClassification() {
        #expect(SignResponse("$WiredIn:1/uid:a;") == .info(SignInfo(version: 1, uniqueIdentifier: "a")))
        #expect(SignResponse("$nope;") == .unknown("$nope;"))
    }
}

@Suite struct FramerTests {
    @Test func splitsAcrossChunks() {
        var framer = PacketFramer()
        #expect(framer.append(Data("noise$WiredIn:1.0/u".utf8)).isEmpty)
        #expect(framer.append(Data("id:X;$c:1,2,3/o:1/b:4;\r\n".utf8)) == ["$WiredIn:1.0/uid:X;", "$c:1,2,3/o:1/b:4;"])
    }

    @Test func restartsOnNewDollar() {
        var framer = PacketFramer()
        #expect(framer.append(Data("$broken$c:1,2,3/o:1/b:4;".utf8)) == ["$c:1,2,3/o:1/b:4;"])
    }

    @Test func dropsOverlongPackets() {
        var framer = PacketFramer()
        let long = "$" + String(repeating: "a", count: 200) + ";"
        #expect(framer.append(Data(long.utf8)).isEmpty)
    }
}

/// Bytes captured from a real sign (firmware 0.4) on 2026-10-19.
@Suite struct HardwareCaptureTests {
    static let info = Data("$WiredIn:0.4/uid:2938475202;\0".utf8)
    static let status = Data("$c: 255, 000, 000/o: 1/b: 255/m: 0;\0".utf8)

    @Test func parsesCapturedPackets() throws {
        var framer = PacketFramer()
        let packets = framer.append(Self.info + Self.status)
        #expect(packets.count == 2)
        #expect(SignResponse(packets[0]) == .info(SignInfo(version: 0.4, uniqueIdentifier: "2938475202")))
        let status = try #require(SignStatus(response: packets[1]))
        #expect(status == SignStatus(color: .red, brightness: 1, isOn: true, mode: 0))
    }

    /// Unprompted packets sent while the sign's button was pressed (off, then on).
    @Test func parsesCapturedButtonPresses() throws {
        var framer = PacketFramer()
        let packets = framer.append(Data("$c: 255, 000, 000/o: 0/b: 255/m: 0;\0$c: 255, 000, 000/o: 1/b: 255/m: 0;\0".utf8))
        #expect(packets.compactMap { SignStatus(response: $0)?.isOn } == [false, true])
    }

    @Test func capturedStatusLengthMatchesOriginalMatcher() {
        // The 2018 app only accepted status packets of 34–35 bytes; the NUL is outside the packet.
        #expect(Self.status.count - 1 == 35)
    }
}

@Suite struct ColorTests {
    @Test func hexRoundTrip() {
        #expect(SignColor(hex: "#FF8000")?.hex == "#FF8000")
        #expect(SignColor(hex: "00ff00") == .green)
        #expect(SignColor(hex: "nope") == nil)
    }
}

@Suite struct SerialPortTests {
    @Test func candidateFiltering() {
        #expect(SerialPort.isCandidate(name: "cu.usbmodem14101"))
        #expect(SerialPort.isCandidate(name: "cu.usbserial-A10"))
        #expect(!SerialPort.isCandidate(name: "tty.usbmodem14101"))
        #expect(!SerialPort.isCandidate(name: "cu.Bluetooth-Incoming-Port"))
        #expect(!SerialPort.isCandidate(name: "cu.AirPods"))
        #expect(!SerialPort.isCandidate(name: "cu.debug-console"))
    }
}
