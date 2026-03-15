import XCTest
@testable import MacVRHostCore
@testable import MacVRProtocol

final class WireProtocolTests: XCTestCase {
    func testHelloRoundTrip() throws {
        let message = ClientControlMessage.hello(
            HelloPayload(
                clientName: "quest-3s",
                udpVideoPort: 9944,
                requestedFPS: 72,
                requestedStreamMode: .displayJPEG
            )
        )
        let encoded = try WireCodec.encode(message)
        let decoded = try WireCodec.decode(ClientControlMessage.self, from: encoded)

        XCTAssertEqual(decoded.type, .hello)
        XCTAssertEqual(decoded.hello?.clientName, "quest-3s")
        XCTAssertEqual(decoded.hello?.udpVideoPort, 9944)
        XCTAssertEqual(decoded.hello?.requestedFPS, 72)
        XCTAssertEqual(decoded.hello?.requestedStreamMode, .displayJPEG)
    }

    func testEncodeLineAppendsNewline() throws {
        let message = ServerControlMessage.pong(PongPayload(nonce: "abc", serverTimeNs: 123))
        let encoded = try WireCodec.encodeLine(message)

        XCTAssertEqual(encoded.last, 0x0A)
    }

    func testFPSClampingAndFrameInterval() {
        XCTAssertEqual(HostConfiguration.clampFPS(0), 1)
        XCTAssertEqual(HostConfiguration.clampFPS(72), 72)
        XCTAssertEqual(HostConfiguration.clampFPS(400), 240)
        XCTAssertEqual(HostConfiguration.frameIntervalNanoseconds(targetFPS: 120), 8_333_333)
        XCTAssertEqual(HostConfiguration.clampPacketSize(100), 512)
        XCTAssertEqual(HostConfiguration.clampPacketSize(2000), 2000)
        XCTAssertEqual(HostConfiguration.clampJPEGQuality(0), 1)
        XCTAssertEqual(HostConfiguration.clampJPEGQuality(10), 10)
        XCTAssertEqual(HostConfiguration.clampJPEGQuality(120), 100)
        XCTAssertEqual(HostConfiguration.clampBridgeFrameAgeMs(-10), 0)
        XCTAssertEqual(HostConfiguration.clampBridgeFrameAgeMs(250), 250)
        XCTAssertEqual(HostConfiguration.clampBridgeFrameAgeMs(20_000), 10_000)
    }

    func testReleaseVersionMatchesVersionFile() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let versionFile = repositoryRoot.appendingPathComponent("VERSION")
        let version = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(version, macVRReleaseVersion)
    }

    func testFrameChunkPacketizeAndReassemble() throws {
        let payload = Data(repeating: 0xAB, count: 5_000)
        let packets = try FrameChunkPacketizer.packetize(
            codec: .jpeg,
            flags: 0x01,
            frameIndex: 42,
            sentTimeNs: 123_456,
            payload: payload,
            maxPacketSize: 900
        )

        XCTAssertGreaterThan(packets.count, 1)

        let reassembler = FrameReassembler()
        var reassembled: ReassembledFrame?
        for packet in packets {
            reassembled = try reassembler.ingest(packet) ?? reassembled
        }

        XCTAssertEqual(reassembled?.frameIndex, 42)
        XCTAssertEqual(reassembled?.codec, .jpeg)
        XCTAssertEqual(reassembled?.payload, payload)
    }

    func testSingleChunkFrameRoundTrip() throws {
        let payload = Data("hello".utf8)
        let packets = try FrameChunkPacketizer.packetize(
            codec: .mockJSON,
            flags: 0x00,
            frameIndex: 7,
            sentTimeNs: 999,
            payload: payload,
            maxPacketSize: 1200
        )

        XCTAssertEqual(packets.count, 1)
        let packet = try FrameChunkParser.parse(packets[0])
        XCTAssertEqual(packet.header.frameIndex, 7)
        XCTAssertEqual(packet.header.codec, .mockJSON)
        XCTAssertEqual(packet.payload, payload)
    }

    func testBridgeSubmitFrameRoundTrip() throws {
        let jpegBytes = Data(repeating: 0x42, count: 128)
        let submit = BridgeSubmitFramePayload(
            frameIndex: 12,
            sentTimeNs: 333,
            jpegBase64: jpegBytes.base64EncodedString(),
            width: 640,
            height: 360
        )
        let message = BridgeClientMessage.submitFrame(submit)

        let encoded = try WireCodec.encode(message)
        let decoded = try WireCodec.decode(BridgeClientMessage.self, from: encoded)

        XCTAssertEqual(decoded.type, .submitFrame)
        XCTAssertEqual(decoded.submitFrame?.frameIndex, 12)
        XCTAssertEqual(decoded.submitFrame?.decodeJPEGData(), jpegBytes)
        XCTAssertEqual(StreamMode.bridgeJPEG.rawValue, "bridge-jpeg")
    }

    func testBridgeWelcomeTransportRoundTrip() throws {
        let token = Data(repeating: 0x55, count: BridgeUDPPacketEnvelope.authTokenByteCount)
        let welcome = BridgeWelcomePayload(
            message: "Bridge ingest ready",
            acceptedSource: "bridge-sim",
            frameTransport: .udpChunked,
            udpIngestPort: 43000,
            maxPacketSize: 1200,
            udpAuthTokenBase64: token.base64EncodedString()
        )
        let message = BridgeServerMessage.welcome(welcome)

        let encoded = try WireCodec.encode(message)
        let decoded = try WireCodec.decode(BridgeServerMessage.self, from: encoded)

        XCTAssertEqual(decoded.type, .welcome)
        XCTAssertEqual(decoded.welcome?.acceptedSource, "bridge-sim")
        XCTAssertEqual(decoded.welcome?.frameTransport, .udpChunked)
        XCTAssertEqual(decoded.welcome?.udpIngestPort, 43000)
        XCTAssertEqual(decoded.welcome?.maxPacketSize, 1200)
        XCTAssertEqual(decoded.welcome?.udpAuthTokenBase64, token.base64EncodedString())
    }

    func testBridgeWelcomeBackCompatDefaultsToInlineTransport() throws {
        let legacyJSON = """
        {
          "type": "welcome",
          "welcome": {
            "protocolVersion": 1,
            "message": "Bridge ingest ready",
            "acceptedSource": "legacy-bridge"
          }
        }
        """.data(using: .utf8)!

        let decoded = try WireCodec.decode(BridgeServerMessage.self, from: legacyJSON)
        XCTAssertEqual(decoded.type, .welcome)
        XCTAssertEqual(decoded.welcome?.acceptedSource, "legacy-bridge")
        XCTAssertEqual(decoded.welcome?.frameTransport, .tcpInlineBase64)
        XCTAssertNil(decoded.welcome?.udpIngestPort)
        XCTAssertNil(decoded.welcome?.maxPacketSize)
        XCTAssertNil(decoded.welcome?.udpAuthTokenBase64)
    }

    func testBridgeUDPPacketEnvelopeRoundTrip() throws {
        let token = Data((0..<BridgeUDPPacketEnvelope.authTokenByteCount).map { UInt8($0) })
        let frameChunk = Data(repeating: 0xAB, count: 64)

        let wrapped = try BridgeUDPPacketEnvelope.encode(authToken: token, frameChunkPacket: frameChunk)
        let decoded = try BridgeUDPPacketEnvelope.decode(wrapped)

        XCTAssertEqual(decoded.authToken, token)
        XCTAssertEqual(decoded.frameChunkPacket, frameChunk)
    }

    func testBridgeUDPPacketEnvelopeRejectsInvalidTokenLength() {
        XCTAssertThrowsError(
            try BridgeUDPPacketEnvelope.encode(authToken: Data([0x01]), frameChunkPacket: Data([0xAA]))
        )
    }
}
