import SwiftUI

/// Container view that displays session tabs and the active terminal
struct SessionContainerView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @State private var showingNewSession = false
    @State private var showingSessionGrid = false
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeDirection: SwipeDirection?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private enum SwipeDirection {
        case left, right
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    // Session tab bar (only show if multiple sessions or on iPad)
                    if shouldShowTabBar {
                        sessionTabBar
                    }

                    // Active terminal view
                    if let session = sessionStore.activeSession {
                        TerminalWorkspaceView(
                            workspace: Workspace(
                                id: session.id,
                                serverProfile: session.serverProfile,
                                sessionName: session.name,
                                connectionState: session.connectionState
                            )
                        )
                        .offset(x: swipeOffset)
                    } else {
                        // No active session
                        EmptySessionView(onCreateSession: { showingNewSession = true })
                    }
                }

                // Edge swipe zones (invisible, only for gesture detection)
                HStack(spacing: 0) {
                    // Left edge - swipe right for previous session
                    Color.clear
                        .frame(width: 20)
                        .contentShape(Rectangle())
                        .gesture(edgeSwipeGesture(edge: .left, screenWidth: geometry.size.width))

                    Spacer()

                    // Right edge - swipe left for next session
                    Color.clear
                        .frame(width: 20)
                        .contentShape(Rectangle())
                        .gesture(edgeSwipeGesture(edge: .right, screenWidth: geometry.size.width))
                }

                // Session switch indicator
                if swipeDirection != nil {
                    sessionSwitchIndicator
                }
            }
        }
        .background(Color.machineBlack)
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet()
        }
        .sheet(isPresented: $showingSessionGrid) {
            SessionGridView()
        }
        .gesture(pullDownGesture)
    }

    // MARK: - Tab Bar

    private var shouldShowTabBar: Bool {
        // Always show on iPad, or when there are 2+ sessions
        horizontalSizeClass == .regular || sessionStore.sessions.count > 1
    }

    @ViewBuilder
    private var sessionTabBar: some View {
        if horizontalSizeClass == .compact {
            // Phone: compact dots
            CompactSessionTabBar {
                showingNewSession = true
            }
        } else {
            // iPad: full tab bar
            SessionTabBar {
                showingNewSession = true
            }
        }
    }

    // MARK: - Pull Down Gesture

    private var pullDownGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                // Pull down from top to show session grid
                if value.translation.height > 100 && value.startLocation.y < 100 {
                    showingSessionGrid = true
                }
            }
    }

    // MARK: - Edge Swipe Gesture

    private enum Edge { case left, right }

    private func edgeSwipeGesture(edge: Edge, screenWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                guard sessionStore.sessions.count > 1 else { return }

                let threshold: CGFloat = 60
                switch edge {
                case .left:
                    // Swiping right from left edge → previous session
                    if value.translation.width > 0 {
                        swipeOffset = min(value.translation.width * 0.3, 50)
                        if value.translation.width > threshold {
                            swipeDirection = .right
                        }
                    }
                case .right:
                    // Swiping left from right edge → next session
                    if value.translation.width < 0 {
                        swipeOffset = max(value.translation.width * 0.3, -50)
                        if value.translation.width < -threshold {
                            swipeDirection = .left
                        }
                    }
                }
            }
            .onEnded { value in
                let threshold: CGFloat = 60

                switch edge {
                case .left:
                    if value.translation.width > threshold {
                        // Switch to previous session
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            sessionStore.previousSession()
                        }
                    }
                case .right:
                    if value.translation.width < -threshold {
                        // Switch to next session
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            sessionStore.nextSession()
                        }
                    }
                }

                // Reset state
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    swipeOffset = 0
                    swipeDirection = nil
                }
            }
    }

    // MARK: - Session Switch Indicator

    @ViewBuilder
    private var sessionSwitchIndicator: some View {
        HStack {
            if swipeDirection == .right {
                // Previous session indicator on left
                sessionIndicatorPill(for: previousSession, alignment: .leading)
                Spacer()
            } else if swipeDirection == .left {
                // Next session indicator on right
                Spacer()
                sessionIndicatorPill(for: nextSession, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .transition(.opacity)
    }

    private var previousSession: WilloSession? {
        guard let currentIndex = sessionStore.sessions.firstIndex(where: { $0.id == sessionStore.activeSessionId }) else {
            return nil
        }
        let previousIndex = currentIndex == 0 ? sessionStore.sessions.count - 1 : currentIndex - 1
        return sessionStore.sessions[previousIndex]
    }

    private var nextSession: WilloSession? {
        guard let currentIndex = sessionStore.sessions.firstIndex(where: { $0.id == sessionStore.activeSessionId }) else {
            return nil
        }
        let nextIndex = (currentIndex + 1) % sessionStore.sessions.count
        return sessionStore.sessions[nextIndex]
    }

    @ViewBuilder
    private func sessionIndicatorPill(for session: WilloSession?, alignment: HorizontalAlignment) -> some View {
        if let session = session {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.color.color)
                    .frame(width: 8, height: 8)

                Text(session.displayTitle)
                    .font(.willoMono(.caption, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(Color.machineGray)
                    .overlay {
                        Capsule()
                            .strokeBorder(session.color.color.opacity(0.5), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        }
    }
}

// MARK: - Empty Session View

struct EmptySessionView: View {
    let onCreateSession: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.textTertiary)

            VStack(spacing: 8) {
                Text("No Active Session")
                    .font(.willoMono(.title2, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                Text("Create a session to get started")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textSecondary)
            }

            IndustrialButton(title: "New Session", style: .primary) {
                onCreateSession()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.machineBlack)
    }
}

// MARK: - New Session Sheet

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionStore: SessionStore
    @State private var selectedProfileId: UUID?
    @State private var sessionName = ""
    @State private var selectedColor: SessionColor = .cyan

    var body: some View {
        NavigationStack {
            Form {
                // Server profile selection
                Section("Server") {
                    if appState.serverProfiles.isEmpty {
                        Text("No server profiles configured")
                            .foregroundStyle(Color.textTertiary)
                    } else {
                        ForEach(appState.serverProfiles) { profile in
                            ProfileRow(
                                profile: profile,
                                isSelected: selectedProfileId == profile.id
                            ) {
                                selectedProfileId = profile.id
                                if sessionName.isEmpty {
                                    // Auto-generate session name from template
                                    sessionName = expandTemplate(profile.sessionTemplate, profile: profile)
                                }
                            }
                        }
                    }
                }

                // Session details
                Section("Session") {
                    TextField("Session Name", text: $sessionName)
                        .font(.willoMono(.body))

                    // Color picker
                    HStack {
                        Text("Color")
                        Spacer()
                        HStack(spacing: 8) {
                            ForEach(SessionColor.allCases, id: \.self) { color in
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        if selectedColor == color {
                                            Circle()
                                                .stroke(Color.white, lineWidth: 2)
                                        }
                                    }
                                    .onTapGesture {
                                        selectedColor = color
                                    }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.machineBlack)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createSession()
                    }
                    .disabled(selectedProfileId == nil || sessionName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func expandTemplate(_ template: String, profile: ServerProfile) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{user}", with: profile.username)
        result = result.replacingOccurrences(of: "{host}", with: profile.hostname.split(separator: ".").first.map(String.init) ?? profile.hostname)
        result = result.replacingOccurrences(of: "{project}", with: "willo")
        result = result.replacingOccurrences(of: "{env}", with: "dev")
        result = result.replacingOccurrences(of: "{role}", with: "terminal")
        return result
    }

    private func createSession() {
        guard let profileId = selectedProfileId,
              let profile = appState.serverProfiles.first(where: { $0.id == profileId }) else {
            return
        }

        sessionStore.createSession(
            profile: profile,
            name: sessionName,
            color: selectedColor
        )
        dismiss()
    }
}

struct ProfileRow: View {
    let profile: ServerProfile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.willoMono(.body, weight: .medium))
                        .foregroundStyle(Color.textPrimary)

                    Text(profile.connectionString)
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.terminalGreen)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Grid View

struct SessionGridView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var sessionStore: SessionStore

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(sessionStore.sessions) { session in
                        SessionGridCard(session: session) {
                            sessionStore.setActiveSession(session.id)
                            dismiss()
                        }
                    }
                }
                .padding()
            }
            .background(Color.machineBlack)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SessionGridCard: View {
    let session: WilloSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail placeholder
                Rectangle()
                    .fill(Color.machineGray)
                    .frame(height: 100)
                    .overlay {
                        Image(systemName: "terminal")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.textTertiary)
                    }

                // Color accent bar
                Rectangle()
                    .fill(session.color.color)
                    .frame(height: 3)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.displayTitle)
                            .font(.willoMono(.caption, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(session.lastActivityText)
                            .font(.willoCaption)
                            .foregroundStyle(Color.textTertiary)
                    }

                    Text(session.subtitle)
                        .font(.willoCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)

                    // Status
                    HStack(spacing: 4) {
                        SessionActivityIndicator(state: session.activityState, color: session.color)
                        Text(session.activityState.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(session.activityState.statusColor)
                    }
                }
                .padding(12)
            }
            .background(Color.machineGray)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.bezelLight.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Activity State Extensions

extension ActivityState {
    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .active: return "Active"
        case .hasOutput(let count): return "\(count) new"
        case .running: return "Running"
        case .error: return "Error"
        }
    }
}

// MARK: - Previews

#Preview("Session Container") {
    SessionContainerView()
        .environmentObject(SessionStore())
        .environmentObject(SessionManager(appManager: GhosttyAppManager()))
        .environmentObject(AppearanceSettings())
        .environmentObject(AppState())
}

#Preview("New Session Sheet") {
    NewSessionSheet()
        .environmentObject(AppState())
        .environmentObject(SessionStore())
}
