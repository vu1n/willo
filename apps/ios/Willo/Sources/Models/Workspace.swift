import Foundation

struct Workspace: Identifiable, Equatable {
    let id: UUID
    let serverProfile: ServerProfile
    var sessionName: String
    var connectionState: ConnectionState

    init(
        id: UUID = UUID(),
        serverProfile: ServerProfile,
        sessionName: String,
        connectionState: ConnectionState = .disconnected
    ) {
        self.id = id
        self.serverProfile = serverProfile
        self.sessionName = sessionName
        self.connectionState = connectionState
    }

    var displayTitle: String {
        "\(serverProfile.displayName) · \(sessionName)"
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(error: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var statusColor: String {
        switch self {
        case .disconnected: return "gray"
        case .connecting, .reconnecting: return "yellow"
        case .connected: return "green"
        case .failed: return "red"
        }
    }

    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))..."
        case .failed(let error): return "Failed: \(error)"
        }
    }
}
