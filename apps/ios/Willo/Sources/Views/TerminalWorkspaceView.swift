import SwiftUI

struct TerminalWorkspaceView: View {
    let workspace: Workspace
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @State private var session: TerminalSession?
    @State private var sessionState: SessionState = .disconnected
    @State private var showingZellijSidebar = false
    @State private var connectionError: Error?

    var body: some View {
        HStack(spacing: 0) {
            // Main terminal view
            TerminalContainerView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Zellij sidebar (collapsible)
            if showingZellijSidebar, session != nil {
                Divider()
                ZellijSidebarView(session: ZellijSession(
                    id: workspace.sessionName,
                    tabs: [], // TODO: Populate from real zellij state
                    activeTabIndex: 0
                ))
                .frame(width: 280)
                .transition(.move(edge: .trailing))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Disconnect button (only when connected)
                if session != nil, sessionState == .connected {
                    Button {
                        Task { await disconnect() }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Disconnect")
                }

                ConnectionStatusButton(state: sessionState) {
                    Task { await connect() }
                }

                Button {
                    withAnimation {
                        showingZellijSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Toggle Zellij sidebar")
            }
        }
        .navigationTitle(workspace.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await connect()
        }
        .alert("Connection Error", isPresented: .init(
            get: { connectionError != nil },
            set: { if !$0 { connectionError = nil } }
        )) {
            Button("Retry") {
                Task { await connect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let error = connectionError {
                Text(error.localizedDescription)
            }
        }
    }

    private func connect() async {
        sessionState = .connecting
        do {
            // Calculate terminal size from available screen space
            let terminalSize = calculateTerminalSize()

            // Create session config from workspace
            var config = SessionConfig(
                name: workspace.sessionName,
                host: workspace.serverProfile.hostname,
                port: UInt16(workspace.serverProfile.port),
                username: workspace.serverProfile.username,
                connectionType: workspace.serverProfile.preferMosh ? .mosh : .ssh,
                authMethod: workspace.serverProfile.authMethodConfig
            )
            config.terminalCols = terminalSize.cols
            config.terminalRows = terminalSize.rows
            print("[Terminal] Connecting with size: \(terminalSize.cols)x\(terminalSize.rows)")

            // Create session - use Mosh flow if preferred
            let newSession: TerminalSession
            if workspace.serverProfile.preferMosh {
                // Mosh: SSH bootstrap -> get mosh key/port -> UDP connection
                newSession = try await sessionManager.createMoshSession(config: config)
            } else {
                // Plain SSH
                newSession = try await sessionManager.createSession(config: config)
            }

            self.session = newSession
            try await sessionManager.connect(newSession)
            sessionState = .connected
        } catch {
            sessionState = .error(error)
            self.connectionError = error
        }
    }

    private func disconnect() async {
        guard let session = session else { return }
        try? await sessionManager.disconnect(session)
        self.session = nil
        sessionState = .disconnected
    }

    /// Calculate terminal dimensions based on available screen space
    private func calculateTerminalSize() -> (cols: UInt16, rows: UInt16) {
        // Cell dimensions from GlyphAtlas (24pt font)
        let cellWidth: CGFloat = 15.0
        let cellHeight: CGFloat = 28.0

        // Get the current window scene bounds
        var availableSize = CGSize(width: 800, height: 600)  // Fallback

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let bounds = windowScene.coordinateSpace.bounds
            // Account for navigation bar (~50pt) and some padding
            availableSize = CGSize(
                width: bounds.width - 20,  // Small horizontal padding
                height: bounds.height - 100  // Nav bar + status bar + padding
            )
        }

        let cols = max(40, min(200, UInt16(availableSize.width / cellWidth)))
        let rows = max(10, min(60, UInt16(availableSize.height / cellHeight)))

        return (cols, rows)
    }
}

struct ConnectionStatusButton: View {
    let state: SessionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SessionStatusDot(state: state)
                Text(state.statusText)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SessionStatusDot: View {
    let state: SessionState

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
    }
}

extension SessionState {
    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        case .error: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .reconnecting: return .orange
        case .error: return .red
        }
    }
}

struct TerminalContainerView: View {
    let session: TerminalSession?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let session = session {
                // Terminal view using WilloTerminalView (Metal renderer)
                SessionTerminalView(session: session)

                // Reconnecting overlay
                if case .reconnecting = session.state {
                    ReconnectingOverlay(attempt: 1)
                }
            } else {
                // Loading state
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

struct ReconnectingOverlay: View {
    let attempt: Int

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

            Text("Reconnecting...")
                .font(.headline)
                .foregroundColor(.white)

            Text("Attempt \(attempt)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))

            Text("Your session is safe on the server")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(32)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Server Profile Extension

extension ServerProfile {
    var authMethodConfig: AuthMethodConfig {
        switch authMethod {
        case .password(let pwd):
            return .password(pwd)
        case .key:
            return .publicKey(keyPath: "~/.ssh/id_rsa", passphrase: nil)
        case .agent:
            return .agent
        }
    }
}

#Preview {
    NavigationStack {
        TerminalWorkspaceView(
            workspace: Workspace(
                serverProfile: ServerProfile(
                    displayName: "Devbox",
                    hostname: "devbox.local",
                    username: "dev"
                ),
                sessionName: "willo/dev/main/devbox"
            )
        )
        .environmentObject(AppState())
        .environmentObject(SessionManager(appManager: GhosttyAppManager()))
    }
}
