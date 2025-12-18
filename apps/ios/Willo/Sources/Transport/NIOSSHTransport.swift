import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

/// Thread-safe state container for NIOSSHTransport
private actor SSHTransportState {
    var state: TransportState = .disconnected
    var stateContinuation: AsyncStream<TransportState>.Continuation?
    var dataContinuation: AsyncStream<Data>.Continuation?

    func setState(_ newState: TransportState) {
        state = newState
        stateContinuation?.yield(newState)
    }

    func setStateContinuation(_ continuation: AsyncStream<TransportState>.Continuation) {
        stateContinuation = continuation
        continuation.yield(state)
    }

    func setDataContinuation(_ continuation: AsyncStream<Data>.Continuation) {
        dataContinuation = continuation
    }

    func yieldData(_ data: Data) {
        dataContinuation?.yield(data)
    }

    func finishData() {
        dataContinuation?.finish()
    }
}

/// Thread-safe container for data callbacks (matches MoshTransport pattern)
private final class SSHDataCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data) -> Void)?
    private var pendingData: [Data] = []
    private var isPrimaryCallbackSet = false

    /// Set a primary callback for data delivery
    func setPrimaryCallback(_ cb: @escaping (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        callback = cb
        isPrimaryCallbackSet = true
        // Flush any pending data
        for data in pendingData {
            cb(data)
        }
        pendingData.removeAll()
    }

    /// Set a secondary callback (from dataStream). Only works if no primary callback is set.
    func setSecondaryCallback(_ cb: @escaping (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if isPrimaryCallbackSet { return }
        callback = cb
        for data in pendingData {
            cb(data)
        }
        pendingData.removeAll()
    }

    func clearCallback() {
        lock.lock()
        defer { lock.unlock() }
        callback = nil
        isPrimaryCallbackSet = false
    }

    func deliverData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let cb = callback {
            cb(data)
        } else {
            pendingData.append(data)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        callback = nil
        isPrimaryCallbackSet = false
        pendingData.removeAll()
    }
}

/// NIOSSH-based SSH Transport with PTY support for iOS
///
/// Uses Apple's swift-nio-ssh directly for SSH connections.
/// Provides both command execution (for Mosh bootstrap) and
/// interactive shell sessions with PTY.
final class NIOSSHTransport: TerminalTransport, @unchecked Sendable {
    private let config: TransportConfig

    private var channel: Channel?
    private var shellChannel: Channel?
    private let group: MultiThreadedEventLoopGroup
    private let stateActor = SSHTransportState()
    private let dataCallbackState = SSHDataCallbackState()

    /// Current terminal size
    private var terminalCols: UInt16
    private var terminalRows: UInt16

    var state: TransportState {
        get async { await stateActor.state }
    }

    private(set) lazy var stateStream: AsyncStream<TransportState> = {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task { await self.stateActor.setStateContinuation(continuation) }
        }
    }()

    private(set) lazy var dataStream: AsyncStream<Data> = {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task { await self.stateActor.setDataContinuation(continuation) }
        }
    }()

    func initializeStreams() {
        _ = stateStream
        _ = dataStream
    }

    /// Set a direct callback for data - this is the PREFERRED method
    /// Takes priority over dataStream subscriptions
    func setDataCallback(_ callback: @escaping (Data) -> Void) {
        dataCallbackState.setPrimaryCallback(callback)
    }

    /// Clear the data callback
    func clearDataCallback() {
        dataCallbackState.clearCallback()
    }

    init(config: TransportConfig) {
        self.config = config
        self.terminalCols = config.terminalCols
        self.terminalRows = config.terminalRows
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Connection

    func connect() async throws {
        guard await stateActor.state == .disconnected else { return }

        await stateActor.setState(.connecting)
        print("[SSH] Connecting to \(config.host):\(config.port) as \(config.username)")
        print("[SSH] Auth method: \(config.authMethod)")

        do {
            // Create the SSH client channel
            print("[SSH] Creating SSH channel...")
            let channel = try await createSSHChannel()
            self.channel = channel
            print("[SSH] SSH channel created, opening shell...")

            // Open a shell channel with PTY
            try await openShellChannel()
            print("[SSH] Shell channel with PTY opened")

            await stateActor.setState(.connected)
        } catch let error as TransportError {
            print("[SSH] Transport error: \(error)")
            await stateActor.setState(.error(error))
            throw error
        } catch {
            print("[SSH] Connection error: \(type(of: error)) - \(error)")
            print("[SSH] Error details: \(String(describing: error))")
            await stateActor.setState(.error(TransportError.connectionFailed(error.localizedDescription)))
            throw TransportError.connectionFailed("\(type(of: error)): \(error)")
        }
    }

    /// Connect for command execution only (no shell channel)
    /// Used for Mosh bootstrap where we just need to run mosh-server
    func connectForBootstrap() async throws {
        guard await stateActor.state == .disconnected else { return }

        await stateActor.setState(.connecting)
        print("[SSH] Connecting for bootstrap to \(config.host):\(config.port)")

        do {
            let channel = try await createSSHChannel()
            self.channel = channel
            print("[SSH] SSH channel created (bootstrap mode - no shell)")

            await stateActor.setState(.connected)
        } catch let error as TransportError {
            print("[SSH] Transport error: \(error)")
            await stateActor.setState(.error(error))
            throw error
        } catch {
            print("[SSH] Connection error: \(type(of: error)) - \(error)")
            await stateActor.setState(.error(TransportError.connectionFailed(error.localizedDescription)))
            throw TransportError.connectionFailed("\(type(of: error)): \(error)")
        }
    }

    private func createSSHChannel() async throws -> Channel {
        // Capture values for use in closure
        let username = config.username
        let password = getPassword()
        let host = config.host
        let port = config.port

        print("[SSH] Setting up connection to \(host):\(port)")
        print("[SSH] Username: \(username), password length: \(password.count)")

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                // Create delegates inside closure to avoid Sendable capture issues
                let authDelegate = PasswordAuthDelegate(username: username, password: password)
                let hostKeyDelegate = AcceptAllHostKeysDelegate()

                print("[SSH] Channel initializer called, adding SSH handler")

                return channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: authDelegate,
                            serverAuthDelegate: hostKeyDelegate
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                ])
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .connectTimeout(.seconds(10))

        do {
            print("[SSH] Attempting TCP connection...")
            let channel = try await bootstrap.connect(host: host, port: Int(port)).get()
            print("[SSH] TCP connection established!")
            return channel
        } catch {
            print("[SSH] Connection failed to \(host):\(port) - \(error)")
            throw TransportError.connectionFailed("Could not connect to \(host):\(port). Check the hostname and ensure the server is reachable.")
        }
    }

    private func getPassword() -> String {
        switch config.authMethod {
        case .password(let password):
            return password
        default:
            return ""
        }
    }

    private func openShellChannel() async throws {
        guard let channel = channel else {
            throw TransportError.notConnected
        }

        // Get the SSH handler on the event loop
        let sshHandler = try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        }.get()

        // Create data handler with thread-safe callback
        let dataCallback: @Sendable (Data) -> Void = { [weak self] data in
            self?.handleIncomingData(data)
        }

        // Create a session channel on the event loop
        let childChannel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
            // Must dispatch to event loop for NIO operations
            channel.eventLoop.execute {
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }

                sshHandler.createChannel(promise) { childChannel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(TransportError.connectionFailed("Invalid channel type"))
                    }

                    return childChannel.pipeline.addHandlers([
                        ShellDataHandler(onData: dataCallback)
                    ])
                }
            }
        }

        self.shellChannel = childChannel

        // Request PTY
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: Int(terminalCols),
            terminalRowHeight: Int(terminalRows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await childChannel.triggerUserOutboundEvent(ptyRequest).get()

        // Request shell
        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await childChannel.triggerUserOutboundEvent(shellRequest).get()
    }

    /// Thread-safe handler for incoming data
    private func handleIncomingData(_ data: Data) {
        // Deliver via callback (preferred) - will also buffer if no callback yet
        dataCallbackState.deliverData(data)
        // Also yield to async stream for backwards compatibility
        Task { await stateActor.yieldData(data) }
    }

    func disconnect() async throws {
        if let shell = shellChannel {
            try? await shell.close()
        }
        shellChannel = nil

        if let ch = channel {
            try? await ch.close()
        }
        channel = nil

        await stateActor.setState(.disconnected)
        await stateActor.finishData()
        dataCallbackState.finish()
    }

    // MARK: - I/O

    func send(_ data: Data) async throws {
        guard let shell = shellChannel else {
            throw TransportError.notConnected
        }

        var buffer = shell.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        try await shell.writeAndFlush(channelData)
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        terminalCols = cols
        terminalRows = rows

        guard let shell = shellChannel else { return }

        let windowChange = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(cols),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await shell.triggerUserOutboundEvent(windowChange).get()
    }

    // MARK: - Command Execution (for Mosh bootstrap)

    /// Execute a command and return the output
    /// Used primarily for running mosh-server to get connection details
    func executeCommand(_ command: String) async throws -> String {
        guard let channel = channel else {
            throw TransportError.notConnected
        }

        // Get SSH handler on the event loop
        let sshHandler = try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        }.get()

        // Use actor for thread-safe output collection
        let collector = OutputCollector()

        // Create child channel on the event loop
        let childChannel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
            // Must dispatch to event loop for NIO operations
            channel.eventLoop.execute {
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }

                sshHandler.createChannel(promise) { childChannel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(TransportError.connectionFailed("Invalid channel type"))
                    }

                    let handler = CommandOutputHandler { data in
                        Task { await collector.append(data) }
                    }

                    return childChannel.pipeline.addHandlers([handler])
                }
            }
        }

        // Execute command
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        try await childChannel.triggerUserOutboundEvent(execRequest).get()

        // Wait for channel to close
        try await childChannel.closeFuture.get()

        return await collector.getString()
    }

}

// MARK: - Output Collector Actor

/// Thread-safe collector for command output
private actor OutputCollector {
    private var data = Data()

    func append(_ newData: Data) {
        data.append(newData)
    }

    func getString() -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Authentication Delegates

/// Simple password authentication delegate
final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let password: String
    private let lock = NSLock()
    private var _attemptedPassword = false

    private var attemptedPassword: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _attemptedPassword
        }
        set {
            lock.lock()
            _attemptedPassword = newValue
            lock.unlock()
        }
    }

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        print("[SSH Auth] Available methods: \(availableMethods)")
        print("[SSH Auth] Username: \(username), password length: \(password.count)")

        if !attemptedPassword && availableMethods.contains(.password) {
            attemptedPassword = true
            print("[SSH Auth] Attempting password authentication...")
            nextChallengePromise.succeed(.init(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            ))
        } else {
            print("[SSH Auth] No more auth methods to try (attempted: \(attemptedPassword))")
            nextChallengePromise.succeed(nil)
        }
    }
}

/// Accept all host keys (for development - should validate in production)
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // Accept any host key
        // TODO: Implement proper host key validation with known_hosts
        validationCompletePromise.succeed(())
    }
}

/// Public key authentication delegate
/// NOTE: NIOSSH doesn't include an OpenSSH key parser, so this requires
/// the key to be parsed externally before passing to this delegate.
/// For now, we fall back to password auth. Full key support requires
/// adding an OpenSSH key parser (complex due to various key formats).
final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    private let lock = NSLock()
    private var _attempted = false

    private var attempted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _attempted }
        set { lock.lock(); _attempted = newValue; lock.unlock() }
    }

    init(username: String, privateKeyData: Data, passphrase: String?) {
        self.username = username
        // TODO: Parse OpenSSH key format and store for use
        print("[SSH Auth] Public key auth initialized (key parsing not yet implemented)")
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        print("[SSH Auth] Public key auth requested but not yet implemented")
        print("[SSH Auth] Available methods: \(availableMethods)")
        // TODO: Implement OpenSSH key parsing
        // For now, fail gracefully so password auth can be tried
        nextChallengePromise.succeed(nil)
    }
}

/// Default key auth delegate - placeholder until OpenSSH key parsing is implemented
final class DefaultKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String

    init(username: String) {
        self.username = username
        print("[SSH Auth] Agent/default key auth requested (not yet implemented)")
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        print("[SSH Auth] Default key auth not yet implemented, available: \(availableMethods)")
        // TODO: Implement SSH key loading from common paths
        nextChallengePromise.succeed(nil)
    }
}

// MARK: - Channel Handlers

/// Handler for shell session data
final class ShellDataHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    let onData: @Sendable (Data) -> Void

    init(onData: @escaping @Sendable (Data) -> Void) {
        self.onData = onData
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = channelData.data else { return }

        if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
            onData(data)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SSH] Shell error: \(error)")
        context.close(promise: nil)
    }
}

/// Handler for command output
final class CommandOutputHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    let onData: @Sendable (Data) -> Void

    init(onData: @escaping @Sendable (Data) -> Void) {
        self.onData = onData
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = channelData.data else { return }

        if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
            onData(data)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}
