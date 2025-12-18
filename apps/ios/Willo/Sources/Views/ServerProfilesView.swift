import SwiftUI

struct ServerProfilesView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var editingProfile: ServerProfile?
    @State private var showingNewProfile = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.serverProfiles) { profile in
                    ServerProfileRow(profile: profile) {
                        editingProfile = profile
                    }
                }
                .onDelete(perform: deleteProfiles)
            }
            .navigationTitle("Servers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewProfile = true
                    } label: {
                        Image(systemName: "plus")
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
            .overlay {
                if appState.serverProfiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "server.rack")
                    } description: {
                        Text("Add a server to get started")
                    } actions: {
                        Button("Add Server") {
                            showingNewProfile = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func deleteProfiles(at offsets: IndexSet) {
        appState.serverProfiles.remove(atOffsets: offsets)
    }
}

struct ServerProfileRow: View {
    let profile: ServerProfile
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.headline)

                    Text(profile.connectionString)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Label(profile.multiplexer.displayName, systemImage: "rectangle.split.3x1")
                        if let lastConnected = profile.lastConnected {
                            Text("·")
                            Text(lastConnected, style: .relative)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProfileEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState

    @State var profile: ServerProfile
    @State private var password: String = ""
    let isNew: Bool

    // Map auth method to picker index
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
        // Extract password from profile if it exists
        if case .password(let pwd) = profile.authMethod {
            self._password = State(initialValue: pwd)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Display Name", text: $profile.displayName)
                    TextField("Hostname", text: $profile.hostname)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $profile.port, format: .number)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    TextField("Username", text: $profile.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: Binding(
                        get: { authMethodType },
                        set: { newType in
                            switch newType {
                            case 0: profile.authMethod = .key(keyId: nil)
                            case 1: profile.authMethod = .password(password)
                            case 2: profile.authMethod = .agent
                            default: break
                            }
                        }
                    )) {
                        Text("SSH Key").tag(0)
                        Text("Password").tag(1)
                        Text("SSH Agent").tag(2)
                    }

                    // Show password field when password auth is selected
                    if profile.authMethod.isPassword {
                        SecureField("Password", text: $password)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }

                    // TODO: Key selection UI for SSH Key auth
                }

                Section("Connection Type") {
                    Toggle("Use Mosh", isOn: $profile.preferMosh)

                    if profile.preferMosh {
                        Text("Mosh provides better responsiveness over high-latency or unreliable connections")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Session") {
                    Picker("Multiplexer", selection: $profile.multiplexer) {
                        ForEach(MultiplexerPreference.allCases, id: \.self) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }

                    TextField("Session Template", text: $profile.sessionTemplate)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle(isNew ? "New Server" : "Edit Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .disabled(profile.displayName.isEmpty || profile.hostname.isEmpty || profile.username.isEmpty)
                }
            }
        }
    }

    private func saveProfile() {
        // Sync password to authMethod before saving
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
                    username: "deploy"
                ),
            ]
            return state
        }())
}
