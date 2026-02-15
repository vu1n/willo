import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.willo.app", category: "CloudSync")

/// Manages iCloud synchronization using NSUbiquitousKeyValueStore
///
/// CloudSyncManager provides a simple key-value sync mechanism for:
/// - WilloSession metadata (session definitions, not terminal state)
/// - ServerProfile definitions (excluding passwords - those stay in Keychain)
/// - Custom layout templates (when implemented)
///
/// NSUbiquitousKeyValueStore has a 1MB total limit, which is sufficient for metadata.
/// Data syncs automatically across devices signed into the same iCloud account.
@MainActor
final class CloudSyncManager: ObservableObject {
    // MARK: - Singleton

    static let shared = CloudSyncManager()

    // MARK: - Cloud Store

    private let cloudStore = NSUbiquitousKeyValueStore.default

    // MARK: - Keys

    private enum CloudKey: String {
        case sessions = "willo.sessions.v1"
        case serverProfiles = "willo.profiles.v1"
        case layouts = "willo.layouts.v1"
        case lastSyncTimestamp = "willo.lastSync"
    }

    /// NSUbiquitousKeyValueStore total limit is 1MB; individual values max ~256KB
    private let iCloudMaxValueSize = 256 * 1024  // 256 KB per value

    // MARK: - State

    /// Whether iCloud sync is available
    @Published private(set) var isAvailable: Bool = false

    /// Last sync timestamp
    @Published private(set) var lastSyncDate: Date?

    /// Sync state for UI feedback
    @Published private(set) var syncState: SyncState = .idle

    /// Subject to publish sync events
    let syncEvents = PassthroughSubject<SyncEvent, Never>()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        setupCloudSync()
    }

    // MARK: - Setup

    private func setupCloudSync() {
        // Check if iCloud is available
        isAvailable = FileManager.default.ubiquityIdentityToken != nil

        if !isAvailable {
            logger.info("iCloud not available - user may not be signed in")
            return
        }

        logger.info("iCloud available - setting up sync")

        // Listen for external changes from other devices
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            self?.handleExternalChange(notification)
        }

        // Synchronize on startup to get latest data
        cloudStore.synchronize()

        // Load last sync timestamp
        if let timestamp = cloudStore.object(forKey: CloudKey.lastSyncTimestamp.rawValue) as? TimeInterval {
            lastSyncDate = Date(timeIntervalSince1970: timestamp)
        }
    }

    // MARK: - External Change Handling

    private func handleExternalChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }

        logger.info("External change detected - reason: \(changeReason), keys: \(changedKeys, privacy: .public)")

        // changeReason: 0 = server change, 1 = initial sync, 2 = quota violation, 3 = account change
        switch changeReason {
        case NSUbiquitousKeyValueStoreServerChange:
            handleServerChange(changedKeys)
        case NSUbiquitousKeyValueStoreInitialSyncChange:
            handleInitialSync(changedKeys)
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            logger.warning("iCloud quota exceeded!")
            syncState = .error("iCloud storage quota exceeded")
        case NSUbiquitousKeyValueStoreAccountChange:
            logger.warning("iCloud account changed")
            syncState = .error("iCloud account changed")
        default:
            break
        }

        updateLastSyncDate()
    }

    private func handleServerChange(_ changedKeys: [String]) {
        syncState = .syncing

        for key in changedKeys {
            if key == CloudKey.sessions.rawValue {
                syncEvents.send(.sessionsChanged)
            } else if key == CloudKey.serverProfiles.rawValue {
                syncEvents.send(.profilesChanged)
            } else if key == CloudKey.layouts.rawValue {
                syncEvents.send(.layoutsChanged)
            }
        }

        syncState = .idle
    }

    private func handleInitialSync(_ changedKeys: [String]) {
        logger.info("Initial sync completed for keys: \(changedKeys, privacy: .public)")
        handleServerChange(changedKeys) // Same handling as server change
    }

    private func updateLastSyncDate() {
        lastSyncDate = Date()
        cloudStore.set(lastSyncDate!.timeIntervalSince1970, forKey: CloudKey.lastSyncTimestamp.rawValue)
    }

    // MARK: - Sessions Sync

    /// Sync session definitions to iCloud
    func syncSessions(_ sessions: [WilloSession]) {
        guard isAvailable else { return }

        do {
            // Convert sessions to syncable format (exclude runtime state)
            let syncableSessions = sessions.map { session in
                SyncableSession(
                    id: session.id,
                    serverProfileId: session.serverProfile.id,
                    name: session.name,
                    description: session.description,
                    color: session.color,
                    createdAt: session.createdAt,
                    lastActivityAt: session.lastActivityAt,
                    deviceOrigin: session.deviceOrigin,
                    layoutId: session.layoutId
                )
            }

            let data = try JSONEncoder().encode(syncableSessions)
            guard data.count < iCloudMaxValueSize else {
                logger.warning("Sessions data too large for iCloud (\(data.count) bytes)")
                syncState = .error("Sessions data exceeds iCloud size limit")
                return
            }
            cloudStore.set(data, forKey: CloudKey.sessions.rawValue)
            cloudStore.synchronize()

            updateLastSyncDate()
            logger.info("Synced \(sessions.count) sessions to iCloud")
        } catch {
            logger.error("Failed to sync sessions: \(error.localizedDescription, privacy: .public)")
            syncState = .error("Failed to sync sessions")
        }
    }

    /// Load sessions from iCloud and merge with local sessions
    func loadSessions() -> [SyncableSession]? {
        guard isAvailable else { return nil }

        guard let data = cloudStore.data(forKey: CloudKey.sessions.rawValue) else {
            logger.debug("No sessions in iCloud")
            return nil
        }

        do {
            let sessions = try JSONDecoder().decode([SyncableSession].self, from: data)
            logger.info("Loaded \(sessions.count) sessions from iCloud")
            return sessions
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Merge iCloud sessions with local sessions (last-write-wins by timestamp)
    func mergeSessions(local: [WilloSession], cloud: [SyncableSession]) -> [WilloSession] {
        var merged = local
        let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

        for cloudSession in cloud {
            if let localSession = localById[cloudSession.id] {
                // Session exists locally - use the one with latest activity
                if cloudSession.lastActivityAt > localSession.lastActivityAt {
                    // Cloud version is newer - update local
                    logger.debug("Updating session \(cloudSession.name, privacy: .public) from iCloud (newer)")
                    if let index = merged.firstIndex(where: { $0.id == cloudSession.id }) {
                        merged[index] = cloudSession.toWilloSession(
                            serverProfile: localSession.serverProfile,
                            connectionState: localSession.connectionState,
                            activityState: localSession.activityState
                        )
                    }
                }
            } else {
                // Session only exists in cloud - add it (will need profile resolution)
                logger.info("Adding new session from iCloud: \(cloudSession.name, privacy: .public)")
                // We can't add it directly without a resolved ServerProfile
                // Mark for resolution in SessionStore
            }
        }

        return merged
    }

    // MARK: - Server Profiles Sync

    /// Sync server profiles to iCloud (excluding sensitive data)
    func syncServerProfiles(_ profiles: [ServerProfile]) {
        guard isAvailable else { return }

        do {
            // Convert profiles to syncable format (exclude passwords)
            let syncableProfiles = profiles.map { profile in
                SyncableServerProfile(
                    id: profile.id,
                    displayName: profile.displayName,
                    hostname: profile.hostname,
                    port: profile.port,
                    username: profile.username,
                    authMethod: profile.authMethod.sanitized, // Remove password
                    multiplexer: profile.multiplexer,
                    startupBehavior: profile.startupBehavior,
                    sessionTemplate: profile.sessionTemplate,
                    preferMosh: profile.preferMosh,
                    lastConnected: profile.lastConnected
                )
            }

            let data = try JSONEncoder().encode(syncableProfiles)
            guard data.count < iCloudMaxValueSize else {
                logger.warning("Profiles data too large for iCloud (\(data.count) bytes)")
                syncState = .error("Profiles data exceeds iCloud size limit")
                return
            }
            cloudStore.set(data, forKey: CloudKey.serverProfiles.rawValue)
            cloudStore.synchronize()

            updateLastSyncDate()
            logger.info("Synced \(profiles.count) profiles to iCloud")
        } catch {
            logger.error("Failed to sync profiles: \(error.localizedDescription, privacy: .public)")
            syncState = .error("Failed to sync profiles")
        }
    }

    /// Load server profiles from iCloud
    func loadServerProfiles() -> [SyncableServerProfile]? {
        guard isAvailable else { return nil }

        guard let data = cloudStore.data(forKey: CloudKey.serverProfiles.rawValue) else {
            logger.debug("No profiles in iCloud")
            return nil
        }

        do {
            let profiles = try JSONDecoder().decode([SyncableServerProfile].self, from: data)
            logger.info("Loaded \(profiles.count) profiles from iCloud")
            return profiles
        } catch {
            logger.error("Failed to load profiles: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Load server profiles from iCloud, forcing a sync first
    /// This is the preferred method for initial app load to ensure we get the latest data
    func loadServerProfilesWithSync() -> [SyncableServerProfile]? {
        guard isAvailable else {
            logger.debug("iCloud not available for profile sync")
            return nil
        }

        // Force synchronize to pull latest data from iCloud
        // This is important on fresh installs where local cache is empty
        cloudStore.synchronize()

        return loadServerProfiles()
    }

    /// Merge iCloud profiles with local profiles (last-write-wins by timestamp)
    func mergeServerProfiles(local: [ServerProfile], cloud: [SyncableServerProfile]) -> [ServerProfile] {
        var merged = local
        let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

        for cloudProfile in cloud {
            if let localProfile = localById[cloudProfile.id] {
                // Profile exists locally - use the one with latest connection
                let cloudLastConnected = cloudProfile.lastConnected ?? Date.distantPast
                let localLastConnected = localProfile.lastConnected ?? Date.distantPast

                if cloudLastConnected > localLastConnected {
                    // Cloud version is newer - update local (preserve local auth)
                    logger.debug("Updating profile \(cloudProfile.displayName, privacy: .public) from iCloud (newer)")
                    if let index = merged.firstIndex(where: { $0.id == cloudProfile.id }) {
                        merged[index] = cloudProfile.toServerProfile(preservingAuthFrom: localProfile)
                    }
                }
            } else {
                // Profile only exists in cloud - add it
                logger.info("Adding new profile from iCloud: \(cloudProfile.displayName, privacy: .public)")
                merged.append(cloudProfile.toServerProfile(preservingAuthFrom: nil))
            }
        }

        return merged
    }

    // MARK: - User Layouts Sync

    /// Sync user layouts to iCloud
    func syncUserLayouts(_ layouts: [UserLayout]) {
        guard isAvailable else { return }

        do {
            let data = try JSONEncoder().encode(layouts)
            guard data.count < iCloudMaxValueSize else {
                logger.warning("Layouts data too large for iCloud (\(data.count) bytes)")
                syncState = .error("Layouts data exceeds iCloud size limit")
                return
            }
            cloudStore.set(data, forKey: CloudKey.layouts.rawValue)
            cloudStore.synchronize()

            updateLastSyncDate()
            logger.info("Synced \(layouts.count) user layouts to iCloud")
        } catch {
            logger.error("Failed to sync layouts: \(error.localizedDescription, privacy: .public)")
            syncState = .error("Failed to sync layouts")
        }
    }

    /// Load user layouts from iCloud
    func loadUserLayouts() -> [UserLayout]? {
        guard isAvailable else { return nil }

        guard let data = cloudStore.data(forKey: CloudKey.layouts.rawValue) else {
            logger.debug("No layouts in iCloud")
            return nil
        }

        do {
            let layouts = try JSONDecoder().decode([UserLayout].self, from: data)
            logger.info("Loaded \(layouts.count) layouts from iCloud")
            return layouts
        } catch {
            logger.error("Failed to load layouts: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Merge iCloud layouts with local layouts (last-write-wins by createdAt)
    func mergeUserLayouts(local: [UserLayout], cloud: [UserLayout]) -> [UserLayout] {
        var merged = local
        let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

        for cloudLayout in cloud {
            if let localLayout = localById[cloudLayout.id] {
                // Layout exists locally - use the one created most recently
                if cloudLayout.createdAt > localLayout.createdAt {
                    // Cloud version is newer - update local
                    logger.debug("Updating layout \(cloudLayout.name, privacy: .public) from iCloud (newer)")
                    if let index = merged.firstIndex(where: { $0.id == cloudLayout.id }) {
                        merged[index] = cloudLayout
                    }
                }
            } else {
                // Layout only exists in cloud - add it
                logger.info("Adding new layout from iCloud: \(cloudLayout.name, privacy: .public)")
                merged.append(cloudLayout)
            }
        }

        return merged
    }

    // MARK: - Manual Sync

    /// Force synchronization with iCloud
    func forceSynchronize() {
        guard isAvailable else { return }

        syncState = .syncing
        cloudStore.synchronize()

        // Give it a moment to sync
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.syncState = .idle
        }
    }
}

// MARK: - Sync State

enum SyncState: Equatable {
    case idle
    case syncing
    case error(String)
}

// MARK: - Sync Events

enum SyncEvent {
    case sessionsChanged
    case profilesChanged
    case layoutsChanged
}

// MARK: - Syncable Models

/// Syncable version of WilloSession (excludes runtime state)
struct SyncableSession: Codable, Identifiable {
    let id: UUID
    let serverProfileId: UUID
    var name: String
    var description: String
    var color: SessionColor
    var createdAt: Date
    var lastActivityAt: Date
    var deviceOrigin: DeviceOrigin
    var layoutId: String?

    func toWilloSession(
        serverProfile: ServerProfile,
        connectionState: ConnectionState,
        activityState: ActivityState
    ) -> WilloSession {
        WilloSession(
            id: id,
            serverProfile: serverProfile,
            name: name,
            description: description,
            color: color,
            connectionState: connectionState,
            activityState: activityState,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            deviceOrigin: deviceOrigin,
            layoutId: layoutId
        )
    }
}

/// Syncable version of ServerProfile (excludes passwords)
struct SyncableServerProfile: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var multiplexer: MultiplexerPreference
    var startupBehavior: StartupBehavior
    var sessionTemplate: String
    var preferMosh: Bool
    var lastConnected: Date?

    func toServerProfile(preservingAuthFrom localProfile: ServerProfile?) -> ServerProfile {
        ServerProfile(
            id: id,
            displayName: displayName,
            hostname: hostname,
            port: port,
            username: username,
            authMethod: localProfile?.authMethod ?? authMethod, // Preserve local auth if exists
            multiplexer: multiplexer,
            startupBehavior: startupBehavior,
            sessionTemplate: sessionTemplate,
            preferMosh: preferMosh,
            lastConnected: lastConnected
        )
    }
}

// MARK: - AuthMethod Sanitization

extension AuthMethod {
    /// Returns a version safe for cloud sync (removes passwords)
    var sanitized: AuthMethod {
        switch self {
        case .password:
            // Don't sync passwords - default to key auth
            return .key(keyId: nil)
        case .key, .agent:
            return self
        }
    }
}
