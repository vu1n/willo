import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionStore: SessionStore
    @State private var showingProfiles = false
    @State private var hasMigratedWorkspaces = false

    #if DEBUG
    /// Launch argument to auto-show terminal demo for testing
    private var autoShowTerminalDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-ShowTerminalDemo")
    }
    #endif

    var body: some View {
        Group {
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
        .onAppear {
            migrateWorkspacesToSessions()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if sessionStore.sessions.isEmpty && appState.workspaces.isEmpty {
            // No sessions or workspaces - show welcome view
            NavigationSplitView {
                WorkspaceSidebar()
            } detail: {
                WelcomeView(showingProfiles: $showingProfiles)
            }
            .sheet(isPresented: $showingProfiles) {
                ServerProfilesView()
            }
        } else {
            // Has sessions - show session container with tab bar
            SessionContainerView()
        }
    }

    /// Migrate existing workspaces to WilloSessions for tab support
    private func migrateWorkspacesToSessions() {
        guard !hasMigratedWorkspaces else { return }
        hasMigratedWorkspaces = true

        // Check each workspace and create a session if it doesn't exist
        for workspace in appState.workspaces {
            let hasSession = sessionStore.sessions.contains { $0.id == workspace.id }
            if !hasSession {
                print("[Migration] Creating session for workspace: \(workspace.sessionName)")
                let session = WilloSession(
                    id: workspace.id,  // Use same ID for linking
                    serverProfile: workspace.serverProfile,
                    name: workspace.sessionName,
                    description: workspace.serverProfile.connectionString,
                    color: SessionColor.allCases.randomElement() ?? .cyan
                )
                sessionStore.addSession(session)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(SessionStore())
}
