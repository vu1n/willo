import SwiftUI

struct WelcomeView: View {
    @Binding var showingProfiles: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @State private var showingTerminalDemo = false
    @State private var showingMetalDemo = false
    @State private var showingSSHTest = false
    @State private var animateIn = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background with grid
                Color.machineDark
                    .ignoresSafeArea()

                GridPatternView()
                    .ignoresSafeArea()
                    .opacity(0.5)

                // Scan lines overlay
                ScanLinesView(opacity: 0.015)
                    .ignoresSafeArea()

                // Main content
                VStack(spacing: 0) {
                    // Top bar with appearance toggle
                    HStack {
                        Spacer()
                        AppearanceToggleCompact(settings: appearanceSettings)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                    Spacer()

                    // Hero section
                    VStack(spacing: 32) {
                        // Logo
                        WilloLogo()
                            .opacity(animateIn ? 1 : 0)
                            .offset(y: animateIn ? 0 : 20)

                        // Tagline
                        Text("FAST. RESILIENT. MOBILE.")
                            .font(.willoSectionHeader)
                            .tracking(4)
                            .foregroundStyle(Color.textSecondary)
                            .opacity(animateIn ? 1 : 0)
                            .offset(y: animateIn ? 0 : 10)
                            .animation(.easeOut(duration: 0.6).delay(0.2), value: animateIn)
                    }

                    Spacer()

                    // Server launch panel
                    VStack(spacing: 20) {
                        if appState.serverProfiles.isEmpty {
                            // First run - add server CTA
                            FirstRunPanel(onAddServer: { showingProfiles = true })
                                .opacity(animateIn ? 1 : 0)
                                .animation(.easeOut(duration: 0.5).delay(0.3), value: animateIn)
                        } else {
                            // Recent servers
                            LaunchPanel(
                                servers: Array(appState.serverProfiles.prefix(3)),
                                onSelect: connectTo,
                                onManage: { showingProfiles = true }
                            )
                            .opacity(animateIn ? 1 : 0)
                            .animation(.easeOut(duration: 0.5).delay(0.3), value: animateIn)
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    // Keyboard shortcuts
                    KeyboardShortcutsBar()
                        .opacity(animateIn ? 1 : 0)
                        .animation(.easeOut(duration: 0.5).delay(0.5), value: animateIn)

                    // Debug panel
                    #if DEBUG
                    DebugPanel(
                        onGhosttyTest: { showingTerminalDemo = true },
                        onMetalTest: { showingMetalDemo = true },
                        onSSHTest: { showingSSHTest = true }
                    )
                    .opacity(animateIn ? 0.7 : 0)
                    .animation(.easeOut(duration: 0.5).delay(0.6), value: animateIn)
                    #endif
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                animateIn = true
            }
        }
        .sheet(isPresented: $showingTerminalDemo) {
            NavigationStack {
                TerminalDemoView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingTerminalDemo = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingMetalDemo) {
            NavigationStack {
                MetalTerminalDemoView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingMetalDemo = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingSSHTest) {
            NavigationStack {
                SSHTestView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingSSHTest = false }
                        }
                    }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func connectTo(profile: ServerProfile) {
        let workspace = Workspace(
            serverProfile: profile,
            sessionName: generateSessionName(for: profile)
        )
        appState.workspaces.append(workspace)
        appState.activeWorkspaceId = workspace.id
    }

    private func generateSessionName(for profile: ServerProfile) -> String {
        let hostPart = profile.hostname.split(separator: ".").first ?? "server"
        return "willo/\(profile.username)/\(hostPart)"
    }
}

// MARK: - Willo Logo

private struct WilloLogo: View {
    @State private var glowPulse = false

    var body: some View {
        VStack(spacing: 16) {
            // Terminal icon with glow
            ZStack {
                // Glow layers
                Image(systemName: "terminal.fill")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(Color.terminalCyan)
                    .blur(radius: 20)
                    .opacity(glowPulse ? 0.6 : 0.3)

                Image(systemName: "terminal.fill")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(Color.terminalCyan)
                    .blur(radius: 8)
                    .opacity(0.5)

                // Main icon
                Image(systemName: "terminal.fill")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.terminalCyan, .terminalCyan.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // Title
            Text("WILLO")
                .font(.willoDisplay(42, weight: .bold))
                .tracking(8)
                .foregroundStyle(Color.textPrimary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}

// MARK: - First Run Panel

private struct FirstRunPanel: View {
    let onAddServer: () -> Void

    var body: some View {
        IndustrialCard {
            VStack(spacing: 20) {
                Image(systemName: "server.rack")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.terminalCyan)

                VStack(spacing: 8) {
                    Text("Welcome to Willo")
                        .font(.willoMono(.title3, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text("Add a server to begin your first session")
                        .font(.willoCaption)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                }

                IndustrialButton(
                    title: "Add Server",
                    icon: "plus.circle.fill",
                    style: .primary,
                    size: .large
                ) {
                    onAddServer()
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 400)
    }
}

// MARK: - Launch Panel

private struct LaunchPanel: View {
    let servers: [ServerProfile]
    let onSelect: (ServerProfile) -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Section header
            HStack {
                IndustrialSectionHeader(title: "Quick Launch", icon: "bolt.fill")
                Spacer()
            }

            // Server cards
            VStack(spacing: 10) {
                ForEach(servers) { profile in
                    ServerLaunchCard(profile: profile) {
                        onSelect(profile)
                    }
                }
            }

            // Manage button
            IndustrialButton(
                title: "Manage Servers",
                icon: "server.rack",
                style: .secondary
            ) {
                onManage()
            }
        }
        .frame(maxWidth: 500)
    }
}

// MARK: - Server Launch Card

private struct ServerLaunchCard: View {
    let profile: ServerProfile
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Server icon with status
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.machineBlack)
                        .frame(width: 48, height: 48)

                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.terminalCyan)
                }

                // Server info
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.willoMono(.headline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    HStack(spacing: 8) {
                        Text(profile.connectionString)
                            .font(.willoCaption)
                            .foregroundStyle(Color.textTertiary)

                        if profile.preferMosh {
                            MoshBadge()
                        }
                    }
                }

                Spacer()

                // Launch arrow
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.terminalCyan)
                    .opacity(isHovered ? 1 : 0.6)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.machineGray)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isHovered ? Color.terminalCyan.opacity(0.5) : Color.bezelLight.opacity(0.3),
                                lineWidth: 1
                            )
                    }
            }
            .shadow(color: isHovered ? Color.terminalCyan.opacity(0.2) : .clear, radius: 12)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Mosh Badge

private struct MoshBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
            Text("MOSH")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(Color.terminalAmber)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
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

// MARK: - Keyboard Shortcuts Bar

private struct KeyboardShortcutsBar: View {
    var body: some View {
        HStack(spacing: 24) {
            ShortcutPill(keys: "⌘T", action: "New Tab")
            ShortcutPill(keys: "⌘K", action: "Commands")
            ShortcutPill(keys: "⌘R", action: "Reconnect")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background {
            Rectangle()
                .fill(Color.machineGray.opacity(0.5))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.bezelLight.opacity(0.2))
                        .frame(height: 1)
                }
        }
    }
}

private struct ShortcutPill: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.willoMono(.caption, weight: .semibold))
                .foregroundStyle(Color.terminalCyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.machineBlack)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.bezelLight.opacity(0.3), lineWidth: 1)
                        }
                }

            Text(action)
                .font(.willoCaption)
                .foregroundStyle(Color.textTertiary)
        }
    }
}

// MARK: - Debug Panel

#if DEBUG
private struct DebugPanel: View {
    let onGhosttyTest: () -> Void
    let onMetalTest: () -> Void
    let onSSHTest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("DEV")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.terminalAmber)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule()
                        .strokeBorder(Color.terminalAmber.opacity(0.5), lineWidth: 1)
                }

            IndustrialButton(title: "Ghostty", icon: "terminal", style: .ghost, size: .small) {
                onGhosttyTest()
            }

            IndustrialButton(title: "Metal", icon: "cpu", style: .ghost, size: .small) {
                onMetalTest()
            }

            IndustrialButton(title: "SSH", icon: "network", style: .ghost, size: .small) {
                onSSHTest()
            }
        }
        .padding(12)
    }
}
#endif

#Preview {
    WelcomeView(showingProfiles: .constant(false))
        .environmentObject({
            let state = AppState()
            state.serverProfiles = [
                ServerProfile(displayName: "Devbox", hostname: "devbox.local", username: "dev"),
                ServerProfile(displayName: "Production", hostname: "prod.example.com", username: "deploy", preferMosh: true),
            ]
            return state
        }())
        .environmentObject(AppearanceSettings())
}
