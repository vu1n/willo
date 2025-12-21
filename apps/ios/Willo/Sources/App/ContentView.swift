import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionStore: SessionStore
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
        if sessionStore.sessions.isEmpty {
            // No sessions - show welcome/workspace sidebar view
            NavigationSplitView {
                WorkspaceSidebar()
            } detail: {
                if let workspace = appState.activeWorkspace {
                    TerminalWorkspaceView(workspace: workspace)
                } else {
                    WelcomeView(showingProfiles: $showingProfiles)
                }
            }
            .sheet(isPresented: $showingProfiles) {
                ServerProfilesView()
            }
        } else {
            // Has sessions - show session container with tab bar
            SessionContainerView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(SessionStore())
}
