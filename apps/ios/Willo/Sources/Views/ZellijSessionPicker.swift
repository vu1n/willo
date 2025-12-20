import SwiftUI

/// A picker view for selecting or creating zellij sessions on the server
struct ZellijSessionPicker: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appearanceSettings: AppearanceSettings

    /// Available sessions fetched from server
    @State private var sessions: [ZellijRemoteSession] = []
    @State private var isLoading = true
    @State private var error: String?

    /// New session name input
    @State private var newSessionName = ""

    /// Callback when a session is selected
    let onSelect: (String) -> Void

    /// Callback for listing sessions (runs zellij list-sessions)
    let onListSessions: () async throws -> [ZellijRemoteSession]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    loadingView
                } else if let error = error {
                    errorView(message: error)
                } else {
                    sessionListView
                }
            }
            .background(Color.machineDark)
            .navigationTitle("Zellij Sessions")
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
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadSessions()
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .terminalCyan))
                .scaleEffect(1.2)

            Text("Loading sessions...")
                .font(.willoMono(.subheadline))
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Color.terminalAmber)

            Text("Failed to list sessions")
                .font(.willoMono(.headline, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            Text(message)
                .font(.willoCaption)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                Task { await loadSessions() }
            } label: {
                Text("Retry")
                    .font(.willoMono(.callout, weight: .semibold))
                    .foregroundStyle(Color.machineBlack)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.terminalCyan)
                    .cornerRadius(8)
            }

            Spacer()
        }
    }

    private var sessionListView: some View {
        VStack(spacing: 0) {
            // New session input
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.terminalGreen)

                    TextField("New session name", text: $newSessionName)
                        .font(.willoMono(.body))
                        .foregroundStyle(Color.textPrimary)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    if !newSessionName.isEmpty {
                        Button {
                            createSession(name: newSessionName)
                        } label: {
                            Text("Create")
                                .font(.willoMono(.caption, weight: .semibold))
                                .foregroundStyle(Color.machineBlack)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.terminalGreen)
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(14)
                .background(Color.machineGray)
                .cornerRadius(10)
            }
            .padding(16)
            .background(Color.bezelGray.opacity(0.3))

            Divider()
                .background(Color.bezelLight.opacity(0.3))

            // Existing sessions
            if sessions.isEmpty {
                emptySessionsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sessions) { session in
                            SessionRow(session: session) {
                                attachToSession(session)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var emptySessionsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "rectangle.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.textTertiary)

            Text("No Active Sessions")
                .font(.willoMono(.headline, weight: .semibold))
                .foregroundStyle(Color.textSecondary)

            Text("Create a new session above")
                .font(.willoCaption)
                .foregroundStyle(Color.textTertiary)

            Spacer()
        }
    }

    // MARK: - Actions

    private func loadSessions() async {
        isLoading = true
        error = nil

        do {
            sessions = try await onListSessions()
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func attachToSession(_ session: ZellijRemoteSession) {
        onSelect(session.name)
        dismiss()
    }

    private func createSession(name: String) {
        onSelect(name)
        dismiss()
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: ZellijRemoteSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Session icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.machineBlack)
                        .frame(width: 40, height: 40)

                    Image(systemName: "terminal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.terminalCyan)
                }

                // Session info
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.willoMono(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    HStack(spacing: 8) {
                        if let tabCount = session.tabCount {
                            Label("\(tabCount) tabs", systemImage: "square.on.square")
                                .font(.willoCaption)
                                .foregroundStyle(Color.textTertiary)
                        }

                        if session.isAttached {
                            Text("ATTACHED")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.terminalAmber)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.terminalAmber.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                }

                Spacer()

                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.terminalCyan)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.machineGray)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.bezelLight.opacity(0.2), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Remote Session Model

/// Represents a zellij session on the remote server
struct ZellijRemoteSession: Identifiable {
    let id: String
    let name: String
    let tabCount: Int?
    let isAttached: Bool

    init(name: String, tabCount: Int? = nil, isAttached: Bool = false) {
        self.id = name
        self.name = name
        self.tabCount = tabCount
        self.isAttached = isAttached
    }

    /// Parse zellij list-sessions output
    /// Format: "session-name [Created: timestamp] (ATTACHED)"
    static func parse(from output: String) -> [ZellijRemoteSession] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            // Check for ATTACHED marker
            let isAttached = trimmed.contains("(ATTACHED)")

            // Extract session name (first word before any brackets)
            let parts = trimmed.split(separator: " ")
            guard let name = parts.first else { return nil }

            return ZellijRemoteSession(
                name: String(name),
                isAttached: isAttached
            )
        }
    }
}

#Preview {
    ZellijSessionPicker(
        onSelect: { name in print("Selected: \(name)") },
        onListSessions: {
            // Simulate async load
            try? await Task.sleep(nanoseconds: 500_000_000)
            return [
                ZellijRemoteSession(name: "main", tabCount: 3, isAttached: true),
                ZellijRemoteSession(name: "dev", tabCount: 2),
                ZellijRemoteSession(name: "testing"),
            ]
        }
    )
    .environmentObject(AppearanceSettings())
}
