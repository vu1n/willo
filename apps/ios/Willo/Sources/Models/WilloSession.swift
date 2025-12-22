import Foundation
import SwiftUI

// MARK: - Device Origin

/// Tracks which device type created a session
enum DeviceOrigin: String, Codable, CaseIterable {
    case phone
    case tablet
    case desktop

    var icon: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .desktop: return "desktopcomputer"
        }
    }

    var displayName: String {
        switch self {
        case .phone: return "Phone"
        case .tablet: return "Tablet"
        case .desktop: return "Desktop"
        }
    }

    /// Detect current device type
    static var current: DeviceOrigin {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return .phone
        case .pad: return .tablet
        default: return .desktop
        }
        #else
        return .desktop
        #endif
    }
}

// MARK: - Layout Template

/// Represents a zellij layout template
struct LayoutTemplate: Identifiable, Equatable {
    let id: String  // filename without extension
    let name: String
    let description: String
    let icon: String
    let suitableFor: Set<DeviceOrigin>
    let kdlContent: String

    /// Short hash of content for cache invalidation (changes when layout is updated)
    var contentHash: String {
        // Simple hash using first 8 chars of content hash
        let hash = kdlContent.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return String(format: "%08x", abs(hash))
    }

    /// Built-in layout templates
    static let builtIn: [LayoutTemplate] = [
        LayoutTemplate(
            id: "focus",
            name: "Focus",
            description: "Single pane, distraction-free",
            icon: "scope",
            suitableFor: [.phone, .tablet, .desktop],
            kdlContent: """
            layout {
                pane size=1 borderless=true {
                    plugin location="compact-bar"
                }
                pane focus=true
            }
            """
        ),
        LayoutTemplate(
            id: "split",
            name: "Split",
            description: "Main workspace + output",
            icon: "rectangle.split.2x1",
            suitableFor: [.tablet, .desktop],
            kdlContent: """
            layout {
                pane size=1 borderless=true {
                    plugin location="compact-bar"
                }
                pane split_direction="horizontal" {
                    pane size="60%" focus=true name="main"
                    pane size="40%" name="output"
                }
            }
            """
        ),
        LayoutTemplate(
            id: "monitor",
            name: "Monitor",
            description: "Stacked panes for monitoring",
            icon: "square.stack.3d.up",
            suitableFor: [.tablet, .desktop],
            kdlContent: """
            layout {
                pane size=1 borderless=true {
                    plugin location="compact-bar"
                }
                pane stacked=true {
                    pane name="server-1" focus=true
                    pane name="server-2"
                    pane name="server-3"
                    pane name="logs"
                }
            }
            """
        ),
        LayoutTemplate(
            id: "dev",
            name: "Dev",
            description: "Editor + terminal + output",
            icon: "rectangle.split.3x1",
            suitableFor: [.tablet, .desktop],
            kdlContent: """
            layout {
                pane size=1 borderless=true {
                    plugin location="compact-bar"
                }
                pane split_direction="vertical" {
                    pane size="65%" focus=true name="editor"
                    pane size="35%" split_direction="horizontal" {
                        pane size="50%" name="terminal"
                        pane size="50%" name="output"
                    }
                }
            }
            """
        ),
        LayoutTemplate(
            id: "dashboard",
            name: "Dashboard",
            description: "4-pane grid overview",
            icon: "square.grid.2x2",
            suitableFor: [.tablet, .desktop],
            kdlContent: """
            layout {
                pane size=1 borderless=true {
                    plugin location="compact-bar"
                }
                pane split_direction="horizontal" {
                    pane split_direction="vertical" {
                        pane name="top-left" focus=true
                        pane name="bottom-left"
                    }
                    pane split_direction="vertical" {
                        pane name="top-right"
                        pane name="bottom-right"
                    }
                }
            }
            """
        ),
        LayoutTemplate(
            id: "tabs-dev",
            name: "Tabs Dev",
            description: "Multi-tab: code, git, server",
            icon: "rectangle.stack",
            suitableFor: [.tablet, .desktop],
            kdlContent: """
            layout {
                default_tab_template {
                    pane size=1 borderless=true {
                        plugin location="compact-bar"
                    }
                    children
                }
                tab name="code" focus=true {
                    pane split_direction="vertical" {
                        pane size="70%" name="editor"
                        pane size="30%" name="terminal"
                    }
                }
                tab name="git" {
                    pane name="git"
                }
                tab name="server" {
                    pane stacked=true {
                        pane name="logs"
                        pane name="processes"
                    }
                }
            }
            """
        )
    ]

    /// Get layouts suitable for current device
    static func forCurrentDevice() -> [LayoutTemplate] {
        let current = DeviceOrigin.current
        return builtIn.filter { $0.suitableFor.contains(current) }
    }

    /// Get layouts suitable for a specific device
    static func forDevice(_ device: DeviceOrigin) -> [LayoutTemplate] {
        builtIn.filter { $0.suitableFor.contains(device) }
    }
}

// MARK: - Willo Session

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
    var deviceOrigin: DeviceOrigin
    var layoutId: String?

    init(
        id: UUID = UUID(),
        serverProfile: ServerProfile,
        name: String,
        description: String = "",
        color: SessionColor = .cyan,
        connectionState: ConnectionState = .disconnected,
        activityState: ActivityState = .idle,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        deviceOrigin: DeviceOrigin = .current,
        layoutId: String? = nil
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
        self.deviceOrigin = deviceOrigin
        self.layoutId = layoutId
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
        case deviceOrigin, layoutId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        color = try container.decode(SessionColor.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        deviceOrigin = try container.decodeIfPresent(DeviceOrigin.self, forKey: .deviceOrigin) ?? .current
        layoutId = try container.decodeIfPresent(String.self, forKey: .layoutId)

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
        try container.encode(deviceOrigin, forKey: .deviceOrigin)
        try container.encodeIfPresent(layoutId, forKey: .layoutId)
    }
}
