import Foundation

// MARK: - Protocol Version

/// Bridge protocol version - must match plugin version
let kBridgeProtocolVersion = 1

// MARK: - Shell Escaping

/// Utility for shell-safe string escaping
enum ShellEscape {
    /// Shell-escape a string for safe interpolation in bash
    /// Uses single-quote wrapping with escaped single quotes
    static func escape(_ value: String) -> String {
        // Single-quote wrap with escaped single quotes
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Protocol Envelope (Server -> iPad)

/// Protocol envelope matching plugin output
struct BridgeEnvelope: Codable, Sendable {
    let v: Int
    let session: String
    let ts: Int64
    let type: String
    let payload: BridgePayload

    enum CodingKeys: String, CodingKey {
        case v, session, ts, type, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        session = try container.decode(String.self, forKey: .session)
        ts = try container.decode(Int64.self, forKey: .ts)
        type = try container.decode(String.self, forKey: .type)

        // Decode payload based on type
        switch type {
        case "hello":
            payload = .hello(try container.decode(HelloPayload.self, forKey: .payload))
        case "tabUpdate":
            payload = .tabUpdate(try container.decode(TabUpdatePayload.self, forKey: .payload))
        case "paneUpdate":
            payload = .paneUpdate(try container.decode(PaneUpdatePayload.self, forKey: .payload))
        case "sessionUpdate":
            payload = .sessionUpdate(try container.decode(SessionUpdatePayload.self, forKey: .payload))
        default:
            payload = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(session, forKey: .session)
        try container.encode(ts, forKey: .ts)
        try container.encode(type, forKey: .type)
        // Payload encoding not needed for receive-only
    }
}

// MARK: - Typed Payloads

/// Typed payload enum - no AnyCodable needed
enum BridgePayload: Codable, Sendable {
    case hello(HelloPayload)
    case tabUpdate(TabUpdatePayload)
    case paneUpdate(PaneUpdatePayload)
    case sessionUpdate(SessionUpdatePayload)
    case unknown

    func encode(to encoder: Encoder) throws {
        // Encoding not needed for receive-only payloads
    }

    init(from decoder: Decoder) throws {
        // Should not be called directly - decoding happens in BridgeEnvelope
        self = .unknown
    }
}

struct HelloPayload: Codable, Sendable {
    let pluginVersion: String
    let zellijVersion: String
    let protocolVersion: Int
}

/// Tab update payload - uses ZellijTab from ZellijState.swift
struct TabUpdatePayload: Codable, Sendable {
    let tabs: [ZellijTab]
}

/// Pane update payload - maps tab indices to panes
struct PaneUpdatePayload: Codable, Sendable {
    let panes: [String: [ZellijPane]]

    /// Convert string keys to integer tab indices
    func toManifest() -> [Int: [ZellijPane]] {
        var result: [Int: [ZellijPane]] = [:]
        for (key, panes) in panes {
            if let index = Int(key) {
                result[index] = panes
            }
        }
        return result
    }
}

/// Session update payload
struct SessionUpdatePayload: Codable, Sendable {
    let sessions: [BridgeSessionInfo]
}

// MARK: - Bridge-Specific State Types

/// Information about a Zellij session (from SessionUpdate)
/// Note: This is the bridge's representation, converted to ZellijSession for app use
struct BridgeSessionInfo: Codable, Sendable, Identifiable {
    let name: String
    let isCurrentSession: Bool
    let tabs: [BridgeTabInfo]?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isCurrentSession = "is_current_session"
        case tabs
    }
}

/// Basic tab info from SessionUpdate
struct BridgeTabInfo: Codable, Sendable {
    let name: String
}

// MARK: - Commands (iPad -> Server)

/// Commands sent to plugin via stdin
struct BridgeCommand: Codable, Sendable {
    let v: Int
    let type: String
    var direction: String?
    var paneId: Int?
    var tabId: Int?
    var name: String?
    var layout: String?

    init(v: Int, type: String) {
        self.v = v
        self.type = type
    }

    /// Create a "newPane" command
    static func newPane(direction: PaneDirection? = nil) -> BridgeCommand {
        var cmd = BridgeCommand(v: kBridgeProtocolVersion, type: "newPane")
        cmd.direction = direction?.rawValue
        return cmd
    }

    /// Create a "newTab" command
    static func newTab(name: String? = nil, layout: String? = nil) -> BridgeCommand {
        var cmd = BridgeCommand(v: kBridgeProtocolVersion, type: "newTab")
        cmd.name = name
        cmd.layout = layout
        return cmd
    }

    /// Create a "focus" command
    static func focus(paneId: Int) -> BridgeCommand {
        var cmd = BridgeCommand(v: kBridgeProtocolVersion, type: "focus")
        cmd.paneId = paneId
        return cmd
    }

    /// Create a "focusTab" command
    static func focusTab(tabId: Int) -> BridgeCommand {
        var cmd = BridgeCommand(v: kBridgeProtocolVersion, type: "focusTab")
        cmd.tabId = tabId
        return cmd
    }

    /// Create a "requestSnapshot" command
    static var requestSnapshot: BridgeCommand {
        BridgeCommand(v: kBridgeProtocolVersion, type: "requestSnapshot")
    }

    /// Create a "ping" command for heartbeat
    static var ping: BridgeCommand {
        BridgeCommand(v: kBridgeProtocolVersion, type: "ping")
    }

    /// Create an "applyLayout" command
    static func applyLayout(name: String) -> BridgeCommand {
        var cmd = BridgeCommand(v: kBridgeProtocolVersion, type: "applyLayout")
        cmd.name = name
        return cmd
    }

    enum CodingKeys: String, CodingKey {
        case v, type, direction, paneId, tabId, name, layout
    }
}

/// Pane direction for newPane command
enum PaneDirection: String, Codable, Sendable {
    case up, down, left, right
}

// MARK: - Bridge Channel Delegate

/// Protocol for receiving parsed bridge messages
protocol BridgeChannelDelegate: AnyObject, Sendable {
    @MainActor func bridgeDidReceive(_ envelope: BridgeEnvelope)
    @MainActor func bridgeChannelDidClose()
}
