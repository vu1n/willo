import Foundation
import Darwin

/// PTY Bridge for connecting Ghostty terminal to external transports
///
/// Creates a pseudo-terminal pair and manages bidirectional I/O between
/// the terminal emulator and a transport (SSH, Mosh, etc.)
///
/// Architecture:
/// ```
/// ┌─────────────┐   slave   ┌─────────────┐   master   ┌─────────────┐
/// │   Ghostty   │◄─────────►│     PTY     │◄──────────►│   Bridge    │
/// │   Surface   │           │    Pair     │            │   (this)    │
/// └─────────────┘           └─────────────┘            └─────────────┘
///                                                            │
///                                                            ▼
///                                                      ┌─────────────┐
///                                                      │  Transport  │
///                                                      │ (SSH/Mosh)  │
///                                                      └─────────────┘
/// ```
///
/// NOTE: On iOS, PTY creation is possible but sandboxed. This bridge is designed
/// to work within iOS constraints where possible.
final class PTYBridge: @unchecked Sendable {
    /// Master file descriptor (our side)
    private(set) var masterFD: Int32 = -1

    /// Slave file descriptor (Ghostty's side)
    private(set) var slaveFD: Int32 = -1

    /// Slave device path (for passing to Ghostty)
    private(set) var slavePath: String?

    /// Read buffer size
    private let bufferSize = 16384

    /// Whether the bridge is active
    private var isActive = false

    /// Read task
    private var readTask: Task<Void, Never>?

    /// Callback for data received from terminal (user input to send to server)
    var onTerminalInput: ((Data) -> Void)?

    /// Continuation for data stream
    private var dataContinuation: AsyncStream<Data>.Continuation?

    /// Async stream of data from terminal
    lazy var terminalInputStream: AsyncStream<Data> = {
        AsyncStream { continuation in
            self.dataContinuation = continuation
        }
    }()

    init() {}

    deinit {
        close()
    }

    // MARK: - PTY Creation

    /// Open a new PTY pair
    func open() throws {
        guard masterFD == -1 else {
            throw PTYError.alreadyOpen
        }

        // Open master PTY
        masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else {
            throw PTYError.openFailed(errno: errno)
        }

        // Grant access to slave
        guard grantpt(masterFD) == 0 else {
            Darwin.close(masterFD)
            masterFD = -1
            throw PTYError.grantFailed(errno: errno)
        }

        // Unlock slave
        guard unlockpt(masterFD) == 0 else {
            Darwin.close(masterFD)
            masterFD = -1
            throw PTYError.unlockFailed(errno: errno)
        }

        // Get slave path
        guard let pathPtr = ptsname(masterFD) else {
            Darwin.close(masterFD)
            masterFD = -1
            throw PTYError.ptsnameFailed(errno: errno)
        }
        slavePath = String(cString: pathPtr)

        // Open slave
        guard let path = slavePath else {
            Darwin.close(masterFD)
            masterFD = -1
            throw PTYError.noSlavePath
        }

        slaveFD = Darwin.open(path, O_RDWR)
        guard slaveFD >= 0 else {
            Darwin.close(masterFD)
            masterFD = -1
            throw PTYError.slaveOpenFailed(errno: errno)
        }

        isActive = true
    }

    /// Close the PTY pair
    func close() {
        isActive = false
        readTask?.cancel()
        readTask = nil

        if slaveFD >= 0 {
            Darwin.close(slaveFD)
            slaveFD = -1
        }

        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }

        slavePath = nil
        dataContinuation?.finish()
    }

    // MARK: - I/O Operations

    /// Start reading from PTY master (captures terminal input from user)
    func startReading() {
        guard isActive, masterFD >= 0 else { return }

        readTask = Task { [weak self] in
            guard let self = self else { return }

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.bufferSize)
            defer { buffer.deallocate() }

            while !Task.isCancelled && self.isActive {
                let bytesRead = read(self.masterFD, buffer, self.bufferSize)

                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    self.dataContinuation?.yield(data)
                    self.onTerminalInput?(data)
                } else if bytesRead == 0 {
                    // EOF
                    break
                } else if errno == EAGAIN || errno == EINTR {
                    // Non-blocking or interrupted, continue
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                } else {
                    // Error
                    break
                }
            }
        }
    }

    /// Write data to PTY master (sends server output to terminal)
    func write(_ data: Data) throws {
        guard isActive, masterFD >= 0 else {
            throw PTYError.notOpen
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var totalWritten = 0
            let count = buffer.count

            while totalWritten < count {
                let written = Darwin.write(
                    masterFD,
                    baseAddress.advanced(by: totalWritten),
                    count - totalWritten
                )

                if written > 0 {
                    totalWritten += written
                } else if errno == EAGAIN || errno == EINTR {
                    // Would block or interrupted, retry
                    continue
                } else {
                    throw PTYError.writeFailed(errno: errno)
                }
            }
        }
    }

    /// Write string to PTY master
    func write(_ string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw PTYError.encodingFailed
        }
        try write(data)
    }

    // MARK: - Terminal Configuration

    /// Set terminal size
    func setSize(cols: UInt16, rows: UInt16) throws {
        guard isActive, masterFD >= 0 else {
            throw PTYError.notOpen
        }

        var size = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else {
            throw PTYError.resizeFailed(errno: errno)
        }
    }

    /// Configure terminal attributes
    func configureTerminal() throws {
        guard isActive, slaveFD >= 0 else {
            throw PTYError.notOpen
        }

        var term = termios()

        // Get current attributes
        guard tcgetattr(slaveFD, &term) == 0 else {
            throw PTYError.tcgetattrFailed(errno: errno)
        }

        // Set raw mode (disable echo, canonical mode, etc.)
        // This is typically what terminal emulators expect
        cfmakeraw(&term)

        // Set the attributes
        guard tcsetattr(slaveFD, TCSANOW, &term) == 0 else {
            throw PTYError.tcsetattrFailed(errno: errno)
        }
    }
}

// MARK: - Errors

enum PTYError: LocalizedError {
    case alreadyOpen
    case notOpen
    case openFailed(errno: Int32)
    case grantFailed(errno: Int32)
    case unlockFailed(errno: Int32)
    case ptsnameFailed(errno: Int32)
    case noSlavePath
    case slaveOpenFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case resizeFailed(errno: Int32)
    case tcgetattrFailed(errno: Int32)
    case tcsetattrFailed(errno: Int32)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .alreadyOpen:
            return "PTY is already open"
        case .notOpen:
            return "PTY is not open"
        case .openFailed(let errno):
            return "Failed to open PTY master: \(String(cString: strerror(errno)))"
        case .grantFailed(let errno):
            return "Failed to grant PTY: \(String(cString: strerror(errno)))"
        case .unlockFailed(let errno):
            return "Failed to unlock PTY: \(String(cString: strerror(errno)))"
        case .ptsnameFailed(let errno):
            return "Failed to get slave path: \(String(cString: strerror(errno)))"
        case .noSlavePath:
            return "No slave path available"
        case .slaveOpenFailed(let errno):
            return "Failed to open PTY slave: \(String(cString: strerror(errno)))"
        case .writeFailed(let errno):
            return "Failed to write to PTY: \(String(cString: strerror(errno)))"
        case .readFailed(let errno):
            return "Failed to read from PTY: \(String(cString: strerror(errno)))"
        case .resizeFailed(let errno):
            return "Failed to resize PTY: \(String(cString: strerror(errno)))"
        case .tcgetattrFailed(let errno):
            return "Failed to get terminal attributes: \(String(cString: strerror(errno)))"
        case .tcsetattrFailed(let errno):
            return "Failed to set terminal attributes: \(String(cString: strerror(errno)))"
        case .encodingFailed:
            return "Failed to encode string"
        }
    }
}

// MARK: - Transport Bridge

/// Bridges a PTY to a TerminalTransport
///
/// This class coordinates bidirectional data flow between
/// a PTY (connected to Ghostty) and a transport (SSH/Mosh)
final class TransportPTYBridge {
    private let pty: PTYBridge
    private let transport: TerminalTransport

    private var transportReadTask: Task<Void, Never>?
    private var ptyReadTask: Task<Void, Never>?

    init(pty: PTYBridge, transport: TerminalTransport) {
        self.pty = pty
        self.transport = transport
    }

    deinit {
        stop()
    }

    /// Start bidirectional bridging
    func start() {
        // Read from transport, write to PTY (server output → terminal)
        transportReadTask = Task { [weak self] in
            guard let self = self else { return }

            for await data in self.transport.dataStream {
                do {
                    try self.pty.write(data)
                } catch {
                    print("Failed to write to PTY: \(error)")
                }
            }
        }

        // Read from PTY, send to transport (user input → server)
        ptyReadTask = Task { [weak self] in
            guard let self = self else { return }

            for await data in self.pty.terminalInputStream {
                do {
                    try await self.transport.send(data)
                } catch {
                    print("Failed to send to transport: \(error)")
                }
            }
        }

        pty.startReading()
    }

    /// Stop bridging
    func stop() {
        transportReadTask?.cancel()
        ptyReadTask?.cancel()
        transportReadTask = nil
        ptyReadTask = nil
    }

    /// Resize terminal
    func resize(cols: UInt16, rows: UInt16) async throws {
        try pty.setSize(cols: cols, rows: rows)
        try await transport.resize(cols: cols, rows: rows)
    }
}
