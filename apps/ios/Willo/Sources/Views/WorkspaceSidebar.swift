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
    @EnvironmentObject var sessionStore: SessionStore
    @State private var selectedProfile: ServerProfile?
    @State private var sessionName = ""
    @State private var selectedColor: SessionColor = .cyan

    /// Key for storing last selected profile
    private static let lastProfileKey = "lastSelectedProfileId"

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
                                            selectProfile(profile)
                                        }
                                    }
                                }
                            }
                        }

                        // Session name
                        VStack(alignment: .leading, spacing: 12) {
                            IndustrialSectionHeader(title: "Session", icon: "terminal")

                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Session name (optional)", text: $sessionName)
                                    .font(.willoMono(.body))
                                    .foregroundStyle(Color.textPrimary)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .recessedPanel()

                                Text("Name for both Willo tab and zellij session")
                                    .font(.willoCaption)
                                    .foregroundStyle(Color.textTertiary)
                            }

                            // Session color
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Color")
                                    .font(.willoCaption)
                                    .foregroundStyle(Color.textSecondary)

                                HStack(spacing: 12) {
                                    ForEach(SessionColor.allCases, id: \.self) { color in
                                        Circle()
                                            .fill(color.color)
                                            .frame(width: 28, height: 28)
                                            .overlay {
                                                if selectedColor == color {
                                                    Circle()
                                                        .stroke(Color.white, lineWidth: 2)
                                                }
                                            }
                                            .shadow(color: selectedColor == color ? color.color.opacity(0.5) : .clear, radius: 4)
                                            .onTapGesture {
                                                selectedColor = color
                                            }
                                    }
                                }
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
                        .disabled(selectedProfile == nil)
                    }
                    .padding(16)
                }
                .background(Color.machineGray)
            }
            .background(Color.machineDark)
            .navigationTitle("New Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.machineGray, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .onAppear {
                autoSelectProfile()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func autoSelectProfile() {
        // Try to select last used profile
        if let lastIdString = UserDefaults.standard.string(forKey: Self.lastProfileKey),
           let lastId = UUID(uuidString: lastIdString),
           let profile = appState.serverProfiles.first(where: { $0.id == lastId }) {
            selectedProfile = profile
        }
        // Otherwise select first profile if only one exists
        else if appState.serverProfiles.count == 1 {
            selectedProfile = appState.serverProfiles.first
        }
    }

    private func selectProfile(_ profile: ServerProfile) {
        selectedProfile = profile
        // Save as last selected
        UserDefaults.standard.set(profile.id.uuidString, forKey: Self.lastProfileKey)
    }

    private func createWorkspace() {
        guard let profile = selectedProfile else { return }

        // Use provided name or generate zellij-style random name
        let finalName = sessionName.isEmpty ? generateZellijStyleName() : sessionName

        // Save last selected profile
        UserDefaults.standard.set(profile.id.uuidString, forKey: Self.lastProfileKey)

        // Create WilloSession (new session-based architecture)
        let session = sessionStore.createSession(
            profile: profile,
            name: finalName,
            color: selectedColor
        )

        // Also create legacy Workspace for backward compatibility
        let workspace = Workspace(
            id: session.id,  // Use same ID for linking
            serverProfile: profile,
            sessionName: finalName
        )

        appState.workspaces.append(workspace)
        appState.activeWorkspaceId = workspace.id
        dismiss()
    }

    /// Generate a zellij-style session name (adjective-noun)
    /// Ensures no collision with existing sessions
    private func generateZellijStyleName() -> String {
        let adjectives = [
            "able", "aged", "ancient", "bold", "brave", "bright", "calm", "clean", "clever", "cool",
            "damp", "dark", "dawn", "deep", "dry", "early", "easy", "empty", "fair", "fast",
            "flat", "free", "fresh", "full", "gentle", "good", "great", "green", "happy", "heavy",
            "hidden", "holy", "humble", "icy", "kind", "late", "light", "little", "lively", "lone",
            "long", "lucky", "mild", "misty", "mute", "named", "narrow", "neat", "new", "nice",
            "noble", "odd", "old", "orange", "pale", "patient", "plain", "polite", "proud", "purple",
            "quick", "quiet", "rapid", "rare", "red", "restless", "rich", "rough", "round", "royal",
            "rustic", "shy", "silent", "simple", "small", "smooth", "snowy", "soft", "solitary", "sparkling",
            "spring", "still", "summer", "super", "sweet", "tender", "thirsty", "tiny", "tough", "twilight",
            "wandering", "warm", "weathered", "white", "wild", "winter", "wispy", "young", "zealous"
        ]

        let nouns = [
            "apple", "apricot", "badger", "bear", "bee", "bird", "breeze", "brook", "bush", "butterfly",
            "cherry", "cloud", "coral", "crane", "dawn", "deer", "dew", "dream", "duck", "dust",
            "eagle", "elm", "fern", "field", "finch", "fire", "flower", "fog", "forest", "fox",
            "frog", "frost", "glade", "grass", "grove", "hare", "hawk", "hazel", "hill", "hound",
            "lake", "leaf", "light", "lily", "lion", "maple", "meadow", "mist", "moon", "moss",
            "moth", "mouse", "night", "oak", "ocean", "orchid", "otter", "owl", "palm", "path",
            "peak", "pebble", "pine", "pond", "rabbit", "rain", "raven", "reef", "river", "robin",
            "rock", "rose", "sage", "sea", "shadow", "shore", "sky", "smoke", "snow", "sparrow",
            "star", "stone", "storm", "stream", "sun", "swallow", "thunder", "tiger", "tree", "violet",
            "water", "wave", "weasel", "willow", "wind", "wolf", "wood", "wren"
        ]

        let existingNames = Set(sessionStore.sessions.map { $0.name })

        // Try to find a unique name (up to 100 attempts)
        for _ in 0..<100 {
            let adjective = adjectives.randomElement() ?? "wild"
            let noun = nouns.randomElement() ?? "star"
            let name = "\(adjective)-\(noun)"

            if !existingNames.contains(name) {
                return name
            }
        }

        // Fallback: append random number
        let adjective = adjectives.randomElement() ?? "wild"
        let noun = nouns.randomElement() ?? "star"
        return "\(adjective)-\(noun)-\(Int.random(in: 100...999))"
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
    .environmentObject(SessionStore())
    .preferredColorScheme(.dark)
}
