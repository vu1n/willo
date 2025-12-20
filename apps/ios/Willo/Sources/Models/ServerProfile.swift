import Foundation

struct ServerProfile: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var multiplexer: MultiplexerPreference
    var startupBehavior: StartupBehavior
    var sessionTemplate: String
    var preferMosh: Bool
    var lastConnected: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .key(keyId: nil),
        multiplexer: MultiplexerPreference = .zellij,
        startupBehavior: StartupBehavior = .newSession,
        sessionTemplate: String = "{project}/{env}/{role}/{host}",
        preferMosh: Bool = true,
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.multiplexer = multiplexer
        self.startupBehavior = startupBehavior
        self.sessionTemplate = sessionTemplate
        self.preferMosh = preferMosh
        self.lastConnected = lastConnected
    }

    var connectionString: String {
        "\(username)@\(hostname):\(port)"
    }
}

enum AuthMethod: Codable, Equatable, Hashable {
    case password(String)  // Store password (TODO: move to Keychain in production)
    case key(keyId: UUID?)
    case agent

    // For Picker compatibility - compare only the case, not associated values
    static func ~= (lhs: AuthMethod, rhs: AuthMethod) -> Bool {
        switch (lhs, rhs) {
        case (.password, .password): return true
        case (.key, .key): return true
        case (.agent, .agent): return true
        default: return false
        }
    }

    var isPassword: Bool {
        if case .password = self { return true }
        return false
    }
}

enum MultiplexerPreference: String, Codable, CaseIterable {
    case zellij
    case tmux
    case none

    var attachCommand: String {
        switch self {
        case .zellij: return "zellij attach -c"
        case .tmux: return "tmux new -A -s"
        case .none: return ""
        }
    }

    var displayName: String {
        switch self {
        case .zellij: return "Zellij"
        case .tmux: return "tmux"
        case .none: return "None"
        }
    }
}

/// What to do after SSH/Mosh connection is established
enum StartupBehavior: String, Codable, CaseIterable {
    case bareShell      // Just connect, no multiplexer
    case attachLast     // Attach to most recent session (zellij attach / tmux attach)
    case newSession     // Create new session with name from template

    var displayName: String {
        switch self {
        case .bareShell: return "Bare Shell"
        case .attachLast: return "Attach Last"
        case .newSession: return "New Session"
        }
    }

    var description: String {
        switch self {
        case .bareShell: return "Just connect, no multiplexer"
        case .attachLast: return "Attach to most recent session"
        case .newSession: return "Create new session with name"
        }
    }

    /// Returns the shell command to execute for the given multiplexer
    /// - Parameters:
    ///   - multiplexer: The multiplexer preference
    ///   - sessionName: Optional session name for new sessions
    ///   - userName: User name for zellij collaborative sessions (prevents duplicate user indicators)
    func command(for multiplexer: MultiplexerPreference, sessionName: String?, userName: String = "willo") -> String? {
        switch self {
        case .bareShell:
            return nil
        case .attachLast:
            switch multiplexer {
            case .zellij: return "zellij attach --user-name \"\(userName)\""
            case .tmux: return "tmux attach || tmux"
            case .none: return nil
            }
        case .newSession:
            guard let name = sessionName else { return nil }
            switch multiplexer {
            case .zellij: return "zellij attach -c \"\(name)\" --user-name \"\(userName)\""
            case .tmux: return "tmux new-session -A -s \"\(name)\""
            case .none: return nil
            }
        }
    }
}
