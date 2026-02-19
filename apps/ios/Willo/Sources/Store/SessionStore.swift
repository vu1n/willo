import Foundation
import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.willo.app", category: "SessionStore")

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

    /// Currently active Zellij bridge (for UI reactivity)
    /// Updated when active session changes or bridge starts/stops
    @Published private(set) var activeBridge: ZellijBridge?

    // MARK: - Active Terminal Sessions

    /// Cache of active terminal sessions (kept alive when switching tabs)
    /// Key: WilloSession.id, Value: TerminalSession
    private var activeTerminalSessions: [UUID: TerminalSession] = [:]

    // MARK: - Zellij Bridge Instances

    /// Cache of Zellij bridges per session
    /// Key: WilloSession.id, Value: ZellijBridge
    private var zellijBridges: [UUID: ZellijBridge] = [:]

    // MARK: - Dependencies

    private weak var sessionManager: SessionManager?
    private var cancellables = Set<AnyCancellable>()

    /// Thumbnail manager for capturing terminal screenshots
    #if os(iOS)
    let thumbnailManager = ThumbnailManager()
    #endif

    /// Cloud sync manager
    private let cloudSync = CloudSyncManager.shared

    // MARK: - Persistence Keys

    private static let sessionsKey = "willoSessions"
    private static let activeSessionKey = "activeSessionId"

    // MARK: - Init

    init(sessionManager: SessionManager? = nil) {
        self.sessionManager = sessionManager
        loadSessions()
        setupCloudSync()
    }

    // MARK: - Terminal Session Management

    /// Get cached terminal session for a WilloSession
    func getTerminalSession(for sessionId: UUID) -> TerminalSession? {
        return activeTerminalSessions[sessionId]
    }

    /// Cache a terminal session
    func setTerminalSession(_ terminalSession: TerminalSession, for sessionId: UUID) {
        activeTerminalSessions[sessionId] = terminalSession
    }

    /// Remove cached terminal session (on close)
    func removeTerminalSession(for sessionId: UUID) {
        activeTerminalSessions.removeValue(forKey: sessionId)
    }

    /// Check if a terminal session is active
    func hasActiveTerminalSession(for sessionId: UUID) -> Bool {
        return activeTerminalSessions[sessionId] != nil
    }

    // MARK: - Zellij Bridge Management

    /// Start a Zellij bridge for a session
    /// - Parameters:
    ///   - sessionId: The WilloSession ID
    ///   - transport: The SSH transport to use for the bridge channel
    ///   - zellijSessionName: The name of the Zellij session on the server
    func startBridge(
        for sessionId: UUID,
        transport: NIOSSHTransport,
        zellijSessionName: String
    ) async {
        // Don't start duplicate bridges
        guard zellijBridges[sessionId] == nil else {
            logger.debug("Bridge already exists for session \(sessionId, privacy: .public)")
            return
        }

        let bridge = ZellijBridge(sessionName: zellijSessionName)
        zellijBridges[sessionId] = bridge
        await bridge.start(transport: transport)

        // Update activeBridge if this is the active session
        if sessionId == activeSessionId {
            activeBridge = bridge
        }
    }

    /// Stop and remove the Zellij bridge for a session
    func stopBridge(for sessionId: UUID) {
        zellijBridges[sessionId]?.stop()
        zellijBridges.removeValue(forKey: sessionId)

        // Clear activeBridge if this was the active session
        if sessionId == activeSessionId {
            activeBridge = nil
        }
    }

    /// Get the Zellij bridge for a session
    func getBridge(for sessionId: UUID) -> ZellijBridge? {
        zellijBridges[sessionId]
    }

    /// Check if a session has an active bridge
    func hasActiveBridge(for sessionId: UUID) -> Bool {
        zellijBridges[sessionId]?.isConnected ?? false
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
        color: SessionColor = .cyan,
        layoutId: String? = nil
    ) -> WilloSession {
        let session = WilloSession(
            serverProfile: profile,
            name: name,
            description: description,
            color: color,
            deviceOrigin: .current,
            layoutId: layoutId
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

        // Update activeBridge for the new session
        activeBridge = sessionId.flatMap { zellijBridges[$0] }

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

    /// Update the server profile for a session (e.g., after toggling SSH/Mosh)
    func updateServerProfile(_ profile: ServerProfile, for sessionId: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].serverProfile = profile
        }
    }

    /// Close and remove a session
    func closeSession(_ sessionId: UUID) {
        // Stop Zellij bridge if active
        stopBridge(for: sessionId)

        // Disconnect terminal session if active
        if let terminalSession = activeTerminalSessions[sessionId] {
            Task {
                try? await sessionManager?.disconnect(terminalSession)
            }
            activeTerminalSessions.removeValue(forKey: sessionId)
        }

        // Clean up thumbnail
        #if os(iOS)
        thumbnailManager.unregisterTerminalView(for: sessionId)
        #endif

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
        color: SessionColor? = nil,
        layoutId: String?? = nil  // Double optional: nil = don't change, .some(nil) = clear, .some(value) = set
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
        if let layoutId = layoutId {
            sessions[index].layoutId = layoutId
        }

        saveSessions()
    }

    /// Set layout for a session
    func setLayout(_ sessionId: UUID, layoutId: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].layoutId = layoutId
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

    // MARK: - Cloud Sync Setup

    private func setupCloudSync() {
        // Listen for external changes from iCloud
        cloudSync.syncEvents
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .sessionsChanged:
                    self.mergeCloudSessions()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Perform initial merge with cloud data
        mergeCloudSessions()
    }

    private func mergeCloudSessions() {
        guard let cloudSessions = cloudSync.loadSessions() else {
            logger.debug("No cloud sessions to merge")
            return
        }

        logger.info("Merging \(cloudSessions.count) sessions from iCloud")

        // For each cloud session, check if we have it locally
        for cloudSession in cloudSessions {
            if let localIndex = sessions.firstIndex(where: { $0.id == cloudSession.id }) {
                // Session exists - merge by timestamp (cloud wins if newer)
                let localSession = sessions[localIndex]
                if cloudSession.lastActivityAt > localSession.lastActivityAt {
                    logger.debug("Updating session \(cloudSession.name, privacy: .public) from iCloud")
                    sessions[localIndex] = cloudSession.toWilloSession(
                        serverProfile: localSession.serverProfile,
                        connectionState: localSession.connectionState,
                        activityState: localSession.activityState
                    )
                }
            } else {
                // New session from cloud - will need profile resolution
                logger.info("New session from iCloud: \(cloudSession.name, privacy: .public) - needs profile resolution")
                // Store the cloud session temporarily and resolve after profiles load
                // For now, we'll skip adding it until profiles are resolved
            }
        }

        // Save merged sessions locally
        saveSessionsLocally()
    }

    // MARK: - Persistence

    private func loadSessions() {
        // Load session IDs and metadata from local storage
        guard let data = UserDefaults.standard.data(forKey: Self.sessionsKey) else {
            return
        }

        do {
            sessions = try JSONDecoder().decode([WilloSession].self, from: data)
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription, privacy: .public)")
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
        // Save to local storage
        saveSessionsLocally()

        // Sync to iCloud
        cloudSync.syncSessions(sessions)
    }

    private func saveSessionsLocally() {
        do {
            let data = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        } catch {
            logger.error("Failed to save sessions: \(error.localizedDescription, privacy: .public)")
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
                logger.debug("Resolved profile for session '\(session.name, privacy: .public)': \(matchingProfile.displayName, privacy: .public)")
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
                    lastActivityAt: session.lastActivityAt,
                    deviceOrigin: session.deviceOrigin,
                    layoutId: session.layoutId
                )
            } else if session.serverProfile.hostname.isEmpty {
                // Profile was deleted or not found - mark for removal
                logger.warning("Could not resolve profile for session '\(session.name, privacy: .public)' (ID: \(session.serverProfile.id, privacy: .public)) - marking for removal")
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
