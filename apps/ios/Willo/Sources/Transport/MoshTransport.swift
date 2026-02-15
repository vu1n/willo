import Foundation
import mosh
import os.log

private let logger = Logger(subsystem: "com.willo.app", category: "Mosh")

/// Thread-safe state container for MoshTransport
private actor MoshTransportState {
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
private typealias DataCallbackState = TransportDataCallbackState<Data>

/// Mosh Transport using Blink's libmosh xcframework
///
/// Provides Mosh connectivity for mobile-optimized terminal sessions.
/// Uses the battle-tested mosh implementation from Blink Shell.
///
/// Architecture:
/// ```
/// ┌─────────────┐       ┌─────────────┐
/// │   Swift     │◄─────►│  mosh_main  │
/// │  (pipes)    │       │ (libmosh)   │
/// └─────────────┘       └─────────────┘
///       │                     │
///       ▼                     ▼
/// AsyncStream<Data>      UDP/SSP to server
/// ```
final class MoshTransport: TerminalTransport, @unchecked Sendable {
    private let config: TransportConfig
    private let moshKey: String
    private let moshPort: String
    private let stateActor = MoshTransportState()
    private let dataCallbackState = DataCallbackState()

    // Pipes for mosh I/O
    private var inputReadFd: Int32 = -1
    private var inputWriteFd: Int32 = -1
    private var outputReadFd: Int32 = -1
    private var outputWriteFd: Int32 = -1

    // Thread for mosh_main (using pthread_create like Blink, not GCD)
    private var moshThread: pthread_t?
    private let isRunningLock = NSLock()
    private var _isRunning = false
    private var isRunning: Bool {
        get { isRunningLock.lock(); defer { isRunningLock.unlock() }; return _isRunning }
        set { isRunningLock.lock(); _isRunning = newValue; isRunningLock.unlock() }
    }

    /// Terminal size
    private var terminalCols: UInt16
    private var terminalRows: UInt16

    /// Window size pointer - explicitly allocated so mosh and Swift share the same memory
    /// Must remain valid for the lifetime of the mosh session
    private var windowSizePtr: UnsafeMutablePointer<winsize>?
    private let windowSizeLock = NSLock()

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
            dataCallbackState.setSecondaryCallback { data in
                continuation.yield(data)
            }
            continuation.onTermination = { _ in
                dataCallbackState.clearCallback()
            }
        }
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

    /// Initialize the streams - must be called before connect()
    func initializeStreams() {
        _ = stateStream
        // Note: dataStream is no longer lazy, so no need to access it here
    }

    /// Initialize Mosh transport
    /// - Parameters:
    ///   - config: Base transport configuration (host used for connection)
    ///   - moshKey: The MOSH_KEY from server bootstrap
    ///   - moshPort: The UDP port from server bootstrap (e.g., "60001")
    init(config: TransportConfig, moshKey: String, moshPort: String) {
        self.config = config
        self.moshKey = moshKey
        self.moshPort = moshPort
        self.terminalCols = config.terminalCols
        self.terminalRows = config.terminalRows
    }

    deinit {
        deallocateWindowSize()
        closePipes()
    }

    /// Thread-safe deallocation of windowSizePtr — single deallocation site
    private func deallocateWindowSize() {
        windowSizeLock.lock()
        defer { windowSizeLock.unlock() }
        windowSizePtr?.deallocate()
        windowSizePtr = nil
    }

    // MARK: - Connection

    func connect() async throws {
        guard await stateActor.state == .disconnected else { return }

        await stateActor.setState(.connecting)
        logger.info("Connecting to \(self.config.host, privacy: .public):\(self.moshPort, privacy: .public)")

        // Create pipes for I/O
        var inputFds: [Int32] = [0, 0]
        var outputFds: [Int32] = [0, 0]

        guard pipe(&inputFds) == 0, pipe(&outputFds) == 0 else {
            throw TransportError.connectionFailed("Failed to create pipes: \(String(cString: strerror(errno)))")
        }

        inputReadFd = inputFds[0]   // mosh reads from here
        inputWriteFd = inputFds[1]  // we write here
        outputReadFd = outputFds[0] // we read from here
        outputWriteFd = outputFds[1] // mosh writes here

        // Start reading output in background — first data arrival marks us as connected
        startOutputReader()

        // Run mosh_main on a pthread (not GCD) - required for SIGWINCH to work
        isRunning = true

        // Use passUnretained since the transport's lifecycle is managed externally.
        // The isRunning flag ensures the thread exits if the transport is deallocated.
        var thread: pthread_t?
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let result = pthread_create(&thread, nil, { context -> UnsafeMutableRawPointer? in
            let transport = Unmanaged<MoshTransport>.fromOpaque(context).takeRetainedValue()
            transport.runMosh()
            return nil
        }, selfPtr)

        if result != 0 {
            Unmanaged<MoshTransport>.fromOpaque(selfPtr).release()
            throw TransportError.connectionFailed("Failed to create mosh thread: \(result)")
        }

        moshThread = thread

        if let thread = thread {
            pthread_detach(thread)
        }

        // Wait for first data or timeout to determine connection status.
        // The connected state is set by startOutputReader when first data arrives.
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3s for UDP handshake

        let currentState = await stateActor.state
        if case .connecting = currentState {
            // Still connecting after timeout — mark connected optimistically
            // (mosh handles reconnection internally)
            await stateActor.setState(.connected)
        }
    }

    private func runMosh() {
        // Convert file descriptors to FILE*
        guard let f_in = fdopen(inputReadFd, "r"),
              let f_out = fdopen(outputWriteFd, "w") else {
            logger.error("Failed to fdopen file descriptors")
            Task { [weak self] in
                await self?.stateActor.setState(.error(TransportError.connectionFailed("Failed to open file handles")))
            }
            return
        }

        // Mark FDs as owned by FILE* now — fclose() will close them,
        // so prevent closePipes() from double-closing
        inputReadFd = -1
        outputWriteFd = -1

        // Disable buffering on output so data flows immediately
        setvbuf(f_out, nil, _IONBF, 0)

        // Allocate window size struct - must be explicitly allocated so mosh
        // and Swift share the same memory when we update it for SIGWINCH
        let wsPtr = UnsafeMutablePointer<winsize>.allocate(capacity: 1)
        wsPtr.pointee = winsize(
            ws_row: terminalRows,
            ws_col: terminalCols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        windowSizeLock.lock()
        windowSizePtr = wsPtr
        windowSizeLock.unlock()

        logger.info("Starting mosh session to \(self.config.host, privacy: .public)")

        // Call mosh_main (blocks until session ends)
        let result = mosh_main(
            f_in,
            f_out,
            wsPtr,
            nil,    // state_callback (for session persistence)
            nil,    // state_callback_context
            config.host,
            moshPort,
            moshKey,
            "adaptive",  // predict_mode: always, never, adaptive, experimental
            nil,         // encoded_state_buffer (for resume)
            0,           // encoded_state_size
            nil          // predict_overwrite
        )

        logger.info("mosh_main exited with code: \(result)")

        fclose(f_in)
        fclose(f_out)

        // Clean up allocated memory via centralized method
        deallocateWindowSize()

        moshThread = nil

        Task { [weak self] in
            self?.isRunning = false
            await self?.stateActor.setState(.disconnected)
            self?.dataCallbackState.finish()
        }
    }

    func disconnect() async throws {
        isRunning = false
        moshThread = nil

        deallocateWindowSize()
        closePipes()
        await stateActor.setState(.disconnected)
        dataCallbackState.finish()
    }

    private func closePipes() {
        if inputWriteFd >= 0 { close(inputWriteFd); inputWriteFd = -1 }
        if inputReadFd >= 0 { close(inputReadFd); inputReadFd = -1 }
        if outputWriteFd >= 0 { close(outputWriteFd); outputWriteFd = -1 }
        if outputReadFd >= 0 { close(outputReadFd); outputReadFd = -1 }
    }

    // MARK: - I/O

    func send(_ data: Data) async throws {
        guard inputWriteFd >= 0 else {
            throw TransportError.notConnected
        }

        // Write to input pipe (terminal -> mosh)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(inputWriteFd, bytes.baseAddress, bytes.count)
        }

        if written < 0 {
            throw TransportError.connectionFailed("Write failed: \(String(cString: strerror(errno)))")
        }
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        terminalCols = cols
        terminalRows = rows

        // Update the window size struct that mosh reads on SIGWINCH
        windowSizeLock.lock()
        let ptr = windowSizePtr
        windowSizeLock.unlock()

        if let ptr = ptr {
            ptr.pointee.ws_col = cols
            ptr.pointee.ws_row = rows
        }

        // Send SIGWINCH to the mosh thread to trigger resize handling
        if let thread = moshThread {
            pthread_kill(thread, SIGWINCH)
        }
    }

    // MARK: - Private

    private func startOutputReader() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var receivedFirstData = false

            while self.isRunning && self.outputReadFd >= 0 {
                let bytesRead = read(self.outputReadFd, &buffer, buffer.count)

                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)

                    // Transition to connected on first data received from mosh
                    if !receivedFirstData {
                        receivedFirstData = true
                        Task {
                            await self.stateActor.setState(.connected)
                        }
                    }

                    self.dataCallbackState.deliverData(data)
                } else if bytesRead == 0 {
                    break
                } else if errno != EINTR {
                    logger.error("Output reader error: \(String(cString: strerror(errno)), privacy: .public)")
                    break
                }
            }
        }
    }
}

// MARK: - Mosh Bootstrap Helper

extension MoshTransport {
    /// Result of bootstrapping mosh-server via SSH
    struct BootstrapResult {
        let key: String
        let port: String
    }

    /// Bootstrap a Mosh connection via SSH
    ///
    /// Connects to the server via SSH and runs mosh-server to get the
    /// UDP port and session key needed for the Mosh connection.
    ///
    /// - Parameters:
    ///   - sshTransport: An established SSH transport to the server
    /// - Returns: The mosh key and port from mosh-server
    static func bootstrap(using sshTransport: NIOSSHTransport) async throws -> BootstrapResult {
        // Run mosh-server on the remote host
        // Output format: MOSH CONNECT <port> <base64-key>
        //
        // Example:
        // $ mosh-server new -s -c 256 -l LANG=en_US.UTF-8
        // MOSH CONNECT 60001 2BQZjzv8FJQ+vPKHshEiMA==
        //
        // We use a login shell (-l) to ensure PATH includes Homebrew paths
        // Common locations: /opt/homebrew/bin (Apple Silicon), /usr/local/bin (Intel)

        let command = """
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; \
            mosh-server new -s -c 256 -l LANG=en_US.UTF-8
            """

        let output = try await sshTransport.executeCommand(command)

        guard let result = parseMoshServerOutput(output) else {
            throw TransportError.connectionFailed("Failed to parse mosh-server output: \(output)")
        }

        return result
    }

    /// Parse mosh-server output to extract port and key
    static func parseMoshServerOutput(_ output: String) -> BootstrapResult? {
        // Expected format: MOSH CONNECT <port> <base64-key>
        let lines = output.split(separator: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("MOSH CONNECT") {
                let parts = trimmed.split(separator: " ")
                guard parts.count >= 4 else { continue }

                let port = String(parts[2])
                let key = String(parts[3])

                return BootstrapResult(key: key, port: port)
            }
        }
        return nil
    }
}
