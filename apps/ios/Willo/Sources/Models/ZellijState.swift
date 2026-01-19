import Foundation

/// Represents the server-side Zellij session structure
/// Used by the Zellij Bridge to sync iPad UI with server state
struct ZellijSession: Identifiable, Codable, Sendable {
    let id: String  // Session name
    var tabs: [ZellijTab]
    var activeTabIndex: Int
    var paneManifest: [Int: [ZellijPane]]  // Tab index -> panes

    var activeTab: ZellijTab? {
        guard activeTabIndex >= 0 && activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    /// Get panes for a specific tab
    func panes(for tabIndex: Int) -> [ZellijPane] {
        paneManifest[tabIndex] ?? []
    }

    /// Get the focused pane in the active tab
    var focusedPane: ZellijPane? {
        guard let activeTab = activeTab else { return nil }
        return panes(for: activeTab.position).first { $0.isFocused }
    }

    init(id: String, tabs: [ZellijTab] = [], activeTabIndex: Int = 0, paneManifest: [Int: [ZellijPane]] = [:]) {
        self.id = id
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.paneManifest = paneManifest
    }
}

/// Tab information from Zellij TabUpdate event
struct ZellijTab: Identifiable, Codable, Sendable {
    let position: Int  // Tab index
    let name: String
    let active: Bool
    let mode: String?
    let activeSyncSwapLayoutName: String?
    let isFullscreenActive: Bool
    let isPendingPanesVisible: Bool
    let areFloatingPanesVisible: Bool
    let other: Int?

    var id: Int { position }

    enum CodingKeys: String, CodingKey {
        case position
        case name
        case active
        case mode
        case activeSyncSwapLayoutName = "active_swap_layout_name"
        case isFullscreenActive = "is_fullscreen_active"
        case isPendingPanesVisible = "is_pending_panes_visible"
        case areFloatingPanesVisible = "are_floating_panes_visible"
        case other
    }

    init(position: Int, name: String, active: Bool = false, mode: String? = nil, activeSyncSwapLayoutName: String? = nil, isFullscreenActive: Bool = false, isPendingPanesVisible: Bool = false, areFloatingPanesVisible: Bool = false, other: Int? = nil) {
        self.position = position
        self.name = name
        self.active = active
        self.mode = mode
        self.activeSyncSwapLayoutName = activeSyncSwapLayoutName
        self.isFullscreenActive = isFullscreenActive
        self.isPendingPanesVisible = isPendingPanesVisible
        self.areFloatingPanesVisible = areFloatingPanesVisible
        self.other = other
    }
}

/// Pane information from Zellij PaneUpdate event
struct ZellijPane: Identifiable, Codable, Sendable {
    let id: Int  // Pane ID
    let title: String
    let isFocused: Bool
    let isFullscreen: Bool
    let isFloating: Bool
    let isPlugin: Bool
    let exitStatus: Int?
    let runCommand: String?
    let x: Int?
    let y: Int?
    let rows: Int?
    let columns: Int?

    var isRunning: Bool {
        exitStatus == nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case isFocused = "is_focused"
        case isFullscreen = "is_fullscreen"
        case isFloating = "is_floating"
        case isPlugin = "is_plugin"
        case exitStatus = "exit_status"
        case runCommand = "run_command"
        case x, y, rows, columns
    }

    init(id: Int, title: String, isFocused: Bool = false, isFullscreen: Bool = false, isFloating: Bool = false, isPlugin: Bool = false, exitStatus: Int? = nil, runCommand: String? = nil, x: Int? = nil, y: Int? = nil, rows: Int? = nil, columns: Int? = nil) {
        self.id = id
        self.title = title
        self.isFocused = isFocused
        self.isFullscreen = isFullscreen
        self.isFloating = isFloating
        self.isPlugin = isPlugin
        self.exitStatus = exitStatus
        self.runCommand = runCommand
        self.x = x
        self.y = y
        self.rows = rows
        self.columns = columns
    }
}
