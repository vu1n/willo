import SwiftUI

struct WelcomeView: View {
    @Binding var showingProfiles: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @State private var showingTerminalDemo = false
    @State private var showingMetalDemo = false
    @State private var showingSSHTest = false

    var body: some View {
        VStack(spacing: 32) {
            // Appearance toggle in top-right
            HStack {
                Spacer()
                AppearanceToggle(settings: appearanceSettings)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            // Logo/Title
            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("Willo")
                    .font(.largeTitle.bold())

                Text("Fast, resilient iPad terminal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Quick actions
            VStack(spacing: 16) {
                if appState.serverProfiles.isEmpty {
                    // First run - create profile
                    Button {
                        showingProfiles = true
                    } label: {
                        Label("Add Your First Server", systemImage: "plus.circle.fill")
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    // Recent connections
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Servers")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(appState.serverProfiles.prefix(3)) { profile in
                            RecentServerButton(profile: profile) {
                                connectTo(profile: profile)
                            }
                        }

                        Button {
                            showingProfiles = true
                        } label: {
                            Label("Manage Servers", systemImage: "server.rack")
                                .frame(maxWidth: 280)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: 320)

            Spacer()

            // Keyboard shortcuts hint
            VStack(spacing: 4) {
                Text("Keyboard Shortcuts")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    ShortcutHint(keys: "⌘T", action: "New Tab")
                    ShortcutHint(keys: "⌘K", action: "Command Palette")
                    ShortcutHint(keys: "⌘R", action: "Reconnect")
                }
            }
            .padding(.bottom, 16)

            // Developer testing option
            #if DEBUG
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        showingTerminalDemo = true
                    } label: {
                        Label("Ghostty Test", systemImage: "terminal")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.secondary)

                    Button {
                        showingMetalDemo = true
                    } label: {
                        Label("Metal Renderer", systemImage: "cpu")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }

                Button {
                    showingSSHTest = true
                } label: {
                    Label("SSH Test", systemImage: "network")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
            }
            .padding(.bottom, 16)
            #endif
        }
        .sheet(isPresented: $showingTerminalDemo) {
            NavigationStack {
                TerminalDemoView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingTerminalDemo = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingMetalDemo) {
            NavigationStack {
                MetalTerminalDemoView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingMetalDemo = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingSSHTest) {
            NavigationStack {
                SSHTestView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingSSHTest = false
                            }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(.systemBackground))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
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
        // Simple session name for now
        // TODO: Use template from profile
        "willo/dev/main/\(profile.hostname.split(separator: ".").first ?? "server")"
    }
}

struct RecentServerButton: View {
    let profile: ServerProfile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.headline)

                    Text(profile.connectionString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct ShortcutHint: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    WelcomeView(showingProfiles: .constant(false))
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
}
