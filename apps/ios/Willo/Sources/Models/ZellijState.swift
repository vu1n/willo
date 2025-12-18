import Foundation

/// Represents the server-side Zellij session structure
/// Used by the Zellij Bridge to sync iPad UI with server state
struct ZellijSession: Identifiable, Codable {
    let id: String  // Session name
    var tabs: [ZellijTab]
    var activeTabIndex: Int

    var activeTab: ZellijTab? {
        guard activeTabIndex >= 0 && activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }
}

struct ZellijTab: Identifiable, Codable {
    let id: Int  // Tab index
    var name: String
    var panes: [ZellijPane]
    var activePaneId: Int?
    var isFullscreen: Bool
}

struct ZellijPane: Identifiable, Codable {
    let id: Int  // Pane ID
    var title: String
    var command: String?
    var isFloating: Bool
    var exitCode: Int?
    var isFocused: Bool

    var isRunning: Bool {
        exitCode == nil
    }
}

/// Bridge protocol messages (JSON Lines over SSH side-channel)
enum BridgeMessage: Codable {
    case sessionList(sessions: [String])
    case tabUpdate(tab: ZellijTab)
    case paneUpdate(pane: ZellijPane)
    case focusUpdate(tabId: Int, paneId: Int)

    // Commands from iPad → server
    case newTab(name: String?, layout: String?)
    case newPane(direction: PaneDirection?, command: String?)
    case focus(tabId: Int?, paneId: Int?)
    case renameTab(tabId: Int, name: String)
    case renamePane(paneId: Int, name: String)
    case applyLayout(layoutName: String)
}

enum PaneDirection: String, Codable {
    case up, down, left, right
}
