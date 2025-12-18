import SwiftUI

struct TerminalWorkspaceView: View {
    let workspace: Workspace
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @State private var session: TerminalSession?
    @State private var sessionState: SessionState = .disconnected
    @State private var showingSettings = false
    @State private var showingCommandPalette = false
    @State private var connectionError: Error?

    var body: some View {
        VStack(spacing: 0) {
            // Unified status bar
            TerminalStatusBar(
                workspace: workspace,
                sessionState: sessionState,
                onCommandPalette: { showingCommandPalette = true },
                onSettings: { showingSettings = true },
                onDisconnect: { Task { await disconnect() } },
                onReconnect: { Task { await connect() } }
            )

            // Terminal view
            TerminalContainerView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.machineBlack)
        .sheet(isPresented: $showingSettings) {
            TerminalSettingsSheet()
        }
        .sheet(isPresented: $showingCommandPalette) {
            if let session = session {
                CommandPaletteView { data in
                    Task {
                        try? await session.transport.send(data)
                    }
                }
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
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
            let terminalSize = calculateTerminalSize()

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

            let newSession: TerminalSession
            if workspace.serverProfile.preferMosh {
                newSession = try await sessionManager.createMoshSession(config: config)
            } else {
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

    private func calculateTerminalSize() -> (cols: UInt16, rows: UInt16) {
        let cellWidth: CGFloat = 15.0
        let cellHeight: CGFloat = 28.0
        var availableSize = CGSize(width: 800, height: 600)

        #if os(iOS)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let bounds = windowScene.coordinateSpace.bounds
            availableSize = CGSize(
                width: bounds.width - 20,
                height: bounds.height - 100
            )
        }
        #endif

        let cols = max(40, min(200, UInt16(availableSize.width / cellWidth)))
        let rows = max(10, min(60, UInt16(availableSize.height / cellHeight)))

        return (cols, rows)
    }
}

// MARK: - Terminal Status Bar

struct TerminalStatusBar: View {
    let workspace: Workspace
    let sessionState: SessionState
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onDisconnect: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator with host info
            HStack(spacing: 10) {
                StatusLED(status: ledStatus, size: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.serverProfile.displayName)
                        .font(.willoMono(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    HStack(spacing: 6) {
                        Text(sessionState.statusText)
                            .font(.willoCaption)
                            .foregroundStyle(sessionState.color)

                        if sessionState == .connected {
                            Text("•")
                                .foregroundStyle(Color.textTertiary)
                            Text(workspace.sessionName)
                                .font(.willoCaption)
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                // Command palette (only when connected)
                if sessionState == .connected {
                    IndustrialIconButton(icon: "command", isActive: false, activeColor: .terminalCyan) {
                        onCommandPalette()
                    }
                    .help("Zellij Commands (⌘K)")
                }

                // Settings
                IndustrialIconButton(icon: "gearshape", isActive: false) {
                    onSettings()
                }
                .help("Settings")

                // Disconnect/Reconnect
                if sessionState == .connected {
                    IndustrialIconButton(icon: "xmark.circle", activeColor: .terminalRed) {
                        onDisconnect()
                    }
                    .help("Disconnect")
                } else if sessionState == .disconnected || sessionState == .error(NSError()) {
                    IndustrialIconButton(icon: "bolt.fill", isActive: true, activeColor: .terminalGreen) {
                        onReconnect()
                    }
                    .help("Connect")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Rectangle()
                .fill(Color.machineGray)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.bezelLight.opacity(0.2))
                        .frame(height: 1)
                }
        }
    }

    private var ledStatus: StatusLED.LEDStatus {
        switch sessionState {
        case .disconnected: return .disconnected
        case .connecting, .reconnecting: return .connecting
        case .connected: return .connected
        case .error: return .error
        }
    }
}

// MARK: - Session State Extensions

extension SessionState {
    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .error: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: return .textTertiary
        case .connecting: return .terminalAmber
        case .connected: return .terminalGreen
        case .reconnecting: return .terminalAmber
        case .error: return .terminalRed
        }
    }
}

// MARK: - Terminal Container

struct TerminalContainerView: View {
    let session: TerminalSession?
    @EnvironmentObject var appearanceSettings: AppearanceSettings

    var body: some View {
        ZStack {
            Color.machineBlack
                .ignoresSafeArea()

            if let session = session {
                SessionTerminalView(session: session)

                if case .reconnecting = session.state {
                    ReconnectingOverlay(attempt: 1)
                }
            } else {
                ConnectingView()
            }
        }
    }
}

// MARK: - Connecting View

private struct ConnectingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 20) {
            // Animated terminal icon
            ZStack {
                Circle()
                    .stroke(Color.terminalCyan.opacity(0.2), lineWidth: 2)
                    .frame(width: 64, height: 64)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.terminalCyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(rotation))

                Image(systemName: "terminal")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.terminalCyan)
            }

            Text("ESTABLISHING CONNECTION")
                .font(.willoSectionHeader)
                .tracking(2)
                .foregroundStyle(Color.textSecondary)
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Reconnecting Overlay

struct ReconnectingOverlay: View {
    let attempt: Int
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            // Pulsing indicator
            ZStack {
                Circle()
                    .fill(Color.terminalAmber.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .scaleEffect(pulse ? 1.2 : 1)
                    .opacity(pulse ? 0 : 0.5)

                Circle()
                    .fill(Color.terminalAmber.opacity(0.2))
                    .frame(width: 60, height: 60)

                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.terminalAmber)
            }

            VStack(spacing: 8) {
                Text("RECONNECTING")
                    .font(.willoSectionHeader)
                    .tracking(2)
                    .foregroundStyle(Color.terminalAmber)

                Text("Attempt \(attempt)")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textTertiary)

                Text("Session preserved on server")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.machineGray.opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.terminalAmber.opacity(0.3), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.5), radius: 20)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
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
    .environmentObject(AppearanceSettings())
    .preferredColorScheme(.dark)
}
