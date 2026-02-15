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
        startupBehavior: StartupBehavior = .namedSession,
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
    case password  // Password stored in Keychain, keyed by profile ID
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

    // MARK: - Codable migration

    /// Custom decoding to handle migration from old `.password(String)` format
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try decoding the new enum format first
        if let stringValue = try? container.decode(String.self) {
            switch stringValue {
            case "password":
                self = .password
            case "agent":
                self = .agent
            default:
                self = .agent
            }
            return
        }

        // Fall back to the keyed container format
        enum CodingKeys: String, CodingKey {
            case password, key, agent
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if keyed.contains(.password) {
            // Old format stored the password string — migrate by discarding it.
            // The password should have been migrated to Keychain separately.
            _ = try? keyed.decode(String.self, forKey: .password)
            self = .password
        } else if keyed.contains(.key) {
            let keyId = try? keyed.decode(UUID?.self, forKey: .key)
            self = .key(keyId: keyId ?? nil)
        } else {
            self = .agent
        }
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
    case attachLast     // Attach to most recent session, or create if none
    case pickSession    // Show session picker (zellij's built-in UI)
    case namedSession   // Create/attach to session matching Willo tab name

    var displayName: String {
        switch self {
        case .bareShell: return "Bare Shell"
        case .attachLast: return "Attach/Create"
        case .pickSession: return "Pick Session"
        case .namedSession: return "Named Session"
        }
    }

    var description: String {
        switch self {
        case .bareShell: return "Just connect, no multiplexer"
        case .attachLast: return "Attach to existing or create new"
        case .pickSession: return "Show list of existing sessions"
        case .namedSession: return "Session name matches tab label"
        }
    }

    /// Returns the shell command to execute for the given multiplexer
    /// - Parameters:
    ///   - multiplexer: The multiplexer preference
    ///   - sessionName: Session name for namedSession behavior (matches Willo tab)
    func command(for multiplexer: MultiplexerPreference, sessionName: String? = nil) -> String? {
        switch self {
        case .bareShell:
            return nil
        case .attachLast:
            switch multiplexer {
            // Attach to last session, or create if none exists
            case .zellij: return "zellij attach || zellij"
            case .tmux: return "tmux attach || tmux new-session"
            case .none: return nil
            }
        case .pickSession:
            switch multiplexer {
            // Just run attach - zellij/tmux will show session picker if multiple exist
            case .zellij: return "zellij attach"
            case .tmux: return "tmux attach"
            case .none: return nil
            }
        case .namedSession:
            guard let name = sessionName, !name.isEmpty else {
                // Fallback to attachLast if no name provided
                return command(for: multiplexer, sessionName: nil)
            }
            switch multiplexer {
            // Create or attach to session with specific name
            // -c flag creates if doesn't exist, attaches if it does
            case .zellij: return "zellij attach -c \"\(name)\""
            case .tmux: return "tmux new-session -A -s \"\(name)\""
            case .none: return nil
            }
        }
    }
}
