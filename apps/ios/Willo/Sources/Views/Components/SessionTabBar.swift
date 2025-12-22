import SwiftUI

/// Compact session tab bar for switching between sessions
struct SessionTabBar: View {
    @EnvironmentObject var sessionStore: SessionStore
    let highlightedSessionId: UUID?
    let onAddSession: () -> Void

    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 0) {
            // Session tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sessionStore.sessions) { session in
                        SessionTab(
                            session: session,
                            isActive: session.id == sessionStore.activeSessionId,
                            isHighlighted: session.id == highlightedSessionId,
                            namespace: tabNamespace,
                            onTap: {
                                sessionStore.setActiveSession(session.id)
                            },
                            onClose: {
                                sessionStore.closeSession(session.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // Add session button
            Button(action: onAddSession) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle()
                            .fill(Color.machineGray)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.bezelLight.opacity(0.3), lineWidth: 1)
                            }
                    }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
        }
        .background {
            Rectangle()
                .fill(Color.machineBlack)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.bezelLight.opacity(0.15))
                        .frame(height: 1)
                }
        }
    }
}

// MARK: - Session Tab

struct SessionTab: View {
    let session: WilloSession
    let isActive: Bool
    let isHighlighted: Bool
    let namespace: Namespace.ID
    let onTap: () -> Void
    let onClose: () -> Void

    @State private var isPressed = false
    @State private var showCloseButton = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    // Activity indicator
                    SessionActivityIndicator(state: session.activityState, color: session.color)

                    // Session name
                    Text(session.displayTitle)
                        .font(.willoMono(.caption, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
                        .lineLimit(1)

                    // Device origin icon (subtle indicator)
                    DeviceOriginBadge(device: session.deviceOrigin, isActive: isActive)

                    // Unread badge
                    if session.activityState.hasUnread {
                        UnreadBadge(count: session.activityState.unreadCount)
                    }
                }
            }
            .buttonStyle(.plain)

            // Close button (show on hover/active)
            if isActive || showCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 16, height: 16)
                        .background {
                            Circle()
                                .fill(Color.machineGray.opacity(0.8))
                        }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isActive {
                // Active tab: full color treatment
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.machineGray)
                    .overlay(alignment: .bottom) {
                        // Bold color accent bar
                        RoundedRectangle(cornerRadius: 1)
                            .fill(session.color.color)
                            .frame(height: 2)
                            .padding(.horizontal, 4)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(session.color.color.opacity(isHighlighted ? 1.0 : 0.4), lineWidth: isHighlighted ? 2 : 1)
                    }
                    .shadow(color: session.color.color.opacity(isHighlighted ? 0.6 : 0.2), radius: isHighlighted ? 8 : 4, x: 0, y: 0)
                    .matchedGeometryEffect(id: "activeTab", in: namespace)
            } else {
                // Inactive tab: subtle color presence (LED dashboard style)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isPressed ? Color.machineGray.opacity(0.5) : Color.machineGray.opacity(0.2))
                    .overlay(alignment: .leading) {
                        // Colored left edge indicator (like a status LED strip)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(session.color.color.opacity(isHighlighted ? 1.0 : 0.5))
                            .frame(width: isHighlighted ? 4 : 2)
                            .padding(.vertical, 4)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(session.color.color.opacity(isHighlighted ? 0.6 : 0.15), lineWidth: isHighlighted ? 2 : 1)
                    }
                    .shadow(color: session.color.color.opacity(isHighlighted ? 0.3 : 0), radius: isHighlighted ? 4 : 0, x: 0, y: 0)
            }
        }
        .scaleEffect(isPressed ? 0.95 : (isHighlighted ? 1.05 : 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        .animation(.easeInOut(duration: 0.15), value: showCloseButton)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHighlighted)
        .onHover { hovering in
            showCloseButton = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Session Activity Indicator

struct SessionActivityIndicator: View {
    let state: ActivityState
    let color: SessionColor

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            // Base circle with session color
            Circle()
                .fill(indicatorColor.opacity(0.3))
                .frame(width: 8, height: 8)

            // Inner dot
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)

            // Pulse animation for running state
            if case .running = state {
                Circle()
                    .stroke(indicatorColor, lineWidth: 1)
                    .frame(width: 12, height: 12)
                    .scaleEffect(isAnimating ? 1.5 : 1.0)
                    .opacity(isAnimating ? 0 : 0.5)
            }
        }
        .onAppear {
            if case .running = state {
                withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
        }
        .onChange(of: state) { _, newState in
            if case .running = newState {
                withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            } else {
                isAnimating = false
            }
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .idle:
            // Use session color at reduced brightness for idle (not gray)
            return color.color.opacity(0.6)
        case .active:
            return color.color
        case .hasOutput:
            return .terminalCyan
        case .running:
            return .terminalAmber
        case .error:
            return .terminalRed
        }
    }
}

// MARK: - Unread Badge

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                Capsule()
                    .fill(Color.terminalRed)
            }
    }
}

// MARK: - Device Origin Badge

/// Small icon showing which device created the session
struct DeviceOriginBadge: View {
    let device: DeviceOrigin
    let isActive: Bool

    var body: some View {
        Image(systemName: device.icon)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(isActive ? Color.textTertiary : Color.textTertiary.opacity(0.6))
            .help("\(device.displayName) session")
    }
}

// MARK: - Compact Session Tab Bar (Phone)

/// Compact tab bar for phone - shows only icons with color indicators
struct CompactSessionTabBar: View {
    @EnvironmentObject var sessionStore: SessionStore
    let highlightedSessionId: UUID?
    let onAddSession: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Session dots
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(sessionStore.sessions) { session in
                        CompactSessionDot(
                            session: session,
                            isActive: session.id == sessionStore.activeSessionId,
                            isHighlighted: session.id == highlightedSessionId
                        ) {
                            sessionStore.setActiveSession(session.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Spacer()

            // Add button
            Button(action: onAddSession) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .background(Color.machineBlack)
    }
}

struct CompactSessionDot: View {
    let session: WilloSession
    let isActive: Bool
    let isHighlighted: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Outer ring - always show but brighter when active or highlighted
                Circle()
                    .stroke(session.color.color.opacity(isActive ? 1.0 : (isHighlighted ? 0.8 : 0.3)), lineWidth: isActive ? 2 : (isHighlighted ? 2 : 1))
                    .frame(width: isHighlighted ? 28 : 24, height: isHighlighted ? 28 : 24)

                // Main dot - always show session color
                Circle()
                    .fill(session.color.color.opacity(isActive ? 1.0 : (isHighlighted ? 0.8 : 0.5)))
                    .frame(width: isHighlighted ? 18 : 16, height: isHighlighted ? 18 : 16)

                // Inner glow when active or highlighted
                if isActive || isHighlighted {
                    Circle()
                        .fill(session.color.color.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .blur(radius: 2)
                }

                // Activity overlay - unread badge
                if session.activityState.hasUnread {
                    Circle()
                        .fill(Color.terminalRed)
                        .frame(width: 8, height: 8)
                        .offset(x: 8, y: -8)
                }

                // Running indicator
                if case .running = session.activityState {
                    Circle()
                        .stroke(Color.terminalAmber, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHighlighted)
    }
}

// MARK: - Previews

#Preview("Session Tab Bar") {
    SessionTabBarPreview()
}

#Preview("Compact Tab Bar") {
    CompactSessionTabBarPreview()
}

@MainActor
private struct SessionTabBarPreview: View {
    @StateObject private var store = SessionStore()

    var body: some View {
        VStack {
            SessionTabBar(highlightedSessionId: nil) { }
                .environmentObject(store)
            Spacer()
        }
        .background(Color.machineBlack)
        .onAppear {
            setupPreviewSessions()
        }
    }

    private func setupPreviewSessions() {
        let profile = ServerProfile(
            displayName: "Devbox",
            hostname: "devbox.local",
            username: "dev"
        )
        store.createSession(profile: profile, name: "dev-work", color: .cyan)
        store.createSession(profile: profile, name: "monitoring", color: .amber)
        store.createSession(profile: profile, name: "deploy", color: .green)
    }
}

@MainActor
private struct CompactSessionTabBarPreview: View {
    @StateObject private var store = SessionStore()

    var body: some View {
        VStack {
            CompactSessionTabBar(highlightedSessionId: nil) { }
                .environmentObject(store)
            Spacer()
        }
        .background(Color.machineBlack)
        .onAppear {
            let profile = ServerProfile(
                displayName: "Devbox",
                hostname: "devbox.local",
                username: "dev"
            )
            store.createSession(profile: profile, name: "dev-work", color: .cyan)
            store.createSession(profile: profile, name: "monitoring", color: .amber)
        }
    }
}
