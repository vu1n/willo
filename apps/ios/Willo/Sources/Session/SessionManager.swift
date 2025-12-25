import Foundation
import SwiftUI
import Combine

/// Manages terminal sessions, coordinating Ghostty surfaces with transports
///
/// SessionManager is the central coordinator that:
/// 1. Creates and manages terminal sessions
/// 2. Connects Ghostty surfaces to transports via PTY bridges
/// 3. Handles session lifecycle (connect, disconnect, reconnect)
/// 4. Persists session configuration
@MainActor
final class SessionManager: ObservableObject {
    /// All managed sessions
    @Published private(set) var sessions: [TerminalSession] = []

    /// Currently active session
    @Published var activeSession: TerminalSession?

    /// App manager for Ghostty
    let appManager: GhosttyAppManager

    /// Session storage
    private var sessionConfigs: [UUID: SessionConfig] = [:]

    init(appManager: GhosttyAppManager) {
        self.appManager = appManager
    }

    // MARK: - Session Management

    /// Create a new session with the given configuration
    func createSession(config: SessionConfig) async throws -> TerminalSession {
        // Create Ghostty surface
        let surface = GhosttySurface(app: appManager)

        // Create transport based on config
        let transport = try createTransport(for: config)

        // Create PTY bridge
        let ptyBridge = PTYBridge()
        try ptyBridge.open()
        try ptyBridge.configureTerminal()

        // Create session
        let session = TerminalSession(
            id: UUID(),
            config: config,
            surface: surface,
            transport: transport,
            ptyBridge: ptyBridge
        )

        // Store config for persistence
        sessionConfigs[session.id] = config

        // Add to sessions list
        sessions.append(session)

        // Set as active if it's the first session
        if activeSession == nil {
            activeSession = session
        }

        return session
    }

    /// Connect a session
    func connect(_ session: TerminalSession) async throws {
        guard session.state != .connected else { return }

        session.setState(.connecting)

        do {
            // Connect transport
            try await session.transport.connect()

            // NOTE: PTY bridge is NOT started - data flows directly from transport
            // to WilloTerminalViewRepresentable via callbacks. The PTYBridge was
            // causing issues by consuming dataStream before the view could.

            // Set initial terminal size from config (not hardcoded)
            let cols = session.config.terminalCols
            let rows = session.config.terminalRows
            print("[SessionManager] Setting initial terminal size: \(cols)x\(rows)")
            try await session.resize(cols: cols, rows: rows)

            session.setState(.connected)
        } catch {
            session.setState(.error(error))
            throw error
        }
    }

    /// Disconnect a session
    func disconnect(_ session: TerminalSession) async throws {
        session.bridge?.stop()
        try await session.transport.disconnect()
        session.setState(.disconnected)
    }

    /// Close and remove a session
    func closeSession(_ session: TerminalSession) async {
        // Disconnect if connected
        if session.state == .connected {
            try? await disconnect(session)
        }

        // Close PTY
        session.ptyBridge.close()

        // Remove from sessions
        sessions.removeAll { $0.id == session.id }
        sessionConfigs.removeValue(forKey: session.id)

        // Update active session if needed
        if activeSession?.id == session.id {
            activeSession = sessions.first
        }
    }

    /// Switch to a different active session
    func setActiveSession(_ session: TerminalSession?) {
        activeSession = session
    }

    // MARK: - Transport Factory

    private func createTransport(for config: SessionConfig) throws -> TerminalTransport {
        switch config.connectionType {
        case .ssh:
            return NIOSSHTransport(config: config.toTransportConfig())
        case .mosh:
            // Mosh requires async bootstrap - use createMoshSession instead
            // Fall back to SSH for now (Mosh bootstrap happens in connect phase)
            return NIOSSHTransport(config: config.toTransportConfig())
        case .local:
            return LocalTransport()
        }
    }

    /// Create a session with Mosh transport (handles SSH bootstrap automatically)
    func createMoshSession(config: SessionConfig) async throws -> TerminalSession {
        // First, create SSH transport for bootstrap (no shell, just command execution)
        let sshTransport = NIOSSHTransport(config: config.toTransportConfig())
        sshTransport.initializeStreams()

        // Connect via SSH in bootstrap mode (no shell channel)
        try await sshTransport.connectForBootstrap()

        // Bootstrap mosh-server to get key and port
        print("[Mosh] Running mosh-server bootstrap...")
        let bootstrap = try await MoshTransport.bootstrap(using: sshTransport)
        print("[Mosh] Bootstrap successful - port: \(bootstrap.port)")

        // Disconnect SSH (we'll use Mosh UDP now)
        try await sshTransport.disconnect()

        // Create Mosh transport with bootstrap credentials
        let moshTransport = MoshTransport(
            config: config.toTransportConfig(),
            moshKey: bootstrap.key,
            moshPort: bootstrap.port
        )
        moshTransport.initializeStreams()

        // Create Ghostty surface
        let surface = GhosttySurface(app: appManager)

        // Create PTY bridge
        let ptyBridge = PTYBridge()
        try ptyBridge.open()
        try ptyBridge.configureTerminal()

        // Create session with Mosh transport
        let session = TerminalSession(
            id: UUID(),
            config: config,
            surface: surface,
            transport: moshTransport,
            ptyBridge: ptyBridge
        )

        // Store and track
        sessionConfigs[session.id] = config
        sessions.append(session)

        if activeSession == nil {
            activeSession = session
        }

        return session
    }

    /// Create a Mosh transport after bootstrapping via SSH
    /// This is called after running mosh-server on the remote host
    func createMoshTransport(config: SessionConfig, moshKey: String, moshPort: String) -> MoshTransport {
        return MoshTransport(
            config: config.toTransportConfig(),
            moshKey: moshKey,
            moshPort: moshPort
        )
    }
}

// MARK: - Terminal Session

/// Represents a single terminal session
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let config: SessionConfig

    /// Ghostty terminal surface
    let surface: GhosttySurface

    /// Network transport
    let transport: TerminalTransport

    /// PTY bridge connecting surface to transport
    let ptyBridge: PTYBridge

    /// Bridge coordinator
    private(set) var bridge: TransportPTYBridge?

    /// Session state
    @Published private(set) var state: SessionState = .disconnected

    /// Display title
    var title: String {
        config.name ?? "\(config.username)@\(config.host)"
    }

    init(
        id: UUID,
        config: SessionConfig,
        surface: GhosttySurface,
        transport: TerminalTransport,
        ptyBridge: PTYBridge
    ) {
        self.id = id
        self.config = config
        self.surface = surface
        self.transport = transport
        self.ptyBridge = ptyBridge
        self.bridge = TransportPTYBridge(pty: ptyBridge, transport: transport)
    }

    func setState(_ newState: SessionState) {
        state = newState
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        try ptyBridge.setSize(cols: cols, rows: rows)
        try await transport.resize(cols: cols, rows: rows)
    }
}

/// Session connection state
enum SessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case error(Error)

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected):
            return true
        case (.reconnecting(let a), .reconnecting(let b)):
            return a == b
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}

// MARK: - Session Configuration

/// Configuration for a terminal session
struct SessionConfig: Codable, Identifiable {
    let id: UUID
    var name: String?
    var host: String
    var port: UInt16
    var username: String
    var connectionType: ConnectionType
    var authMethod: AuthMethodConfig

    /// Terminal settings
    var terminalCols: UInt16 = 80
    var terminalRows: UInt16 = 24

    /// Mosh-specific settings
    var moshPrediction: MoshPrediction = .adaptive
    var moshPort: UInt16? // Server's UDP port

    enum ConnectionType: String, Codable {
        case ssh
        case mosh
        case local
    }

    enum MoshPrediction: String, Codable {
        case adaptive
        case always
        case never
        case experimental
    }

    init(
        id: UUID = UUID(),
        name: String? = nil,
        host: String,
        port: UInt16 = 22,
        username: String,
        connectionType: ConnectionType = .ssh,
        authMethod: AuthMethodConfig = .agent
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.connectionType = connectionType
        self.authMethod = authMethod
    }

    func toTransportConfig() -> TransportConfig {
        TransportConfig(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.toTransportAuthMethod(),
            terminalCols: terminalCols,
            terminalRows: terminalRows
        )
    }
}

/// Authentication method configuration
enum AuthMethodConfig: Codable {
    case password(String)
    case publicKey(keyPath: String, passphrase: String?)
    case agent

    func toTransportAuthMethod() -> TransportConfig.AuthMethod {
        switch self {
        case .password(let password):
            return .password(password)
        case .publicKey(let keyPath, let passphrase):
            // Load key data from path
            let keyData = (try? Data(contentsOf: URL(fileURLWithPath: keyPath))) ?? Data()
            return .publicKey(privateKey: keyData, passphrase: passphrase)
        case .agent:
            return .agent
        }
    }
}

// MARK: - Local Transport

/// Local transport for testing (connects to local shell)
final class LocalTransport: TerminalTransport {
    private var _state: TransportState = .disconnected
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private var dataContinuation: AsyncStream<Data>.Continuation?

    var state: TransportState {
        get async { _state }
    }

    lazy var stateStream: AsyncStream<TransportState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(self._state)
        }
    }()

    lazy var dataStream: AsyncStream<Data> = {
        AsyncStream { continuation in
            self.dataContinuation = continuation
        }
    }()

    func connect() async throws {
        setState(.connecting)
        // Local shell - immediate connection
        setState(.connected)
    }

    func disconnect() async throws {
        setState(.disconnected)
        dataContinuation?.finish()
    }

    func send(_ data: Data) async throws {
        // Echo back for testing
        dataContinuation?.yield(data)
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        // No-op for local
    }

    private func setState(_ newState: TransportState) {
        _state = newState
        stateContinuation?.yield(newState)
    }
}
