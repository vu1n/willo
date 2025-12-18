import Foundation
import mosh

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

/// Thread-safe container for data callbacks
/// Uses direct callback instead of AsyncStream to avoid multiple consumer issues
private final class DataCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data) -> Void)?
    private var pendingData: [Data] = []  // Buffer for data arriving before callback is set
    private var isPrimaryCallbackSet = false  // Tracks if a direct callback was set (not from dataStream)

    /// Set a primary callback (from setDataCallback). This takes priority over dataStream.
    func setPrimaryCallback(_ cb: @escaping (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        callback = cb
        isPrimaryCallbackSet = true
        // Flush any pending data
        for data in pendingData {
            print("[Mosh] Flushing \(data.count) bytes of pending data")
            cb(data)
        }
        pendingData.removeAll()
    }

    /// Set a secondary callback (from dataStream access). Only works if no primary callback is set.
    func setSecondaryCallback(_ cb: @escaping (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        // Don't overwrite a primary callback
        if isPrimaryCallbackSet {
            print("[Mosh] Ignoring secondary callback - primary callback already set")
            return
        }
        callback = cb
        // Flush any pending data
        for data in pendingData {
            print("[Mosh] Flushing \(data.count) bytes of pending data")
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
            print("[DataCallback] Delivering \(data.count) bytes")
            cb(data)
        } else {
            // Buffer data until callback is available
            print("[Mosh] Buffering \(data.count) bytes (callback not ready)")
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

    // Background queue for mosh_main (blocks until disconnect)
    private let moshQueue = DispatchQueue(label: "com.willo.mosh", qos: .userInteractive)
    private var isRunning = false

    /// Terminal size
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
            print("[Mosh] Creating new data stream subscription")
            // Set secondary callback - won't overwrite a primary callback from setDataCallback
            dataCallbackState.setSecondaryCallback { data in
                continuation.yield(data)
            }
            // Handle stream termination
            continuation.onTermination = { _ in
                print("[Mosh] Data stream terminated, clearing callback")
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
        closePipes()
    }

    // MARK: - Connection

    func connect() async throws {
        guard await stateActor.state == .disconnected else { return }

        await stateActor.setState(.connecting)
        print("[Mosh] Connecting to \(config.host):\(moshPort)")

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

        // Start reading output in background
        startOutputReader()

        // Run mosh_main on background queue
        isRunning = true
        moshQueue.async { [weak self] in
            self?.runMosh()
        }

        // Wait a moment for connection to establish
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let currentState = await stateActor.state
        if currentState != .error(.connectionFailed("")) {
            await stateActor.setState(.connected)
        }
    }

    private func runMosh() {
        // Convert file descriptors to FILE*
        guard let f_in = fdopen(inputReadFd, "r"),
              let f_out = fdopen(outputWriteFd, "w") else {
            print("[Mosh] Failed to fdopen file descriptors")
            Task { [weak self] in
                await self?.stateActor.setState(.error(TransportError.connectionFailed("Failed to open file handles")))
            }
            return
        }

        // Disable buffering on output so data flows immediately
        setvbuf(f_out, nil, _IONBF, 0)

        // Set up window size
        var windowSize = winsize(
            ws_row: terminalRows,
            ws_col: terminalCols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        print("[Mosh] Calling mosh_main with:")
        print("[Mosh]   host: \(config.host)")
        print("[Mosh]   port: \(moshPort)")
        print("[Mosh]   key length: \(moshKey.count)")
        print("[Mosh]   window: \(terminalCols)x\(terminalRows)")

        // Call mosh_main (blocks until session ends)
        let result = mosh_main(
            f_in,
            f_out,
            &windowSize,
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

        print("[Mosh] mosh_main exited with code: \(result)")

        fclose(f_in)
        fclose(f_out)

        Task { [weak self] in
            self?.isRunning = false
            await self?.stateActor.setState(.disconnected)
            self?.dataCallbackState.finish()
        }
    }

    func disconnect() async throws {
        isRunning = false
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
        // Note: Mosh handles resize internally via SIGWINCH
        // For runtime resize during active session, we'd need to signal mosh
        // This is a limitation of the pipe-based approach
    }

    // MARK: - Private

    private func startOutputReader() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            print("[Mosh] Output reader started, fd=\(self.outputReadFd)")

            while self.isRunning && self.outputReadFd >= 0 {
                let bytesRead = read(self.outputReadFd, &buffer, buffer.count)

                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    print("[Mosh] Received \(bytesRead) bytes from mosh")
                    self.dataCallbackState.deliverData(data)
                } else if bytesRead == 0 {
                    // EOF - pipe closed
                    print("[Mosh] Output reader: EOF")
                    break
                } else if errno != EINTR {
                    // Error (not just interrupted)
                    print("[Mosh] Output reader error: \(String(cString: strerror(errno)))")
                    break
                }
            }

            print("[Mosh] Output reader stopped")
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
