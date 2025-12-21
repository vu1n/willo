import Foundation
import SwiftUI
import Combine

/// Manages WilloSession instances (app-level tabs)
///
/// SessionStore is responsible for:
/// - Creating and managing WilloSession instances (app tabs)
/// - Tracking the active session
/// - Persisting session metadata
/// - Coordinating with SessionManager for actual connections
@MainActor
final class SessionStore: ObservableObject {
    // MARK: - Published State

    /// All sessions (app tabs)
    @Published private(set) var sessions: [WilloSession] = []

    /// Currently active session ID
    @Published var activeSessionId: UUID?

    // MARK: - Dependencies

    private weak var sessionManager: SessionManager?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Persistence Keys

    private static let sessionsKey = "willoSessions"
    private static let activeSessionKey = "activeSessionId"

    // MARK: - Init

    init(sessionManager: SessionManager? = nil) {
        self.sessionManager = sessionManager
        loadSessions()
    }

    // MARK: - Computed Properties

    /// Currently active session
    var activeSession: WilloSession? {
        sessions.first { $0.id == activeSessionId }
    }

    /// Sessions sorted by last activity
    var sessionsByActivity: [WilloSession] {
        sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Sessions grouped by connection state
    var connectedSessions: [WilloSession] {
        sessions.filter { $0.connectionState == .connected }
    }

    var disconnectedSessions: [WilloSession] {
        sessions.filter { $0.connectionState == .disconnected }
    }

    /// Sessions with unread output
    var sessionsWithUnread: [WilloSession] {
        sessions.filter { $0.activityState.hasUnread }
    }

    // MARK: - Session Management

    /// Create a new session from a server profile
    @discardableResult
    func createSession(from profile: ServerProfile, color: SessionColor? = nil) -> WilloSession {
        let session = WilloSession.create(from: profile, color: color)
        sessions.append(session)

        // Set as active if it's the first session
        if activeSessionId == nil {
            activeSessionId = session.id
        }

        saveSessions()
        return session
    }

    /// Create a session with custom name and description
    @discardableResult
    func createSession(
        profile: ServerProfile,
        name: String,
        description: String = "",
        color: SessionColor = .cyan
    ) -> WilloSession {
        let session = WilloSession(
            serverProfile: profile,
            name: name,
            description: description,
            color: color
        )
        sessions.append(session)

        if activeSessionId == nil {
            activeSessionId = session.id
        }

        saveSessions()
        return session
    }

    /// Add a pre-created session (for migration from workspaces)
    func addSession(_ session: WilloSession) {
        // Check if session with this ID already exists
        guard !sessions.contains(where: { $0.id == session.id }) else { return }

        sessions.append(session)

        if activeSessionId == nil {
            activeSessionId = session.id
        }

        saveSessions()
    }

    /// Switch to a session by ID
    func setActiveSession(_ sessionId: UUID?) {
        guard sessionId != activeSessionId else { return }

        // Mark previous session as idle if it was active
        if let currentId = activeSessionId,
           let index = sessions.firstIndex(where: { $0.id == currentId }) {
            if sessions[index].activityState == .active {
                sessions[index].activityState = .idle
            }
        }

        activeSessionId = sessionId

        // Mark new session as active and clear unread
        if let newId = sessionId,
           let index = sessions.firstIndex(where: { $0.id == newId }) {
            sessions[index].activityState = .active
            sessions[index].lastActivityAt = Date()
        }

        saveSessions()
    }

    /// Switch to next session (for swipe gestures)
    func nextSession() {
        guard let currentIndex = sessions.firstIndex(where: { $0.id == activeSessionId }) else {
            activeSessionId = sessions.first?.id
            return
        }

        let nextIndex = (currentIndex + 1) % sessions.count
        setActiveSession(sessions[nextIndex].id)
    }

    /// Switch to previous session (for swipe gestures)
    func previousSession() {
        guard let currentIndex = sessions.firstIndex(where: { $0.id == activeSessionId }) else {
            activeSessionId = sessions.first?.id
            return
        }

        let previousIndex = currentIndex == 0 ? sessions.count - 1 : currentIndex - 1
        setActiveSession(sessions[previousIndex].id)
    }

    /// Close and remove a session
    func closeSession(_ sessionId: UUID) {
        sessions.removeAll { $0.id == sessionId }

        // Update active session if needed
        if activeSessionId == sessionId {
            activeSessionId = sessions.first?.id
        }

        saveSessions()
    }

    /// Update session metadata
    func updateSession(
        _ sessionId: UUID,
        name: String? = nil,
        description: String? = nil,
        color: SessionColor? = nil
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        if let name = name {
            sessions[index].name = name
        }
        if let description = description {
            sessions[index].description = description
        }
        if let color = color {
            sessions[index].color = color
        }

        saveSessions()
    }

    // MARK: - Connection State

    /// Update session connection state
    func setConnectionState(_ sessionId: UUID, state: ConnectionState) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].connectionState = state
    }

    /// Update session activity state
    func setActivityState(_ sessionId: UUID, state: ActivityState) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].activityState = state
        sessions[index].lastActivityAt = Date()
    }

    /// Mark session as having new output
    func incrementUnread(_ sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }),
              sessionId != activeSessionId else { return }

        let currentCount = sessions[index].activityState.unreadCount
        sessions[index].activityState = .hasOutput(count: currentCount + 1)
        sessions[index].lastActivityAt = Date()
    }

    /// Clear unread count for a session
    func clearUnread(_ sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        if sessions[index].activityState.hasUnread {
            sessions[index].activityState = .active
        }
    }

    // MARK: - Reordering

    /// Move a session to a new position
    func moveSession(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        saveSessions()
    }

    // MARK: - Persistence

    private func loadSessions() {
        // Load session IDs and metadata
        guard let data = UserDefaults.standard.data(forKey: Self.sessionsKey) else {
            return
        }

        do {
            sessions = try JSONDecoder().decode([WilloSession].self, from: data)
        } catch {
            print("[SessionStore] Failed to load sessions: \(error)")
        }

        // Load active session ID
        if let activeIdString = UserDefaults.standard.string(forKey: Self.activeSessionKey),
           let activeId = UUID(uuidString: activeIdString) {
            activeSessionId = activeId
        } else {
            activeSessionId = sessions.first?.id
        }
    }

    private func saveSessions() {
        do {
            let data = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        } catch {
            print("[SessionStore] Failed to save sessions: \(error)")
        }

        if let activeId = activeSessionId {
            UserDefaults.standard.set(activeId.uuidString, forKey: Self.activeSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeSessionKey)
        }
    }

    /// Resolve server profiles after loading
    /// Call this after server profiles are available
    func resolveServerProfiles(from profiles: [ServerProfile]) {
        var sessionsToRemove: [UUID] = []

        for (index, session) in sessions.enumerated() {
            // Match by server profile ID (stored in placeholder during decode)
            if let matchingProfile = profiles.first(where: { $0.id == session.serverProfile.id }) {
                print("[SessionStore] Resolved profile for session '\(session.name)': \(matchingProfile.displayName)")
                // Create a new session with the resolved profile
                sessions[index] = WilloSession(
                    id: session.id,
                    serverProfile: matchingProfile,
                    name: session.name,
                    description: session.description,
                    color: session.color,
                    connectionState: session.connectionState,
                    activityState: session.activityState,
                    createdAt: session.createdAt,
                    lastActivityAt: session.lastActivityAt
                )
            } else if session.serverProfile.hostname.isEmpty {
                // Profile was deleted or not found - mark for removal
                print("[SessionStore] Could not resolve profile for session '\(session.name)' (ID: \(session.serverProfile.id)) - marking for removal")
                sessionsToRemove.append(session.id)
            }
        }

        // Remove sessions with unresolved profiles
        if !sessionsToRemove.isEmpty {
            sessions.removeAll { sessionsToRemove.contains($0.id) }
            if let activeId = activeSessionId, sessionsToRemove.contains(activeId) {
                activeSessionId = sessions.first?.id
            }
        }
    }
}
