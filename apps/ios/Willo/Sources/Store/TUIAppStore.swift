import Foundation
import Combine

// MARK: - Data Models

/// Category for TUI applications
enum TUICategory: String, Codable, CaseIterable, Identifiable {
    case devTools = "Dev Tools"
    case monitoring = "Monitoring"
    case files = "Files"
    case productivity = "Productivity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .devTools: return "hammer.fill"
        case .monitoring: return "chart.bar.fill"
        case .files: return "folder.fill"
        case .productivity: return "checkmark.circle.fill"
        }
    }
}

/// A TUI application that can be launched in the terminal
struct TUIApp: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let category: TUICategory
    let installCommand: String      // e.g., "brew install lazygit"
    let launchCommand: String       // e.g., "lazygit"
    let checkCommand: String?       // e.g., "which lazygit"
    let website: String?            // Project homepage
    let iconName: String?           // SF Symbol name or custom icon

    /// Default SF Symbol based on category if no icon specified
    var displayIcon: String {
        iconName ?? category.icon
    }
}

/// Installation state for a TUI app
enum TUIAppInstallState: Equatable {
    case unknown
    case checking
    case installed
    case notInstalled
    case installing
}

// MARK: - TUI App Store

/// Store for managing TUI applications catalog and installation state
@MainActor
class TUIAppStore: ObservableObject {
    static let shared = TUIAppStore()

    /// All available TUI apps in the catalog
    @Published private(set) var apps: [TUIApp] = []

    /// Installation state per app ID
    @Published private(set) var installStates: [String: TUIAppInstallState] = [:]

    /// Currently selected category filter (nil = all)
    @Published var selectedCategory: TUICategory?

    /// Search query
    @Published var searchQuery: String = ""

    /// Filtered apps based on category and search
    var filteredApps: [TUIApp] {
        apps.filter { app in
            // Category filter
            if let category = selectedCategory, app.category != category {
                return false
            }
            // Search filter
            if !searchQuery.isEmpty {
                let query = searchQuery.lowercased()
                return app.name.lowercased().contains(query) ||
                       app.description.lowercased().contains(query)
            }
            return true
        }
    }

    /// Apps grouped by category
    var appsByCategory: [TUICategory: [TUIApp]] {
        Dictionary(grouping: filteredApps) { $0.category }
    }

    private init() {
        loadCatalog()
    }

    /// Load the built-in catalog of TUI apps
    private func loadCatalog() {
        apps = Self.builtInCatalog
    }

    /// Get installation state for an app
    func installState(for app: TUIApp) -> TUIAppInstallState {
        installStates[app.id] ?? .unknown
    }

    /// Check if an app is installed on the remote server
    /// This would need to run the checkCommand over SSH
    func checkInstallation(for app: TUIApp, using transport: Any?) async {
        guard app.checkCommand != nil else {
            installStates[app.id] = .unknown
            return
        }

        installStates[app.id] = .checking

        // TODO: Execute checkCommand over SSH and parse result
        // For now, mark as unknown until connected
        try? await Task.sleep(nanoseconds: 500_000_000) // Simulate check
        installStates[app.id] = .unknown
    }

    /// Mark an app as installed (called after successful install)
    func markInstalled(_ app: TUIApp) {
        installStates[app.id] = .installed
    }

    /// Mark an app as not installed
    func markNotInstalled(_ app: TUIApp) {
        installStates[app.id] = .notInstalled
    }

    // MARK: - Built-in Catalog

    /// The curated catalog of TUI applications
    static let builtInCatalog: [TUIApp] = [
        // MARK: Dev Tools (Tier 1 - Primary Focus)
        TUIApp(
            id: "gh-dash",
            name: "gh-dash",
            description: "A beautiful dashboard for GitHub issues and PRs",
            category: .devTools,
            installCommand: "brew install gh && gh extension install dlvhdr/gh-dash",
            launchCommand: "gh dash",
            checkCommand: "gh extension list | grep -q gh-dash",
            website: "https://github.com/dlvhdr/gh-dash",
            iconName: "arrow.triangle.branch"
        ),
        TUIApp(
            id: "lazygit",
            name: "lazygit",
            description: "Simple terminal UI for git commands",
            category: .devTools,
            installCommand: "brew install lazygit",
            launchCommand: "lazygit",
            checkCommand: "which lazygit",
            website: "https://github.com/jesseduffield/lazygit",
            iconName: "arrow.triangle.branch"
        ),
        TUIApp(
            id: "tig",
            name: "tig",
            description: "Text-mode interface for git",
            category: .devTools,
            installCommand: "brew install tig",
            launchCommand: "tig",
            checkCommand: "which tig",
            website: "https://github.com/jonas/tig",
            iconName: "clock.arrow.circlepath"
        ),
        TUIApp(
            id: "gitui",
            name: "gitui",
            description: "Blazing fast terminal-ui for git",
            category: .devTools,
            installCommand: "brew install gitui",
            launchCommand: "gitui",
            checkCommand: "which gitui",
            website: "https://github.com/extrawurst/gitui",
            iconName: "arrow.triangle.branch"
        ),
        TUIApp(
            id: "lazydocker",
            name: "lazydocker",
            description: "Simple terminal UI for Docker",
            category: .devTools,
            installCommand: "brew install lazydocker",
            launchCommand: "lazydocker",
            checkCommand: "which lazydocker",
            website: "https://github.com/jesseduffield/lazydocker",
            iconName: "shippingbox"
        ),
        TUIApp(
            id: "k9s",
            name: "k9s",
            description: "Kubernetes CLI to manage clusters",
            category: .devTools,
            installCommand: "brew install k9s",
            launchCommand: "k9s",
            checkCommand: "which k9s",
            website: "https://github.com/derailed/k9s",
            iconName: "cloud"
        ),

        // MARK: Monitoring (Tier 2 - Secondary)
        TUIApp(
            id: "mactop",
            name: "mactop",
            description: "Apple Silicon monitor like htop",
            category: .monitoring,
            installCommand: "brew install mactop",
            launchCommand: "sudo mactop",
            checkCommand: "which mactop",
            website: "https://github.com/context-labs/mactop",
            iconName: "cpu"
        ),
        TUIApp(
            id: "btop",
            name: "btop",
            description: "Resource monitor with style",
            category: .monitoring,
            installCommand: "brew install btop",
            launchCommand: "btop",
            checkCommand: "which btop",
            website: "https://github.com/aristocratos/btop",
            iconName: "chart.bar.fill"
        ),
        TUIApp(
            id: "htop",
            name: "htop",
            description: "Interactive process viewer",
            category: .monitoring,
            installCommand: "brew install htop",
            launchCommand: "htop",
            checkCommand: "which htop",
            website: "https://htop.dev",
            iconName: "list.bullet.rectangle"
        ),
        TUIApp(
            id: "bandwhich",
            name: "bandwhich",
            description: "Terminal bandwidth utilization tool",
            category: .monitoring,
            installCommand: "brew install bandwhich",
            launchCommand: "sudo bandwhich",
            checkCommand: "which bandwhich",
            website: "https://github.com/imsnif/bandwhich",
            iconName: "network"
        ),
        TUIApp(
            id: "bottom",
            name: "bottom",
            description: "Cross-platform graphical process/system monitor",
            category: .monitoring,
            installCommand: "brew install bottom",
            launchCommand: "btm",
            checkCommand: "which btm",
            website: "https://github.com/ClementTsang/bottom",
            iconName: "waveform.path.ecg"
        ),

        // MARK: File Managers (Tier 3 - Lower Priority)
        TUIApp(
            id: "yazi",
            name: "yazi",
            description: "Blazing fast terminal file manager",
            category: .files,
            installCommand: "brew install yazi ffmpegthumbnailer unar poppler",
            launchCommand: "yazi",
            checkCommand: "which yazi",
            website: "https://github.com/sxyazi/yazi",
            iconName: "folder.fill"
        ),
        TUIApp(
            id: "ranger",
            name: "ranger",
            description: "Vim-inspired file manager with preview",
            category: .files,
            installCommand: "brew install ranger",
            launchCommand: "ranger",
            checkCommand: "which ranger",
            website: "https://github.com/ranger/ranger",
            iconName: "folder"
        ),
        TUIApp(
            id: "nnn",
            name: "nnn",
            description: "Tiny, lightning fast file manager",
            category: .files,
            installCommand: "brew install nnn",
            launchCommand: "nnn",
            checkCommand: "which nnn",
            website: "https://github.com/jarun/nnn",
            iconName: "doc.on.doc"
        ),
        TUIApp(
            id: "lf",
            name: "lf",
            description: "Terminal file manager inspired by ranger",
            category: .files,
            installCommand: "brew install lf",
            launchCommand: "lf",
            checkCommand: "which lf",
            website: "https://github.com/gokcehan/lf",
            iconName: "folder.badge.gear"
        ),

        // MARK: Productivity
        TUIApp(
            id: "taskwarrior-tui",
            name: "taskwarrior-tui",
            description: "TUI for Taskwarrior task management",
            category: .productivity,
            installCommand: "brew install taskwarrior-tui",
            launchCommand: "taskwarrior-tui",
            checkCommand: "which taskwarrior-tui",
            website: "https://github.com/kdheepak/taskwarrior-tui",
            iconName: "checklist"
        ),
        TUIApp(
            id: "sc-im",
            name: "sc-im",
            description: "Spreadsheet calculator in the terminal",
            category: .productivity,
            installCommand: "brew install sc-im",
            launchCommand: "sc-im",
            checkCommand: "which sc-im",
            website: "https://github.com/andmarti1424/sc-im",
            iconName: "tablecells"
        ),
    ]
}
