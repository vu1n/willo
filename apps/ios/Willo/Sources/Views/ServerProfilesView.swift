import SwiftUI

struct ServerProfilesView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var editingProfile: ServerProfile?
    @State private var showingNewProfile = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if appState.serverProfiles.isEmpty {
                    // Empty state
                    EmptyServersView {
                        showingNewProfile = true
                    }
                } else {
                    // Server list
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(appState.serverProfiles) { profile in
                                ServerProfileCard(profile: profile) {
                                    editingProfile = profile
                                } onDelete: {
                                    deleteProfile(profile)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(Color.machineDark)
            .navigationTitle("Servers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.machineGray, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.willoMono(.callout, weight: .semibold))
                            .foregroundStyle(Color.terminalCyan)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    IndustrialIconButton(icon: "plus", activeColor: .terminalCyan) {
                        showingNewProfile = true
                    }
                }
            }
            .sheet(item: $editingProfile) { profile in
                ProfileEditorView(profile: profile, isNew: false)
            }
            .sheet(isPresented: $showingNewProfile) {
                ProfileEditorView(
                    profile: ServerProfile(
                        displayName: "",
                        hostname: "",
                        username: ""
                    ),
                    isNew: true
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private func deleteProfile(_ profile: ServerProfile) {
        withAnimation {
            appState.serverProfiles.removeAll { $0.id == profile.id }
        }
    }
}

// MARK: - Empty State

private struct EmptyServersView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.textTertiary)

                Text("No Servers")
                    .font(.willoMono(.title2, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)

                Text("Add a server to connect via SSH or Mosh")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textTertiary)
                    .multilineTextAlignment(.center)
            }

            IndustrialButton(
                title: "Add Server",
                icon: "plus.circle.fill",
                style: .primary,
                size: .large
            ) {
                onAdd()
            }

            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Server Profile Card

private struct ServerProfileCard: View {
    let profile: ServerProfile
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirm = false

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 14) {
                // Server icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.machineBlack)
                        .frame(width: 48, height: 48)

                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.terminalCyan)
                }

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.willoMono(.headline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text(profile.connectionString)
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)

                    // Tags
                    HStack(spacing: 8) {
                        if profile.preferMosh {
                            MiniTag(text: "MOSH", color: .terminalAmber)
                        }

                        MiniTag(text: profile.multiplexer.displayName.uppercased(), color: .terminalBlue)

                        if let lastConnected = profile.lastConnected {
                            Text("•")
                                .foregroundStyle(Color.textTertiary)
                            Text(lastConnected, style: .relative)
                                .font(.willoCaption)
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 8) {
                    Button {
                        showingDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.terminalRed.opacity(0.7))
                            .frame(width: 32, height: 32)
                            .background {
                                Circle()
                                    .fill(Color.terminalRed.opacity(0.1))
                            }
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.machineGray)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.bezelLight.opacity(0.2), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .confirmationDialog("Delete Server", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(profile.displayName)\"?")
        }
    }
}

// MARK: - Mini Tag

private struct MiniTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(color.opacity(0.15))
            }
    }
}

// MARK: - Profile Editor View

struct ProfileEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState

    @State var profile: ServerProfile
    @State private var password: String = ""
    let isNew: Bool

    private var authMethodType: Int {
        switch profile.authMethod {
        case .key: return 0
        case .password: return 1
        case .agent: return 2
        }
    }

    init(profile: ServerProfile, isNew: Bool) {
        self._profile = State(initialValue: profile)
        self.isNew = isNew
        if case .password(let pwd) = profile.authMethod {
            self._password = State(initialValue: pwd)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    connectionSection
                    authenticationSection
                    connectionTypeSection
                    sessionSection
                }
                .padding(20)
            }
            .background(Color.machineDark)
            .navigationTitle(isNew ? "New Server" : "Edit Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.machineGray, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveProfile()
                    } label: {
                        Text("Save")
                            .font(.willoMono(.callout, weight: .semibold))
                            .foregroundStyle(canSave ? Color.terminalCyan : Color.textTertiary)
                    }
                    .disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Section Views

    private var connectionSection: some View {
        EditorSection(title: "Connection", icon: "network") {
            VStack(spacing: 12) {
                EditorField(label: "Display Name", text: $profile.displayName, placeholder: "My Server")

                EditorField(label: "Hostname", text: $profile.hostname, placeholder: "server.example.com")
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif

                HStack(spacing: 12) {
                    EditorField(label: "Username", text: $profile.username, placeholder: "user")
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    portField
                }
            }
        }
    }

    private var portField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PORT")
                .font(.willoSectionHeader)
                .foregroundStyle(Color.textTertiary)

            TextField("22", value: $profile.port, format: .number)
                .font(.willoMono(.body))
                .foregroundStyle(Color.textPrimary)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .padding(12)
                .recessedPanel()
                .frame(width: 80)
        }
    }

    private var authenticationSection: some View {
        EditorSection(title: "Authentication", icon: "key") {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    AuthMethodButton(title: "SSH Key", icon: "key.fill", isSelected: authMethodType == 0) {
                        profile.authMethod = .key(keyId: nil)
                    }
                    AuthMethodButton(title: "Password", icon: "lock.fill", isSelected: authMethodType == 1) {
                        profile.authMethod = .password(password)
                    }
                    AuthMethodButton(title: "Agent", icon: "person.fill", isSelected: authMethodType == 2) {
                        profile.authMethod = .agent
                    }
                }

                if profile.authMethod.isPassword {
                    SecureField("Password", text: $password)
                        .font(.willoMono(.body))
                        .foregroundStyle(Color.textPrimary)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .padding(12)
                        .recessedPanel()
                }
            }
        }
    }

    private var connectionTypeSection: some View {
        EditorSection(title: "Connection Type", icon: "bolt") {
            VStack(spacing: 12) {
                Toggle(isOn: $profile.preferMosh) {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(profile.preferMosh ? Color.terminalAmber : Color.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Mosh")
                                .font(.willoMono(.body, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Text("Better for high-latency connections")
                                .font(.willoCaption)
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                }
                .tint(.terminalAmber)
            }
        }
    }

    private var sessionSection: some View {
        EditorSection(title: "Session", icon: "terminal") {
            VStack(spacing: 12) {
                multiplexerPicker
                if profile.multiplexer != .none {
                    startupBehaviorPicker
                }
            }
        }
    }

    private var multiplexerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MULTIPLEXER")
                .font(.willoSectionHeader)
                .foregroundStyle(Color.textTertiary)

            HStack(spacing: 8) {
                ForEach(MultiplexerPreference.allCases, id: \.self) { pref in
                    MultiplexerButton(
                        preference: pref,
                        isSelected: profile.multiplexer == pref
                    ) {
                        profile.multiplexer = pref
                    }
                }
            }
        }
    }

    private var startupBehaviorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ON CONNECT")
                .font(.willoSectionHeader)
                .foregroundStyle(Color.textTertiary)

            HStack(spacing: 8) {
                ForEach(StartupBehavior.allCases, id: \.self) { behavior in
                    StartupBehaviorButton(
                        behavior: behavior,
                        isSelected: profile.startupBehavior == behavior
                    ) {
                        profile.startupBehavior = behavior
                    }
                }
            }

            Text(profile.startupBehavior.description)
                .font(.willoCaption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private var canSave: Bool {
        !profile.displayName.isEmpty && !profile.hostname.isEmpty && !profile.username.isEmpty
    }

    private func saveProfile() {
        if case .password = profile.authMethod {
            profile.authMethod = .password(password)
        }

        if isNew {
            appState.serverProfiles.append(profile)
        } else if let index = appState.serverProfiles.firstIndex(where: { $0.id == profile.id }) {
            appState.serverProfiles[index] = profile
        }
        dismiss()
    }
}

// MARK: - Editor Components

private struct EditorSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.terminalCyan)

                Text(title.uppercased())
                    .font(.willoSectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(Color.textSecondary)
            }

            content()
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.machineGray)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.bezelLight.opacity(0.2), lineWidth: 1)
                        }
                }
        }
    }
}

private struct EditorField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.willoSectionHeader)
                .foregroundStyle(Color.textTertiary)

            TextField(placeholder, text: $text)
                .font(.willoMono(.body))
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()
                .padding(12)
                .recessedPanel()
        }
    }
}

private struct AuthMethodButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.willoCaption)
            }
            .foregroundStyle(isSelected ? Color.machineBlack : Color.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.terminalCyan : Color.bezelGray)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MultiplexerButton: View {
    let preference: MultiplexerPreference
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(preference.displayName)
                .font(.willoMono(.caption, weight: .semibold))
                .foregroundStyle(isSelected ? Color.machineBlack : Color.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.terminalCyan : Color.bezelGray)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct StartupBehaviorButton: View {
    let behavior: StartupBehavior
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(behavior.displayName)
                .font(.willoMono(.caption, weight: .semibold))
                .foregroundStyle(isSelected ? Color.machineBlack : Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.terminalGreen : Color.bezelGray)
                }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ServerProfilesView()
        .environmentObject({
            let state = AppState()
            state.serverProfiles = [
                ServerProfile(
                    displayName: "Devbox",
                    hostname: "devbox.local",
                    username: "dev",
                    lastConnected: Date().addingTimeInterval(-3600)
                ),
                ServerProfile(
                    displayName: "Production",
                    hostname: "prod.example.com",
                    username: "deploy",
                    preferMosh: true
                ),
            ]
            return state
        }())
}
