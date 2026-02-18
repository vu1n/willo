import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
import os.log

private let logger = Logger(subsystem: "com.willo.app", category: "SSH")

/// Thread-safe state container for NIOSSHTransport
private actor SSHTransportState {
    var state: TransportState = .disconnected
    var stateContinuation: AsyncStream<TransportState>.Continuation?

    func setState(_ newState: TransportState) {
        state = newState
        stateContinuation?.yield(newState)
    }

    func setStateContinuation(_ continuation: AsyncStream<TransportState>.Continuation) {
        stateContinuation = continuation
        continuation.yield(state)
    }
}

/// Type alias using shared callback state implementation
private typealias SSHDataCallbackState = TransportDataCallbackState<Data>

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

    /// Data stream - creates a new stream each time to avoid multiple consumer issues
    /// IMPORTANT: Only ONE consumer should iterate this at a time
    /// NOTE: If setDataCallback was called first, this stream won't receive data
    var dataStream: AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { [dataCallbackState] continuation in
            // Set secondary callback - won't overwrite a primary callback from setDataCallback
            dataCallbackState.setSecondaryCallback { data in
                continuation.yield(data)
            }
            // Handle stream termination
            continuation.onTermination = { _ in
                dataCallbackState.clearCallback()
            }
        }
    }

    func initializeStreams() {
        _ = stateStream
        // Note: dataStream is no longer lazy, so no need to access it here
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
        // Use async shutdown to avoid deadlock if deinit runs on an NIO event loop thread
        group.shutdownGracefully { _ in }
    }

    // MARK: - Connection

    func connect() async throws {
        guard await stateActor.state == .disconnected else { return }

        await stateActor.setState(.connecting)
        logger.info("Connecting to \(self.config.host, privacy: .public):\(self.config.port)")

        do {
            let channel = try await createSSHChannel()
            self.channel = channel

            try await openShellChannel()

            await stateActor.setState(.connected)
        } catch let error as TransportError {
            logger.error("Transport error: \(error.localizedDescription, privacy: .public)")
            await stateActor.setState(.error(error))
            throw error
        } catch {
            logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            await stateActor.setState(.error(TransportError.connectionFailed(error.localizedDescription)))
            throw TransportError.connectionFailed("\(type(of: error)): \(error)")
        }
    }

    /// Connect for command execution only (no shell channel)
    /// Used for Mosh bootstrap where we just need to run mosh-server
    func connectForBootstrap() async throws {
        guard await stateActor.state == .disconnected else { return }

        await stateActor.setState(.connecting)
        logger.info("Connecting for bootstrap to \(self.config.host, privacy: .public):\(self.config.port)")

        do {
            let channel = try await createSSHChannel()
            self.channel = channel

            await stateActor.setState(.connected)
        } catch let error as TransportError {
            logger.error("Bootstrap transport error: \(error.localizedDescription, privacy: .public)")
            await stateActor.setState(.error(error))
            throw error
        } catch {
            logger.error("Bootstrap connection failed: \(error.localizedDescription, privacy: .public)")
            await stateActor.setState(.error(TransportError.connectionFailed(error.localizedDescription)))
            throw TransportError.connectionFailed("\(type(of: error)): \(error)")
        }
    }

    private func createSSHChannel() async throws -> Channel {
        let username = config.username
        let password = getPassword()
        let host = config.host
        let port = config.port
        let hostKeyDelegate = KnownHostsDelegate(host: host, port: Int(port))
        let timeoutSeconds = Int64(config.connectionTimeout)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let authDelegate = PasswordAuthDelegate(username: username, password: password)

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
            .connectTimeout(.seconds(timeoutSeconds))

        do {
            let channel = try await bootstrap.connect(host: host, port: Int(port)).get()
            return channel
        } catch {
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

        // Error callback to update transport state when the shell channel fails
        let errorCallback: @Sendable (Error) -> Void = { [weak self] error in
            guard let self = self else { return }
            Task {
                await self.stateActor.setState(.error(TransportError.connectionFailed(error.localizedDescription)))
            }
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
                        ShellDataHandler(onData: dataCallback, onError: errorCallback)
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
        // Deliver via callback state - will buffer if no callback yet, or deliver
        // to either the primary callback (from setDataCallback) or secondary callback (from dataStream)
        dataCallbackState.deliverData(data)
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
        if !attemptedPassword && availableMethods.contains(.password) {
            attemptedPassword = true
            nextChallengePromise.succeed(.init(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            ))
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

/// Host key validation using Trust On First Use (TOFU) model.
/// First connection to a host: accept and store the key in Keychain.
/// Subsequent connections: verify against stored key; reject on mismatch.
final class KnownHostsDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let keychainKey = "com.willo.knownhost.\(host):\(port)"
        let hostKeyData: Data
        do {
            let encoder = JSONEncoder()
            hostKeyData = try encoder.encode(CodableNIOSSHPublicKey(hostKey))
        } catch {
            validationCompletePromise.fail(TransportError.connectionFailed("Failed to encode host key"))
            return
        }

        // Try to retrieve stored host key from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecAttrService as String: "com.willo.knownhosts",
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let storedData = result as? Data {
            // We have a stored key — verify it matches
            if storedData == hostKeyData {
                validationCompletePromise.succeed(())
            } else {
                logger.error("Host key mismatch for \(self.host, privacy: .public):\(self.port) — possible MITM attack")
                validationCompletePromise.fail(TransportError.connectionFailed(
                    "Host key for \(host):\(port) has changed. This could indicate a man-in-the-middle attack. " +
                    "If the server was reinstalled, remove the old key in Settings."
                ))
            }
        } else {
            // No stored key — Trust On First Use: accept and store
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: keychainKey,
                kSecAttrService as String: "com.willo.knownhosts",
                kSecValueData as String: hostKeyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess || addStatus == errSecDuplicateItem {
                logger.info("Stored host key for \(self.host, privacy: .public):\(self.port) (TOFU)")
                validationCompletePromise.succeed(())
            } else {
                logger.warning("Failed to store host key (status: \(addStatus)), accepting anyway")
                validationCompletePromise.succeed(())
            }
        }
    }

    /// Remove the stored host key for a host (for key rotation or reinstall)
    static func removeHostKey(host: String, port: Int) {
        let keychainKey = "com.willo.knownhost.\(host):\(port)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecAttrService as String: "com.willo.knownhosts"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Wrapper for encoding NIOSSHPublicKey as JSON data for Keychain storage
private struct CodableNIOSSHPublicKey: Codable {
    let keyType: String
    let keyData: Data

    init(_ key: NIOSSHPublicKey) {
        self.keyType = "\(type(of: key))"
        // Use the key's string description as stable serialization
        self.keyData = Data(String(describing: key).utf8)
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
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
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
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // TODO: Implement SSH key loading from common paths
        nextChallengePromise.succeed(nil)
    }
}

// MARK: - Channel Handlers

/// Handler for shell session data
final class ShellDataHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    let onData: @Sendable (Data) -> Void
    let onError: @Sendable (Error) -> Void

    init(onData: @escaping @Sendable (Data) -> Void, onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.onData = onData
        self.onError = onError
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = channelData.data else { return }

        if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
            onData(data)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Shell channel error: \(error.localizedDescription, privacy: .public)")
        onError(error)
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

// MARK: - Bridge Channel Support

/// Handle for a long-running SSH exec channel (bidirectional)
/// Used for Zellij bridge pipe communication
final class BridgeChannelHandle: @unchecked Sendable {
    private let nioChannel: Channel
    private let onDataCallback: @Sendable (Data) -> Void
    private let onCloseCallback: @Sendable () -> Void
    private var earlyDataBuffer: [Data] = []
    private var isReady = false
    private var isClosed = false
    private let lock = NSLock()

    init(
        channel: Channel,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.nioChannel = channel
        self.onDataCallback = onData
        self.onCloseCallback = onClose
    }

    /// Called by channel handler when data arrives
    /// Thread-safe: may be called from NIO event loop
    func receiveData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        if isReady {
            onDataCallback(data)
        } else {
            // Buffer data that arrives before we're ready
            earlyDataBuffer.append(data)
        }
    }

    /// Called by channel handler when remote closes the channel
    /// Thread-safe: may be called from NIO event loop
    func notifyClose() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()

        onCloseCallback()
    }

    /// Mark channel as ready and flush buffered data
    func markReady() {
        lock.lock()
        let buffered = earlyDataBuffer
        earlyDataBuffer = []
        isReady = true
        lock.unlock()

        // Deliver buffered data
        for data in buffered {
            onDataCallback(data)
        }
    }

    /// Write data to stdin of the remote process
    func write(_ data: Data) async throws {
        var buffer = nioChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        try await nioChannel.writeAndFlush(channelData).get()
    }

    /// Close the channel
    func close() {
        nioChannel.close(promise: nil)
    }
}

/// Handler for bridge channel data (bidirectional exec channel)
final class BridgeDataHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private weak var handle: BridgeChannelHandle?

    init(handle: BridgeChannelHandle) {
        self.handle = handle
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = channelData.data else { return }

        if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
            handle?.receiveData(data)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        handle?.notifyClose()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Bridge channel error: \(error.localizedDescription, privacy: .public)")
        handle?.notifyClose()
        context.close(promise: nil)
    }
}

// MARK: - NIOSSHTransport Bridge Extension

extension NIOSSHTransport {
    /// Open a long-running exec channel for bidirectional communication
    /// Unlike executeCommand(), this keeps the channel open for streaming
    ///
    /// - Parameters:
    ///   - command: The command to execute (e.g., zellij pipe command)
    ///   - onData: Callback for received data - passed upfront to avoid early-data race
    ///   - onClose: Callback when remote closes the channel
    /// - Returns: Handle for the channel that can be used for bidirectional communication
    func openBridgeChannel(
        command: String,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void = {}
    ) async throws -> BridgeChannelHandle {
        guard let channel = channel else {
            throw TransportError.notConnected
        }

        // Get SSH handler on the event loop
        let sshHandler = try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        }.get()

        // We'll create the handle after we have the child channel
        // Use a class wrapper to safely capture the handle from the closure
        final class HandleBox: @unchecked Sendable {
            var handle: BridgeChannelHandle?
        }
        let handleBox = HandleBox()

        // Create child channel on the event loop
        let childChannel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
            channel.eventLoop.execute {
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }

                sshHandler.createChannel(promise) { [onData, onClose] childChannel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(TransportError.connectionFailed("Invalid channel type"))
                    }

                    // Create handle with callbacks passed upfront
                    let handle = BridgeChannelHandle(
                        channel: childChannel,
                        onData: onData,
                        onClose: onClose
                    )
                    handleBox.handle = handle

                    return childChannel.pipeline.addHandlers([
                        BridgeDataHandler(handle: handle)
                    ])
                }
            }
        }

        guard let bridgeHandle = handleBox.handle else {
            throw TransportError.connectionFailed("Bridge channel handle was not created")
        }

        // Execute the command
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        try await childChannel.triggerUserOutboundEvent(execRequest).get()

        // Mark handle as ready - flushes any early data
        bridgeHandle.markReady()

        return bridgeHandle
    }
}
