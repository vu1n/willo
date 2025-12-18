import Foundation

/// Protocol defining terminal transport interface
///
/// Transports provide the communication layer between the terminal emulator
/// and remote servers (SSH, Mosh, etc.)
protocol TerminalTransport: AnyObject {
    /// Connection state (async due to actor isolation)
    var state: TransportState { get async }

    /// Async stream of state changes
    var stateStream: AsyncStream<TransportState> { get }

    /// Async stream of data received from remote
    var dataStream: AsyncStream<Data> { get }

    /// Connect to the remote server
    func connect() async throws

    /// Disconnect from the remote server
    func disconnect() async throws

    /// Send data to the remote server
    func send(_ data: Data) async throws

    /// Resize the remote terminal
    func resize(cols: UInt16, rows: UInt16) async throws
}

/// Transport connection state
enum TransportState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(TransportError)

    static func == (lhs: TransportState, rhs: TransportState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.reconnecting, .reconnecting):
            return true
        case (.error(let lhsError), .error(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

/// Transport errors
enum TransportError: LocalizedError {
    case connectionFailed(String)
    case authenticationFailed(String)
    case timeout
    case networkUnavailable
    case hostUnreachable
    case invalidCredentials
    case protocolError(String)
    case disconnected
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .timeout:
            return "Connection timed out"
        case .networkUnavailable:
            return "Network unavailable"
        case .hostUnreachable:
            return "Host unreachable"
        case .invalidCredentials:
            return "Invalid credentials"
        case .protocolError(let reason):
            return "Protocol error: \(reason)"
        case .disconnected:
            return "Disconnected"
        case .notConnected:
            return "Not connected"
        }
    }
}

/// Configuration for transport connections
struct TransportConfig {
    let host: String
    let port: UInt16
    let username: String
    let authMethod: AuthMethod

    /// Terminal size
    var terminalCols: UInt16 = 80
    var terminalRows: UInt16 = 24

    /// Connection timeout in seconds
    var connectionTimeout: TimeInterval = 30

    /// Enable keep-alive
    var keepAlive: Bool = true
    var keepAliveInterval: TimeInterval = 60

    enum AuthMethod {
        case password(String)
        case publicKey(privateKey: Data, passphrase: String?)
        case agent
    }
}

/// Extension for async stream helpers
extension TerminalTransport {
    /// Wait for connection to be established
    func waitForConnection(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        for await state in stateStream {
            if Date() > deadline {
                throw TransportError.timeout
            }

            switch state {
            case .connected:
                return
            case .error(let error):
                throw error
            case .disconnected:
                throw TransportError.disconnected
            default:
                continue
            }
        }
    }
}
