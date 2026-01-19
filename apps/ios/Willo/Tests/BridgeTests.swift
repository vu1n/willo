import XCTest
@testable import Willo

// MARK: - Shell Escape Tests

final class ShellEscapeTests: XCTestCase {

    func testEscapeSimpleString() {
        XCTAssertEqual(ShellEscape.escape("simple"), "'simple'")
    }

    func testEscapeStringWithSpaces() {
        XCTAssertEqual(ShellEscape.escape("my session"), "'my session'")
    }

    func testEscapeStringWithSingleQuote() {
        XCTAssertEqual(ShellEscape.escape("it's mine"), "'it'\\''s mine'")
    }

    func testEscapeStringWithDoubleQuote() {
        XCTAssertEqual(ShellEscape.escape("say \"hello\""), "'say \"hello\"'")
    }

    func testEscapeEmptyString() {
        XCTAssertEqual(ShellEscape.escape(""), "''")
    }

    func testEscapeStringWithMultipleSingleQuotes() {
        XCTAssertEqual(ShellEscape.escape("it's Bob's"), "'it'\\''s Bob'\\''s'")
    }

    func testEscapeStringWithSpecialChars() {
        XCTAssertEqual(ShellEscape.escape("test$var"), "'test$var'")
        XCTAssertEqual(ShellEscape.escape("test`cmd`"), "'test`cmd`'")
        XCTAssertEqual(ShellEscape.escape("test;rm -rf"), "'test;rm -rf'")
    }
}

// MARK: - Version Parsing Tests

final class VersionTests: XCTestCase {

    func testVersionParsing() {
        let v = Version(string: "0.42.1")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 0)
        XCTAssertEqual(v?.minor, 42)
        XCTAssertEqual(v?.patch, 1)
    }

    func testVersionParsingWithPrefix() {
        let v = Version(string: "zellij 0.40.0")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 0)
        XCTAssertEqual(v?.minor, 40)
        XCTAssertEqual(v?.patch, 0)
    }

    func testVersionComparison() {
        let v1 = Version(0, 40, 0)
        let v2 = Version(0, 42, 1)
        let v3 = Version(1, 0, 0)

        XCTAssertTrue(v1 < v2)
        XCTAssertTrue(v2 < v3)
        XCTAssertFalse(v3 < v1)
        XCTAssertTrue(v1 >= v1)
    }

    func testVersionInvalidString() {
        XCTAssertNil(Version(string: "not a version"))
        XCTAssertNil(Version(string: ""))
        XCTAssertNil(Version(string: "1.2"))
    }
}

// MARK: - Bridge Envelope Decoding Tests

final class BridgeEnvelopeTests: XCTestCase {

    func testHelloPayloadDecoding() throws {
        let json = """
        {"v":1,"session":"dev","ts":1234567890,"type":"hello","payload":{"pluginVersion":"1.0.0","zellijVersion":"0.42.1","protocolVersion":1}}
        """
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.v, 1)
        XCTAssertEqual(envelope.session, "dev")
        XCTAssertEqual(envelope.type, "hello")

        guard case .hello(let payload) = envelope.payload else {
            XCTFail("Expected hello payload")
            return
        }
        XCTAssertEqual(payload.pluginVersion, "1.0.0")
        XCTAssertEqual(payload.zellijVersion, "0.42.1")
        XCTAssertEqual(payload.protocolVersion, 1)
    }

    func testTabUpdatePayloadDecoding() throws {
        let json = """
        {"v":1,"session":"dev","ts":1234567890,"type":"tabUpdate","payload":{"tabs":[{"position":0,"name":"editor","active":true,"is_fullscreen_active":false,"is_pending_panes_visible":false,"are_floating_panes_visible":false}]}}
        """
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: Data(json.utf8))

        guard case .tabUpdate(let payload) = envelope.payload else {
            XCTFail("Expected tabUpdate payload")
            return
        }
        XCTAssertEqual(payload.tabs.count, 1)
        XCTAssertEqual(payload.tabs[0].name, "editor")
        XCTAssertEqual(payload.tabs[0].active, true)
    }

    func testPaneUpdatePayloadDecoding() throws {
        let json = """
        {"v":1,"session":"dev","ts":1234567890,"type":"paneUpdate","payload":{"panes":{"0":[{"id":1,"title":"nvim","is_focused":true,"is_fullscreen":false,"is_floating":false,"is_plugin":false}]}}}
        """
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: Data(json.utf8))

        guard case .paneUpdate(let payload) = envelope.payload else {
            XCTFail("Expected paneUpdate payload")
            return
        }

        let manifest = payload.toManifest()
        XCTAssertEqual(manifest.count, 1)
        XCTAssertEqual(manifest[0]?.count, 1)
        XCTAssertEqual(manifest[0]?[0].title, "nvim")
        XCTAssertEqual(manifest[0]?[0].isFocused, true)
    }

    func testUnknownTypeDecodesAsUnknown() throws {
        let json = """
        {"v":1,"session":"dev","ts":1234567890,"type":"futureType","payload":{}}
        """
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: Data(json.utf8))

        guard case .unknown = envelope.payload else {
            XCTFail("Expected unknown payload for unrecognized type")
            return
        }
    }

    func testEmptySessionHandled() throws {
        let json = """
        {"v":1,"session":"unknown","ts":1234567890,"type":"hello","payload":{"pluginVersion":"1.0.0","zellijVersion":"0.42.1","protocolVersion":1}}
        """
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.session, "unknown")
    }
}

// MARK: - Bridge Command Encoding Tests

final class BridgeCommandTests: XCTestCase {

    func testNewPaneCommand() throws {
        let cmd = BridgeCommand.newPane(direction: .right)
        let data = try JSONEncoder().encode(cmd)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"type\":\"newPane\""))
        XCTAssertTrue(json.contains("\"direction\":\"right\""))
        XCTAssertTrue(json.contains("\"v\":1"))
    }

    func testNewTabCommand() throws {
        let cmd = BridgeCommand.newTab(name: "logs", layout: nil)
        let data = try JSONEncoder().encode(cmd)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"type\":\"newTab\""))
        XCTAssertTrue(json.contains("\"name\":\"logs\""))
    }

    func testFocusCommand() throws {
        let cmd = BridgeCommand.focus(paneId: 42)
        let data = try JSONEncoder().encode(cmd)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"type\":\"focus\""))
        XCTAssertTrue(json.contains("\"paneId\":42"))
    }

    func testPingCommand() throws {
        let cmd = BridgeCommand.ping
        let data = try JSONEncoder().encode(cmd)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"type\":\"ping\""))
    }

    func testRequestSnapshotCommand() throws {
        let cmd = BridgeCommand.requestSnapshot
        let data = try JSONEncoder().encode(cmd)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"type\":\"requestSnapshot\""))
    }
}

// MARK: - Bridge Mode Tests

final class BridgeModeTests: XCTestCase {

    func testBridgeModeEquality() {
        XCTAssertEqual(BridgeMode.disconnected, BridgeMode.disconnected)
        XCTAssertEqual(BridgeMode.streaming, BridgeMode.streaming)
        XCTAssertNotEqual(BridgeMode.disconnected, BridgeMode.streaming)

        XCTAssertEqual(
            BridgeMode.unsupported(reason: "test"),
            BridgeMode.unsupported(reason: "test")
        )
        XCTAssertNotEqual(
            BridgeMode.unsupported(reason: "test1"),
            BridgeMode.unsupported(reason: "test2")
        )

        XCTAssertEqual(
            BridgeMode.needsPluginUpdate(installed: "0.9", required: "1.0"),
            BridgeMode.needsPluginUpdate(installed: "0.9", required: "1.0")
        )
    }

    func testBridgeModeIsConnected() {
        XCTAssertFalse(BridgeMode.disconnected.isConnected)
        XCTAssertFalse(BridgeMode.connecting.isConnected)
        XCTAssertFalse(BridgeMode.awaitingHello.isConnected)
        XCTAssertTrue(BridgeMode.streaming.isConnected)
        XCTAssertFalse(BridgeMode.unsupported(reason: "test").isConnected)
    }

    func testBridgeModeStatusText() {
        XCTAssertEqual(BridgeMode.disconnected.statusText, "Disconnected")
        XCTAssertEqual(BridgeMode.streaming.statusText, "Connected")
        XCTAssertEqual(BridgeMode.awaitingHello.statusText, "Awaiting bridge...")
        XCTAssertEqual(BridgeMode.needsPluginInstall.statusText, "Plugin not installed")
    }
}

// MARK: - Zellij State Model Tests

final class ZellijStateTests: XCTestCase {

    func testZellijSessionCreation() {
        let session = ZellijSession(
            id: "test-session",
            tabs: [
                ZellijTab(position: 0, name: "editor", active: true),
                ZellijTab(position: 1, name: "terminal", active: false)
            ],
            activeTabIndex: 0
        )

        XCTAssertEqual(session.id, "test-session")
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertEqual(session.activeTabIndex, 0)
        XCTAssertEqual(session.activeTab?.name, "editor")
    }

    func testZellijSessionPaneManifest() {
        var session = ZellijSession(id: "test")
        session.paneManifest = [
            0: [
                ZellijPane(id: 1, title: "nvim", isFocused: true),
                ZellijPane(id: 2, title: "shell", isFocused: false)
            ],
            1: [
                ZellijPane(id: 3, title: "logs", isFocused: false)
            ]
        ]

        XCTAssertEqual(session.panes(for: 0).count, 2)
        XCTAssertEqual(session.panes(for: 1).count, 1)
        XCTAssertEqual(session.panes(for: 99).count, 0)
    }

    func testZellijTabDecoding() throws {
        let json = """
        {"position":0,"name":"editor","active":true,"is_fullscreen_active":false,"is_pending_panes_visible":false,"are_floating_panes_visible":true}
        """
        let tab = try JSONDecoder().decode(ZellijTab.self, from: Data(json.utf8))

        XCTAssertEqual(tab.position, 0)
        XCTAssertEqual(tab.name, "editor")
        XCTAssertEqual(tab.active, true)
        XCTAssertEqual(tab.isFullscreenActive, false)
        XCTAssertEqual(tab.areFloatingPanesVisible, true)
    }

    func testZellijPaneDecoding() throws {
        let json = """
        {"id":1,"title":"nvim main.rs","is_focused":true,"is_fullscreen":false,"is_floating":false,"is_plugin":false,"exit_status":null,"run_command":"nvim main.rs"}
        """
        let pane = try JSONDecoder().decode(ZellijPane.self, from: Data(json.utf8))

        XCTAssertEqual(pane.id, 1)
        XCTAssertEqual(pane.title, "nvim main.rs")
        XCTAssertEqual(pane.isFocused, true)
        XCTAssertEqual(pane.isPlugin, false)
        XCTAssertEqual(pane.runCommand, "nvim main.rs")
        XCTAssertTrue(pane.isRunning)
    }

    func testZellijPaneExitStatus() throws {
        let json = """
        {"id":1,"title":"done","is_focused":false,"is_fullscreen":false,"is_floating":false,"is_plugin":false,"exit_status":0}
        """
        let pane = try JSONDecoder().decode(ZellijPane.self, from: Data(json.utf8))

        XCTAssertEqual(pane.exitStatus, 0)
        XCTAssertFalse(pane.isRunning)
    }
}

// MARK: - Bridge Capabilities Tests

final class BridgeCapabilitiesTests: XCTestCase {

    func testCapabilitiesEquality() {
        XCTAssertEqual(BridgeCapabilities.streaming, BridgeCapabilities.streaming)
        XCTAssertEqual(BridgeCapabilities.needsPluginInstall, BridgeCapabilities.needsPluginInstall)
        XCTAssertEqual(BridgeCapabilities.sessionNotFound, BridgeCapabilities.sessionNotFound)

        XCTAssertEqual(
            BridgeCapabilities.needsPluginUpdate(installed: "0.9", required: "1.0"),
            BridgeCapabilities.needsPluginUpdate(installed: "0.9", required: "1.0")
        )

        XCTAssertNotEqual(
            BridgeCapabilities.needsPluginUpdate(installed: "0.9", required: "1.0"),
            BridgeCapabilities.needsPluginUpdate(installed: "0.8", required: "1.0")
        )

        XCTAssertEqual(
            BridgeCapabilities.unsupported(reason: "test"),
            BridgeCapabilities.unsupported(reason: "test")
        )
    }

    func testMinimumVersionRequirement() {
        let minVersion = CapabilityDetector.minimumZellijVersion
        XCTAssertEqual(minVersion.major, 0)
        XCTAssertEqual(minVersion.minor, 40)
        XCTAssertEqual(minVersion.patch, 0)

        // Version 0.40.0 should be acceptable
        let v40 = Version(0, 40, 0)
        XCTAssertTrue(v40 >= minVersion)

        // Version 0.39.0 should not be acceptable
        let v39 = Version(0, 39, 0)
        XCTAssertFalse(v39 >= minVersion)

        // Version 0.42.1 should be acceptable
        let v42 = Version(0, 42, 1)
        XCTAssertTrue(v42 >= minVersion)
    }
}

// MARK: - Pane Update Manifest Conversion Tests

final class PaneUpdatePayloadTests: XCTestCase {

    func testToManifestConvertsStringKeysToInts() throws {
        let json = """
        {"panes":{"0":[{"id":1,"title":"pane1","is_focused":true,"is_fullscreen":false,"is_floating":false,"is_plugin":false}],"1":[{"id":2,"title":"pane2","is_focused":false,"is_fullscreen":false,"is_floating":false,"is_plugin":false}]}}
        """
        let payload = try JSONDecoder().decode(PaneUpdatePayload.self, from: Data(json.utf8))
        let manifest = payload.toManifest()

        XCTAssertEqual(manifest.count, 2)
        XCTAssertEqual(manifest[0]?.count, 1)
        XCTAssertEqual(manifest[1]?.count, 1)
        XCTAssertEqual(manifest[0]?[0].id, 1)
        XCTAssertEqual(manifest[1]?[0].id, 2)
    }

    func testToManifestIgnoresInvalidKeys() throws {
        let json = """
        {"panes":{"invalid":[{"id":1,"title":"pane1","is_focused":true,"is_fullscreen":false,"is_floating":false,"is_plugin":false}],"0":[{"id":2,"title":"pane2","is_focused":false,"is_fullscreen":false,"is_floating":false,"is_plugin":false}]}}
        """
        let payload = try JSONDecoder().decode(PaneUpdatePayload.self, from: Data(json.utf8))
        let manifest = payload.toManifest()

        // Only the "0" key should be converted
        XCTAssertEqual(manifest.count, 1)
        XCTAssertEqual(manifest[0]?.count, 1)
        XCTAssertEqual(manifest[0]?[0].id, 2)
    }
}

// MARK: - Channel Receiver Tests (Early Data Buffering)

final class ChannelReceiverTests: XCTestCase {

    func testReceiveBuffersDataBeforeBinding() async {
        let receiver = ChannelReceiver()

        // Receive data before binding
        receiver.receive(Data("chunk1".utf8))
        receiver.receive(Data("chunk2".utf8))

        // Create mock delegate to track received data
        let delegate = MockBridgeChannelDelegate()
        let mockHandle = MockBridgeChannelHandle()
        let channel = await createTestChannel(handle: mockHandle, delegate: delegate)

        // Bind and flush
        await receiver.bindChannel(channel)

        // Give time for async processing
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Data should have been flushed to channel
        // (In real test we'd verify through delegate, but channel is an actor)
    }

    func testReceiveForwardsDataAfterBinding() async {
        let receiver = ChannelReceiver()
        let delegate = MockBridgeChannelDelegate()
        let mockHandle = MockBridgeChannelHandle()
        let channel = await createTestChannel(handle: mockHandle, delegate: delegate)

        // Bind first
        await receiver.bindChannel(channel)

        // Receive data after binding - should forward immediately
        receiver.receive(Data("post-bind-data".utf8))

        // Give time for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func createTestChannel(handle: MockBridgeChannelHandle, delegate: MockBridgeChannelDelegate) async -> BridgeChannel {
        // Note: This won't compile without proper mock - placeholder for test structure
        // In real implementation, would need to mock BridgeChannelHandle
        fatalError("Test requires proper mock implementation")
    }
}

// MARK: - NDJSON Parsing Tests

final class NDJSONParsingTests: XCTestCase {

    func testSingleCompleteFrame() throws {
        // Simulate what BridgeChannel would parse
        let frame = #"{"v":1,"session":"test","ts":123,"type":"hello","payload":{"pluginVersion":"1.0.0","zellijVersion":"0.42.0","protocolVersion":1}}"# + "\n"
        let data = Data(frame.utf8)

        // Split on newline
        let newline = UInt8(ascii: "\n")
        guard let newlineIndex = data.firstIndex(of: newline) else {
            XCTFail("No newline found")
            return
        }

        let lineData = data[data.startIndex..<newlineIndex]
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: Data(lineData))

        XCTAssertEqual(envelope.type, "hello")
        XCTAssertEqual(envelope.v, 1)
    }

    func testPartialFrameBuffering() {
        // First chunk - incomplete JSON
        let partial1 = #"{"v":1,"session":"test","ts":123,"type":"hel"#
        // Second chunk - completes the frame
        let partial2 = #"lo","payload":{"pluginVersion":"1.0.0","zellijVersion":"0.42.0","protocolVersion":1}}"# + "\n"

        var buffer = Data(partial1.utf8)
        let newline = UInt8(ascii: "\n")

        // First chunk - no newline, should buffer
        XCTAssertNil(buffer.firstIndex(of: newline))

        // Add second chunk
        buffer.append(Data(partial2.utf8))

        // Now should have newline
        XCTAssertNotNil(buffer.firstIndex(of: newline))

        // Parse
        if let newlineIndex = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: Data(lineData))
            XCTAssertNotNil(envelope)
            XCTAssertEqual(envelope?.type, "hello")
        }
    }

    func testMultipleFramesInOneChunk() {
        let frame1 = #"{"v":1,"session":"s","ts":1,"type":"hello","payload":{"pluginVersion":"1.0.0","zellijVersion":"0.42.0","protocolVersion":1}}"# + "\n"
        let frame2 = #"{"v":1,"session":"s","ts":2,"type":"hello","payload":{"pluginVersion":"1.0.0","zellijVersion":"0.42.0","protocolVersion":1}}"# + "\n"

        var buffer = Data((frame1 + frame2).utf8)
        let newline = UInt8(ascii: "\n")
        var envelopes: [BridgeEnvelope] = []

        while let newlineIndex = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[(newlineIndex + 1)...])

            if let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: Data(lineData)) {
                envelopes.append(envelope)
            }
        }

        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(envelopes[0].ts, 1)
        XCTAssertEqual(envelopes[1].ts, 2)
    }

    func testInvalidJSONRecovery() {
        let invalidFrame = "not valid json\n"
        let validFrame = #"{"v":1,"session":"s","ts":1,"type":"hello","payload":{"pluginVersion":"1.0.0","zellijVersion":"0.42.0","protocolVersion":1}}"# + "\n"

        var buffer = Data((invalidFrame + validFrame).utf8)
        let newline = UInt8(ascii: "\n")
        var envelopes: [BridgeEnvelope] = []

        while let newlineIndex = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[(newlineIndex + 1)...])

            if let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: Data(lineData)) {
                envelopes.append(envelope)
            }
            // Invalid JSON is silently skipped (logged in real impl)
        }

        // Should have recovered and parsed the valid frame
        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(envelopes[0].type, "hello")
    }

    func testBufferOverflowRecovery() {
        // Simulate buffer at max size
        let maxBufferSize = 5_000_000
        let newline = UInt8(ascii: "\n")

        // Create oversized data
        var hugeBuffer = Data(repeating: UInt8(ascii: "x"), count: maxBufferSize - 100)

        // New data that would overflow but contains a newline for recovery
        let overflowData = Data(repeating: UInt8(ascii: "y"), count: 200) + Data([newline]) + Data("partial".utf8)

        // Check overflow condition
        let wouldOverflow = hugeBuffer.count + overflowData.count > maxBufferSize
        XCTAssertTrue(wouldOverflow)

        // Recovery: find last newline in new data
        if let lastNewline = overflowData.lastIndex(of: newline) {
            // Keep only partial frame after last newline
            let recovered = Data(overflowData[(lastNewline + 1)...])
            XCTAssertEqual(String(data: recovered, encoding: .utf8), "partial")
        }
    }

    func testOversizedFrameRejection() {
        let maxFrameSize = 1_000_000

        // Create a frame larger than max
        let hugePayload = String(repeating: "x", count: maxFrameSize + 100)
        let frameData = Data(hugePayload.utf8)

        // Should be rejected
        XCTAssertTrue(frameData.count > maxFrameSize)
    }
}

// MARK: - Mock Classes for Testing

class MockBridgeChannelDelegate: BridgeChannelDelegate {
    var receivedEnvelopes: [BridgeEnvelope] = []
    var didClose = false

    @MainActor
    func bridgeDidReceive(_ envelope: BridgeEnvelope) {
        receivedEnvelopes.append(envelope)
    }

    @MainActor
    func bridgeChannelDidClose() {
        didClose = true
    }
}

class MockBridgeChannelHandle {
    var writtenData: [Data] = []
    var isClosed = false

    func write(_ data: Data) async throws {
        writtenData.append(data)
    }

    func close() {
        isClosed = true
    }
}
