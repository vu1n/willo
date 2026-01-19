import Foundation

/// Actor for thread-safe NDJSON parsing and channel management
///
/// BridgeChannel owns the parse buffer exclusively, preventing races.
/// All operations are serialized through the actor.
actor BridgeChannel {
    // MARK: - Constants

    /// Maximum buffer size before forced reset (5MB)
    private static let maxBufferSize = 5_000_000

    /// Maximum single frame size (1MB)
    private static let maxFrameSize = 1_000_000

    // MARK: - State

    private var buffer = Data()
    private let newline = UInt8(ascii: "\n")
    private var channelHandle: BridgeChannelHandle?
    private weak var delegate: BridgeChannelDelegate?
    private var isClosed = false

    // MARK: - Init

    init(channelHandle: BridgeChannelHandle, delegate: BridgeChannelDelegate?) {
        self.channelHandle = channelHandle
        self.delegate = delegate
    }

    // MARK: - Receive (called from SSH data callback)

    /// Receive data from the SSH channel and parse NDJSON frames
    func receive(_ data: Data) async {
        guard !isClosed else { return }

        // Bound buffer to prevent memory exhaustion
        if buffer.count + data.count > Self.maxBufferSize {
            print("[BridgeChannel] Buffer overflow (\(buffer.count + data.count) bytes), resetting")
            // Recovery strategy: Find the last newline in the new data
            // and keep only the partial frame after it
            if let lastNewline = data.lastIndex(of: newline) {
                // Keep only the partial frame after the last newline in new data
                buffer = Data(data[(lastNewline + 1)...])
                print("[BridgeChannel] Recovered with \(buffer.count) bytes after last newline")
            } else {
                // No newline in new data - just reset and start fresh
                buffer = Data()
            }
            return
        }
        buffer.append(data)

        // Parse complete frames
        var envelopes: [BridgeEnvelope] = []
        while let newlineIndex = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[(newlineIndex + 1)...])

            guard !lineData.isEmpty else { continue }

            // Reject oversized frames
            guard lineData.count <= Self.maxFrameSize else {
                print("[BridgeChannel] Frame too large (\(lineData.count) bytes), skipping")
                continue
            }

            do {
                let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: Data(lineData))
                envelopes.append(envelope)
            } catch {
                let preview = String(data: Data(lineData.prefix(100)), encoding: .utf8) ?? "?"
                print("[BridgeChannel] Invalid JSON: \(preview)... error: \(error)")
            }
        }

        // Deliver to delegate on MainActor
        for envelope in envelopes {
            await MainActor.run { [weak delegate] in
                delegate?.bridgeDidReceive(envelope)
            }
        }
    }

    // MARK: - Send (NDJSON framed)

    /// Send a command to the plugin
    func send(_ command: BridgeCommand) async throws {
        guard !isClosed, let handle = channelHandle else {
            throw BridgeChannelError.notConnected
        }

        var json = try JSONEncoder().encode(command)
        json.append(UInt8(ascii: "\n"))
        try await handle.write(json)
    }

    // MARK: - Convenience Commands

    /// Request a state snapshot from the plugin
    func requestSnapshot() async throws {
        try await send(.requestSnapshot)
    }

    /// Send a ping for heartbeat
    func sendPing() async throws {
        try await send(.ping)
    }

    /// Request a new pane
    func newPane(direction: PaneDirection? = nil) async throws {
        try await send(.newPane(direction: direction))
    }

    /// Request a new tab
    func newTab(name: String? = nil, layout: String? = nil) async throws {
        try await send(.newTab(name: name, layout: layout))
    }

    /// Focus a pane
    func focusPane(_ paneId: Int) async throws {
        try await send(.focus(paneId: paneId))
    }

    /// Focus a tab
    func focusTab(_ tabId: Int) async throws {
        try await send(.focusTab(tabId: tabId))
    }

    /// Apply a layout
    func applyLayout(_ name: String) async throws {
        try await send(.applyLayout(name: name))
    }

    // MARK: - Lifecycle

    /// Close the channel
    func close() {
        guard !isClosed else { return }
        isClosed = true
        buffer = Data()
        channelHandle?.close()
        channelHandle = nil

        Task { @MainActor [weak delegate] in
            delegate?.bridgeChannelDidClose()
        }
    }

    /// Check if channel is open
    var isOpen: Bool {
        !isClosed && channelHandle != nil
    }
}

// MARK: - Errors

enum BridgeChannelError: LocalizedError {
    case notConnected
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Bridge channel not connected"
        case .encodingFailed:
            return "Failed to encode command"
        }
    }
}

// MARK: - Channel Receiver (Late-Binding Pattern)

/// Thread-safe receiver that buffers data until a BridgeChannel is bound.
/// This solves the early-data race where SSH data arrives before the
/// BridgeChannel is created and assigned.
final class ChannelReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var earlyBuffer: [Data] = []
    private var channel: BridgeChannel?
    private var isBound = false

    /// Receive data - buffers if channel not yet bound, forwards otherwise
    func receive(_ data: Data) {
        lock.lock()

        if isBound, let channel = channel {
            lock.unlock()
            // Channel is bound - forward directly
            Task {
                await channel.receive(data)
            }
        } else {
            // Not yet bound - buffer the data
            earlyBuffer.append(data)
            lock.unlock()
        }
    }

    /// Bind the channel and flush any buffered early data
    func bindChannel(_ channel: BridgeChannel) async {
        // Extract buffered data synchronously to avoid async lock issues
        let buffered: [Data] = {
            lock.lock()
            defer { lock.unlock() }
            self.channel = channel
            let data = earlyBuffer
            earlyBuffer = []
            isBound = true
            return data
        }()

        // Flush buffered data to the channel (async-safe)
        for data in buffered {
            await channel.receive(data)
        }
    }
}
