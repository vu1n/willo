import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingCommandPalette = false
    @State private var showingProfiles = false

    #if DEBUG
    /// Launch argument to auto-show terminal demo for testing
    private var autoShowTerminalDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-ShowTerminalDemo")
    }
    #endif

    var body: some View {
        #if DEBUG
        if autoShowTerminalDemo {
            TerminalDemoView()
        } else {
            mainContent
        }
        #else
        mainContent
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
            WorkspaceSidebar()
        } detail: {
            if let workspace = appState.activeWorkspace {
                TerminalWorkspaceView(workspace: workspace)
            } else {
                WelcomeView(showingProfiles: $showingProfiles)
            }
        }
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteView()
        }
        .sheet(isPresented: $showingProfiles) {
            ServerProfilesView()
        }
        .keyboardShortcut("k", modifiers: .command) // ⌘K for command palette
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            showingCommandPalette = true
        }
    }
}

extension Notification.Name {
    static let showCommandPalette = Notification.Name("showCommandPalette")
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
