import Foundation
import SwiftUI

/// Represents a terminal session in Willo
/// Each session corresponds to a multiplexer session (zellij/tmux) on a server
struct WilloSession: Identifiable, Equatable {
    let id: UUID
    let serverProfile: ServerProfile
    var name: String
    var description: String
    var color: SessionColor
    var connectionState: ConnectionState
    var activityState: ActivityState
    var createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        serverProfile: ServerProfile,
        name: String,
        description: String = "",
        color: SessionColor = .cyan,
        connectionState: ConnectionState = .disconnected,
        activityState: ActivityState = .idle,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.serverProfile = serverProfile
        self.name = name
        self.description = description
        self.color = color
        self.connectionState = connectionState
        self.activityState = activityState
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    /// Create from a server profile with auto-generated session name
    static func create(from profile: ServerProfile, color: SessionColor? = nil) -> WilloSession {
        let sessionName = profile.sessionTemplate
            .replacingOccurrences(of: "{user}", with: profile.username)
            .replacingOccurrences(of: "{host}", with: profile.hostname.components(separatedBy: ".").first ?? profile.hostname)
            .replacingOccurrences(of: "{project}", with: "willo")
            .replacingOccurrences(of: "{env}", with: "dev")
            .replacingOccurrences(of: "{role}", with: "terminal")

        return WilloSession(
            serverProfile: profile,
            name: sessionName,
            description: "\(profile.username)@\(profile.hostname)",
            color: color ?? SessionColor.allCases.randomElement() ?? .cyan
        )
    }

    var displayTitle: String {
        name.isEmpty ? serverProfile.displayName : name
    }

    var subtitle: String {
        description.isEmpty ? serverProfile.connectionString : description
    }

    /// Time since last activity, formatted
    var lastActivityText: String {
        let interval = Date().timeIntervalSince(lastActivityAt)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval / 3600))h"
        }
    }
}

// MARK: - Session Color

enum SessionColor: String, CaseIterable, Codable {
    case cyan
    case amber
    case green
    case magenta
    case blue
    case red

    var color: Color {
        switch self {
        case .cyan: return .terminalCyan
        case .amber: return .terminalAmber
        case .green: return .terminalGreen
        case .magenta: return .terminalMagenta
        case .blue: return .terminalBlue
        case .red: return .terminalRed
        }
    }

    var name: String {
        rawValue.capitalized
    }
}

// MARK: - Activity State

enum ActivityState: Equatable {
    case idle                    // No recent output
    case active                  // Currently being viewed
    case hasOutput(count: Int)   // New output since last viewed
    case running                 // Command in progress
    case error                   // Last command failed

    var hasUnread: Bool {
        if case .hasOutput = self { return true }
        return false
    }

    var unreadCount: Int {
        if case .hasOutput(let count) = self { return count }
        return 0
    }

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .active: return "circle.fill"
        case .hasOutput: return "circle.badge.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var statusColor: Color {
        switch self {
        case .idle: return .textTertiary
        case .active: return .terminalGreen
        case .hasOutput: return .terminalRed
        case .running: return .terminalAmber
        case .error: return .terminalRed
        }
    }
}

// MARK: - Session Persistence

extension WilloSession: Codable {
    enum CodingKeys: String, CodingKey {
        case id, serverProfileId, name, description, color, createdAt, lastActivityAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        color = try container.decode(SessionColor.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)

        // Server profile needs to be resolved separately
        // Store the profile ID in a placeholder profile for later resolution
        let profileId = try container.decode(UUID.self, forKey: .serverProfileId)
        serverProfile = ServerProfile(
            id: profileId,  // Preserve ID for resolution
            displayName: "Loading...",
            hostname: "",
            username: ""
        )
        connectionState = .disconnected
        activityState = .idle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(serverProfile.id, forKey: .serverProfileId)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(color, forKey: .color)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastActivityAt, forKey: .lastActivityAt)
    }
}
