import SwiftUI

struct WorkspaceSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewWorkspace = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SidebarHeader(onNewWorkspace: { showingNewWorkspace = true })

            // Workspaces list
            if appState.workspaces.isEmpty {
                EmptyWorkspacesView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.workspaces) { workspace in
                            WorkspaceCard(
                                workspace: workspace,
                                isSelected: appState.activeWorkspaceId == workspace.id
                            ) {
                                appState.activeWorkspaceId = workspace.id
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.machineDark)
        .overlay {
            ScanLinesView(opacity: 0.02)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceView()
        }
    }
}

// MARK: - Sidebar Header

private struct SidebarHeader: View {
    let onNewWorkspace: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Logo/Title
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.terminalCyan)
                    .glowEffect(color: .terminalCyan, radius: 6)

                Text("WILLO")
                    .font(.willoDisplay(18, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                    .tracking(2)
            }

            Spacer()

            // New workspace button
            IndustrialIconButton(icon: "plus", activeColor: .terminalCyan) {
                onNewWorkspace()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Rectangle()
                .fill(Color.machineGray)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.bezelLight.opacity(0.3), Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                }
        }
    }
}

// MARK: - Workspace Card

private struct WorkspaceCard: View {
    let workspace: Workspace
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Status LED
                StatusLED(status: ledStatus, size: 8, showPulse: true)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.serverProfile.displayName)
                        .font(.willoMono(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text(workspace.sessionName)
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                // Connection type badge
                if workspace.serverProfile.preferMosh {
                    Text("MOSH")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.terminalAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(Color.terminalAmber.opacity(0.15))
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Color.terminalAmber.opacity(0.3), lineWidth: 1)
                                }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.bezelGray : Color.machineGray.opacity(0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.terminalCyan.opacity(0.5) : Color.bezelLight.opacity(0.2),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    }
            }
            .shadow(color: isSelected ? Color.terminalCyan.opacity(0.2) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }

    private var ledStatus: StatusLED.LEDStatus {
        switch workspace.connectionState {
        case .disconnected: return .disconnected
        case .connecting, .reconnecting: return .connecting
        case .connected: return .connected
        case .failed: return .error
        }
    }
}

// MARK: - Empty State

private struct EmptyWorkspacesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.textTertiary)

                Text("No Active Sessions")
                    .font(.willoMono(.headline, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)

                Text("Connect to a server to start")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textTertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - New Workspace View

struct NewWorkspaceView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var selectedProfile: ServerProfile?
    @State private var sessionName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Content
                ScrollView {
                    VStack(spacing: 24) {
                        // Server selection
                        VStack(alignment: .leading, spacing: 12) {
                            IndustrialSectionHeader(title: "Server", icon: "server.rack")

                            if appState.serverProfiles.isEmpty {
                                IndustrialCard {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(Color.terminalAmber)
                                        Text("No servers configured")
                                            .font(.willoMono(.subheadline))
                                            .foregroundStyle(Color.textSecondary)
                                    }
                                }
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(appState.serverProfiles) { profile in
                                        ServerSelectionCard(
                                            profile: profile,
                                            isSelected: selectedProfile?.id == profile.id
                                        ) {
                                            selectedProfile = profile
                                            if sessionName.isEmpty {
                                                sessionName = generateSessionName(for: profile)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Session name
                        VStack(alignment: .leading, spacing: 12) {
                            IndustrialSectionHeader(title: "Session", icon: "terminal")

                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Session name", text: $sessionName)
                                    .font(.willoMono(.body))
                                    .foregroundStyle(Color.textPrimary)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .recessedPanel()

                                Text("Used by zellij to identify your workspace")
                                    .font(.willoCaption)
                                    .foregroundStyle(Color.textTertiary)
                            }
                        }
                    }
                    .padding(20)
                }

                // Footer with action
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.bezelLight.opacity(0.3))

                    HStack {
                        IndustrialButton(title: "Cancel", style: .ghost) {
                            dismiss()
                        }

                        Spacer()

                        IndustrialButton(
                            title: "Connect",
                            icon: "bolt.fill",
                            style: .primary
                        ) {
                            createWorkspace()
                        }
                        .disabled(selectedProfile == nil || sessionName.isEmpty)
                    }
                    .padding(16)
                }
                .background(Color.machineGray)
            }
            .background(Color.machineDark)
            .navigationTitle("New Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.machineGray, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func createWorkspace() {
        guard let profile = selectedProfile else { return }

        let workspace = Workspace(
            serverProfile: profile,
            sessionName: sessionName
        )

        appState.workspaces.append(workspace)
        appState.activeWorkspaceId = workspace.id
        dismiss()
    }

    private func generateSessionName(for profile: ServerProfile) -> String {
        let hostPart = profile.hostname.split(separator: ".").first ?? "server"
        return "willo/\(profile.username)/\(hostPart)"
    }
}

// MARK: - Server Selection Card

private struct ServerSelectionCard: View {
    let profile: ServerProfile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.terminalCyan : Color.bezelLight, lineWidth: 2)
                        .frame(width: 20, height: 20)

                    if isSelected {
                        Circle()
                            .fill(Color.terminalCyan)
                            .frame(width: 10, height: 10)
                    }
                }

                // Server info
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.willoMono(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text(profile.connectionString)
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                }

                Spacer()

                // Connection type
                HStack(spacing: 6) {
                    if profile.preferMosh {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.terminalAmber)
                    }
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.terminalGreen)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.terminalCyan.opacity(0.1) : Color.machineGray)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.terminalCyan.opacity(0.5) : Color.bezelLight.opacity(0.2),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationSplitView {
        WorkspaceSidebar()
    } detail: {
        Color.machineBlack
    }
    .environmentObject({
        let state = AppState()
        state.workspaces = [
            Workspace(
                serverProfile: ServerProfile(displayName: "Devbox", hostname: "devbox.local", username: "dev"),
                sessionName: "willo/dev/main"
            ),
            Workspace(
                serverProfile: ServerProfile(displayName: "Production", hostname: "prod.example.com", username: "deploy", preferMosh: true),
                sessionName: "willo/deploy/prod"
            ),
        ]
        state.activeWorkspaceId = state.workspaces.first?.id
        return state
    }())
    .preferredColorScheme(.dark)
}
