import SwiftUI

struct WorkspaceSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewWorkspace = false

    var body: some View {
        List(selection: $appState.activeWorkspaceId) {
            Section("Workspaces") {
                ForEach(appState.workspaces) { workspace in
                    WorkspaceRow(workspace: workspace)
                        .tag(workspace.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Willo")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewWorkspace = true
                } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceView()
        }
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            ConnectionStatusDot(state: workspace.connectionState)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.serverProfile.displayName)
                    .font(.headline)

                Text(workspace.sessionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct ConnectionStatusDot: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if isAnimating {
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(animationScale)
                        .opacity(animationOpacity)
                }
            }
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isAnimating)
    }

    private var color: Color {
        switch state {
        case .disconnected: return .gray
        case .connecting, .reconnecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var isAnimating: Bool {
        switch state {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    private var animationScale: CGFloat {
        isAnimating ? 2 : 1
    }

    private var animationOpacity: Double {
        isAnimating ? 0 : 1
    }
}

struct NewWorkspaceView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var selectedProfile: ServerProfile?
    @State private var sessionName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Picker("Profile", selection: $selectedProfile) {
                        Text("Select a server").tag(nil as ServerProfile?)
                        ForEach(appState.serverProfiles) { profile in
                            Text(profile.displayName).tag(profile as ServerProfile?)
                        }
                    }
                }

                Section("Session") {
                    TextField("Session name", text: $sessionName)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("New Workspace")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        createWorkspace()
                    }
                    .disabled(selectedProfile == nil || sessionName.isEmpty)
                }
            }
        }
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
}

#Preview {
    NavigationSplitView {
        WorkspaceSidebar()
    } detail: {
        Text("Terminal")
    }
    .environmentObject(AppState())
}
