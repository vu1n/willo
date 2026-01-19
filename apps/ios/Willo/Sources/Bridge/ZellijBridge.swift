import Foundation
import Combine

/// Bridge mode representing the current state of the Zellij bridge
enum BridgeMode: Equatable {
    case disconnected
    case connecting
    case awaitingHello       // Channel open, waiting for hello validation
    case streaming           // Hello validated, streaming active
    case unsupported(reason: String)
    case needsPluginInstall
    case needsPluginUpdate(installed: String, required: String)

    static func == (lhs: BridgeMode, rhs: BridgeMode) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.awaitingHello, .awaitingHello),
             (.streaming, .streaming),
             (.needsPluginInstall, .needsPluginInstall):
            return true
        case (.unsupported(let l), .unsupported(let r)):
            return l == r
        case (.needsPluginUpdate(let lI, let lR), .needsPluginUpdate(let rI, let rR)):
            return lI == rI && lR == rR
        default:
            return false
        }
    }

    var isConnected: Bool {
        self == .streaming
    }

    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .awaitingHello: return "Awaiting bridge..."
        case .streaming: return "Connected"
        case .unsupported(let reason): return reason
        case .needsPluginInstall: return "Plugin not installed"
        case .needsPluginUpdate(let installed, let required):
            return "Plugin update needed (v\(installed) → v\(required))"
        }
    }
}

/// Coordinator for Zellij bridge communication
///
/// ZellijBridge manages the lifecycle of the bridge channel and maintains
/// the observable state of the Zellij session.
@MainActor
final class ZellijBridge: ObservableObject {
    // MARK: - Published State

    /// Current Zellij session state
    @Published private(set) var zellijState: ZellijSession?

    /// Current bridge mode
    @Published private(set) var bridgeMode: BridgeMode = .disconnected

    /// Whether the bridge is fully connected and streaming
    @Published private(set) var isConnected: Bool = false

    // MARK: - Configuration

    /// Plugin version that must match server (loaded from bundled plugin)
    static let pluginVersion = BundledPlugin.pluginVersion()

    /// Hello timeout in seconds
    static let helloTimeoutSeconds: UInt64 = 10

    /// Heartbeat interval in seconds
    static let heartbeatIntervalSeconds: UInt64 = 15

    /// Snapshot request timeout in seconds
    static let snapshotTimeoutSeconds: UInt64 = 2

    // MARK: - Private State

    private let sessionName: String
    private let bridgeId = UUID()  // Unique ID for multi-client support
    private weak var transport: NIOSSHTransport?
    private var channel: BridgeChannel?
    private var helloValidated = false
    private var helloTimeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var snapshotTimeoutTask: Task<Void, Never>?

    /// State update debouncing
    private var pendingState: ZellijSession?
    private var debounceTask: Task<Void, Never>?
    private let debounceIntervalNs: UInt64 = 50_000_000  // 50ms

    // MARK: - Init

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    deinit {
        // Cancel tasks directly - Task.cancel() is safe from any context
        helloTimeoutTask?.cancel()
        heartbeatTask?.cancel()
        snapshotTimeoutTask?.cancel()
        debounceTask?.cancel()
        // Channel cleanup happens automatically when BridgeChannel actor is deallocated
    }

    // MARK: - Public Interface

    /// Start the bridge
    func start(transport: NIOSSHTransport) async {
        self.transport = transport
        bridgeMode = .connecting

        do {
            // Detect capabilities
            let caps = try await CapabilityDetector.detect(
                transport: transport,
                sessionName: sessionName
            )

            switch caps {
            case .streaming:
                try await openStreamingChannel()
            case .needsPluginInstall:
                bridgeMode = .needsPluginInstall
            case .needsPluginUpdate(let installed, let required):
                bridgeMode = .needsPluginUpdate(installed: installed, required: required)
            case .sessionNotFound:
                bridgeMode = .unsupported(reason: "Session '\(sessionName)' not found")
            case .unsupported(let reason):
                bridgeMode = .unsupported(reason: reason)
            }
        } catch {
            bridgeMode = .unsupported(reason: error.localizedDescription)
        }
    }

    /// Stop the bridge
    func stop() {
        stopInternal()
        bridgeMode = .disconnected
        isConnected = false
        zellijState = nil
    }

    /// Install the plugin and retry connection
    func installPluginAndRetry(pluginData: Data) async throws {
        guard let transport = transport else {
            throw BridgeError.notConnected
        }

        bridgeMode = .connecting
        try await CapabilityDetector.deployPlugin(transport: transport, pluginData: pluginData)
        try await openStreamingChannel()
    }

    /// Install the bundled plugin and retry connection
    /// Convenience method that loads the plugin from the app bundle
    func installBundledPluginAndRetry() async throws {
        guard let pluginData = BundledPlugin.loadPluginData() else {
            throw BridgeError.connectionFailed("Bundled plugin not found")
        }
        try await installPluginAndRetry(pluginData: pluginData)
    }

    // MARK: - Channel Commands

    /// Create a new pane
    func newPane(direction: PaneDirection? = nil) async throws {
        guard let channel = channel, bridgeMode == .streaming else {
            throw BridgeError.notConnected
        }
        try await channel.newPane(direction: direction)
    }

    /// Create a new tab
    func newTab(name: String? = nil, layout: String? = nil) async throws {
        guard let channel = channel, bridgeMode == .streaming else {
            throw BridgeError.notConnected
        }
        try await channel.newTab(name: name, layout: layout)
    }

    /// Focus a pane
    func focusPane(_ paneId: Int) async throws {
        guard let channel = channel, bridgeMode == .streaming else {
            throw BridgeError.notConnected
        }
        try await channel.focusPane(paneId)
    }

    /// Focus a tab
    func focusTab(_ tabIndex: Int) async throws {
        guard let channel = channel, bridgeMode == .streaming else {
            throw BridgeError.notConnected
        }
        try await channel.focusTab(tabIndex)
    }

    /// Apply a layout
    func applyLayout(_ name: String) async throws {
        guard let channel = channel, bridgeMode == .streaming else {
            throw BridgeError.notConnected
        }
        try await channel.applyLayout(name)
    }

    // MARK: - Private Implementation

    private func openStreamingChannel() async throws {
        guard let transport = transport else {
            throw BridgeError.notConnected
        }

        let escaped = ShellEscape.escape(sessionName)
        // Use unique pipe name with UUID for multi-client support
        let pipeName = "willo_bridge_\(bridgeId.uuidString.prefix(8))"
        // Use $HOME for reliable expansion
        let cmd = "zellij --session \(escaped) pipe --name \(pipeName) --plugin file:$HOME/.willo/willo-bridge.wasm"

        // Create a late-binding receiver to avoid early data race
        // The receiver buffers data until the BridgeChannel is set
        let receiver = ChannelReceiver()

        // Capture weak self for the close callback
        weak var weakSelf = self

        // Open bridge channel with receiver callback and close handler
        let channelHandle = try await transport.openBridgeChannel(
            command: cmd,
            onData: { data in
                receiver.receive(data)
            },
            onClose: {
                // Remote closed the channel - update state on MainActor
                Task { @MainActor in
                    weakSelf?.handleRemoteClose()
                }
            }
        )

        // Create the BridgeChannel actor and bind it to the receiver
        let bridgeChannel = BridgeChannel(channelHandle: channelHandle, delegate: self)
        channel = bridgeChannel

        // Now bind the channel and flush any early data
        await receiver.bindChannel(bridgeChannel)

        // Mark as awaiting hello, NOT streaming yet
        bridgeMode = .awaitingHello

        // Start hello timeout
        helloTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.helloTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self = self, !self.helloValidated else { return }
                self.stopInternal()
                self.bridgeMode = .unsupported(reason: "Plugin did not respond (timeout)")
            }
        }

        // Start snapshot timeout - if no state after 2s, request explicitly
        snapshotTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.snapshotTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self = self, self.helloValidated, self.zellijState == nil else { return }
                // No state received yet - request snapshot explicitly
                Task {
                    try? await self.channel?.requestSnapshot()
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }

                guard let self = self else { break }
                await MainActor.run {
                    guard self.helloValidated else { return }
                    Task {
                        try? await self.channel?.sendPing()
                    }
                }
            }
        }
    }

    /// Handle remote channel closure (called when SSH channel becomes inactive)
    private func handleRemoteClose() {
        print("[ZellijBridge] Remote channel closed")

        // Stop internal state without changing bridgeMode yet
        stopInternal()

        // Transition to disconnected with reason if we were connected
        if bridgeMode == .streaming {
            bridgeMode = .unsupported(reason: "Connection lost (remote closed)")
        } else if bridgeMode == .awaitingHello {
            bridgeMode = .unsupported(reason: "Plugin connection failed")
        } else {
            bridgeMode = .disconnected
        }
        isConnected = false
    }

    /// Internal cleanup without changing bridgeMode
    private func stopInternal() {
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil

        debounceTask?.cancel()
        debounceTask = nil

        Task {
            await channel?.close()
        }
        channel = nil
        helloValidated = false
    }

    // MARK: - State Update Handling

    /// Handle state update with debouncing
    private func handleStateUpdate(_ state: ZellijSession) {
        pendingState = state
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceIntervalNs ?? 50_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self = self, let state = self.pendingState else { return }
                self.zellijState = state
                self.pendingState = nil
            }
        }
    }
}

// MARK: - BridgeChannelDelegate

extension ZellijBridge: BridgeChannelDelegate {
    nonisolated func bridgeDidReceive(_ envelope: BridgeEnvelope) {
        Task { @MainActor in
            handleEnvelope(envelope)
        }
    }

    nonisolated func bridgeChannelDidClose() {
        Task { @MainActor in
            if bridgeMode == .streaming {
                bridgeMode = .disconnected
                isConnected = false
            }
        }
    }

    @MainActor
    private func handleEnvelope(_ envelope: BridgeEnvelope) {
        switch envelope.type {
        case "hello":
            handleHello(envelope)
        case "tabUpdate":
            handleTabUpdate(envelope)
        case "paneUpdate":
            handlePaneUpdate(envelope)
        case "sessionUpdate":
            handleSessionUpdate(envelope)
        default:
            print("[ZellijBridge] Unknown message type: \(envelope.type)")
        }
    }

    @MainActor
    private func handleHello(_ envelope: BridgeEnvelope) {
        guard case .hello(let payload) = envelope.payload else {
            print("[ZellijBridge] Invalid hello payload")
            return
        }

        // Validate versions
        if payload.pluginVersion != Self.pluginVersion {
            let reason = BridgeMode.needsPluginUpdate(
                installed: payload.pluginVersion,
                required: Self.pluginVersion
            )
            stopInternal()
            bridgeMode = reason
            return
        }

        // Hello validated - transition to streaming
        helloValidated = true
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        bridgeMode = .streaming
        isConnected = true

        // Start heartbeat now that we're connected
        startHeartbeat()

        print("[ZellijBridge] Hello validated - plugin v\(payload.pluginVersion), protocol v\(payload.protocolVersion)")
    }

    @MainActor
    private func handleTabUpdate(_ envelope: BridgeEnvelope) {
        guard helloValidated else {
            print("[ZellijBridge] Ignoring tabUpdate before hello")
            return
        }
        guard case .tabUpdate(let payload) = envelope.payload else { return }

        // Find active tab index
        let activeIndex = payload.tabs.firstIndex { $0.active } ?? 0

        // Update or create state
        if var state = zellijState {
            state.tabs = payload.tabs
            state.activeTabIndex = activeIndex
            handleStateUpdate(state)
        } else {
            // First state - create new session
            let state = ZellijSession(
                id: envelope.session,
                tabs: payload.tabs,
                activeTabIndex: activeIndex
            )
            handleStateUpdate(state)
        }
    }

    @MainActor
    private func handlePaneUpdate(_ envelope: BridgeEnvelope) {
        guard helloValidated else {
            print("[ZellijBridge] Ignoring paneUpdate before hello")
            return
        }
        guard case .paneUpdate(let payload) = envelope.payload else { return }

        // Convert pane manifest
        let manifest = payload.toManifest()

        // Update or create state
        if var state = zellijState {
            state.paneManifest = manifest
            handleStateUpdate(state)
        } else {
            // First state - create new session (unusual to get panes before tabs)
            let state = ZellijSession(
                id: envelope.session,
                paneManifest: manifest
            )
            handleStateUpdate(state)
        }
    }

    @MainActor
    private func handleSessionUpdate(_ envelope: BridgeEnvelope) {
        guard helloValidated else { return }
        // SessionUpdate is mainly for session name - we already have it
        // Could use this to detect session rename
    }
}

// MARK: - Errors

enum BridgeError: LocalizedError {
    case notConnected
    case sessionNotFound(String)
    case versionMismatch(installed: String, required: String)
    case connectionFailed(String)
    case helloTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Bridge not connected"
        case .sessionNotFound(let name):
            return "Session '\(name)' not found"
        case .versionMismatch(let installed, let required):
            return "Plugin version mismatch (v\(installed) vs v\(required))"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .helloTimeout:
            return "Plugin did not respond"
        }
    }
}
