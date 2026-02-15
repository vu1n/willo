import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.willo.app", category: "AppState")

/// Shared app services container - singleton to avoid StateObject recreation issues
@MainActor
final class AppServices: ObservableObject {
    /// Shared singleton instance
    static let shared = AppServices()

    let appState = AppState()
    let appearanceSettings = AppearanceSettings()
    let sessionManager: SessionManager
    let sessionStore: SessionStore
    let layoutStore = LayoutStore()

    private init() {
        let appManager = GhosttyAppManager()
        self.sessionManager = SessionManager(appManager: appManager)
        self.sessionStore = SessionStore(sessionManager: sessionManager)

        // Resolve server profiles for any persisted sessions
        sessionStore.resolveServerProfiles(from: appState.serverProfiles)
    }
}

public struct WilloApp: App {
    public init() {
        // Register custom terminal fonts
        FontManager.shared.registerBundledFonts()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppServices.shared.appState)
                .environmentObject(AppServices.shared.appearanceSettings)
                .environmentObject(AppServices.shared.sessionManager)
                .environmentObject(AppServices.shared.sessionStore)
                .environmentObject(AppServices.shared.layoutStore)
        }
    }
}

/// Root view that handles color scheme based on appearance settings
private struct RootView: View {
    @EnvironmentObject var appearanceSettings: AppearanceSettings

    var body: some View {
        ContentView()
            .preferredColorScheme(appearanceSettings.mode.colorScheme)
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var activeWorkspaceId: UUID?
    @Published var serverProfiles: [ServerProfile] = []

    private static let serverProfilesKey = "serverProfiles"
    private var isLoading = false
    private let cloudSync = CloudSyncManager.shared

    init() {
        // Load from iCloud first (primary source), fall back to UserDefaults
        loadServerProfiles()

        // Set up observation for saving after init completes
        setupAutoSave()

        // Set up cloud sync for external changes
        setupCloudSync()
    }

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    // MARK: - Cloud Sync Setup

    private func setupCloudSync() {
        // Listen for external changes from iCloud (other devices)
        cloudSync.syncEvents
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .profilesChanged:
                    self.mergeCloudProfiles()
                default:
                    break
                }
            }
            .store(in: &cancellables)
        // Note: Initial load from iCloud happens in loadServerProfiles()
    }

    private func mergeCloudProfiles() {
        guard let cloudProfiles = cloudSync.loadServerProfiles() else {
            logger.debug("No cloud profiles to merge")
            return
        }

        logger.info("Merging \(cloudProfiles.count) profiles from iCloud")

        // For each cloud profile, check if we have it locally
        for cloudProfile in cloudProfiles {
            if let localIndex = serverProfiles.firstIndex(where: { $0.id == cloudProfile.id }) {
                // Profile exists - merge by timestamp (cloud wins if newer)
                let localProfile = serverProfiles[localIndex]
                let cloudLastConnected = cloudProfile.lastConnected ?? Date.distantPast
                let localLastConnected = localProfile.lastConnected ?? Date.distantPast

                if cloudLastConnected > localLastConnected {
                    logger.debug("Updating profile \(cloudProfile.displayName, privacy: .public) from iCloud")
                    // Preserve local auth method (passwords stay local)
                    serverProfiles[localIndex] = cloudProfile.toServerProfile(preservingAuthFrom: localProfile)
                }
            } else {
                // New profile from cloud
                logger.info("Adding new profile from iCloud: \(cloudProfile.displayName, privacy: .public)")
                serverProfiles.append(cloudProfile.toServerProfile(preservingAuthFrom: nil))
            }
        }

        // Save merged profiles locally (without triggering cloud sync)
        saveServerProfilesLocally()
    }

    // MARK: - Persistence

    private func setupAutoSave() {
        // Use Combine to observe changes and save
        $serverProfiles
            .dropFirst() // Skip the initial value
            .sink { [weak self] _ in
                self?.saveServerProfiles()
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func loadServerProfiles() {
        isLoading = true
        defer { isLoading = false }

        // Try iCloud first (primary source) - this survives app reinstalls
        if let cloudProfiles = cloudSync.loadServerProfilesWithSync(), !cloudProfiles.isEmpty {
            logger.info("Loaded \(cloudProfiles.count) profiles from iCloud")
            serverProfiles = cloudProfiles.map { $0.toServerProfile(preservingAuthFrom: nil) }

            // Also restore any local auth data from UserDefaults cache
            if let localData = UserDefaults.standard.data(forKey: Self.serverProfilesKey),
               let localProfiles = try? JSONDecoder().decode([ServerProfile].self, from: localData) {
                let localById = Dictionary(uniqueKeysWithValues: localProfiles.map { ($0.id, $0) })
                for i in serverProfiles.indices {
                    if let localProfile = localById[serverProfiles[i].id] {
                        // Preserve local auth method (passwords don't sync to iCloud)
                        serverProfiles[i] = SyncableServerProfile(
                            id: serverProfiles[i].id,
                            displayName: serverProfiles[i].displayName,
                            hostname: serverProfiles[i].hostname,
                            port: serverProfiles[i].port,
                            username: serverProfiles[i].username,
                            authMethod: serverProfiles[i].authMethod,
                            multiplexer: serverProfiles[i].multiplexer,
                            startupBehavior: serverProfiles[i].startupBehavior,
                            sessionTemplate: serverProfiles[i].sessionTemplate,
                            preferMosh: serverProfiles[i].preferMosh,
                            lastConnected: serverProfiles[i].lastConnected
                        ).toServerProfile(preservingAuthFrom: localProfile)
                    }
                }
            }
            return
        }

        // Fall back to UserDefaults (local cache / offline mode)
        guard let data = UserDefaults.standard.data(forKey: Self.serverProfilesKey) else {
            logger.debug("No profiles in iCloud or UserDefaults")
            return
        }
        do {
            serverProfiles = try JSONDecoder().decode([ServerProfile].self, from: data)
            logger.info("Loaded \(self.serverProfiles.count) profiles from UserDefaults (iCloud unavailable)")
        } catch {
            logger.error("Failed to load server profiles: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveServerProfiles() {
        guard !isLoading else { return }

        // Save locally
        saveServerProfilesLocally()

        // Sync to iCloud
        cloudSync.syncServerProfiles(serverProfiles)
    }

    private func saveServerProfilesLocally() {
        do {
            let data = try JSONEncoder().encode(serverProfiles)
            UserDefaults.standard.set(data, forKey: Self.serverProfilesKey)
        } catch {
            logger.error("Failed to save server profiles: \(error.localizedDescription, privacy: .public)")
        }
    }
}
