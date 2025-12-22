import SwiftUI
import Combine

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
        loadServerProfiles()

        // Set up observation for saving after init completes
        setupAutoSave()

        // Set up cloud sync
        setupCloudSync()
    }

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    // MARK: - Cloud Sync Setup

    private func setupCloudSync() {
        // Listen for external changes from iCloud
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

        // Perform initial merge with cloud data
        mergeCloudProfiles()
    }

    private func mergeCloudProfiles() {
        guard let cloudProfiles = cloudSync.loadServerProfiles() else {
            print("[AppState] No cloud profiles to merge")
            return
        }

        print("[AppState] Merging \(cloudProfiles.count) profiles from iCloud")

        // For each cloud profile, check if we have it locally
        for cloudProfile in cloudProfiles {
            if let localIndex = serverProfiles.firstIndex(where: { $0.id == cloudProfile.id }) {
                // Profile exists - merge by timestamp (cloud wins if newer)
                let localProfile = serverProfiles[localIndex]
                let cloudLastConnected = cloudProfile.lastConnected ?? Date.distantPast
                let localLastConnected = localProfile.lastConnected ?? Date.distantPast

                if cloudLastConnected > localLastConnected {
                    print("[AppState] Updating profile \(cloudProfile.displayName) from iCloud")
                    // Preserve local auth method (passwords stay local)
                    serverProfiles[localIndex] = cloudProfile.toServerProfile(preservingAuthFrom: localProfile)
                }
            } else {
                // New profile from cloud
                print("[AppState] Adding new profile from iCloud: \(cloudProfile.displayName)")
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

        guard let data = UserDefaults.standard.data(forKey: Self.serverProfilesKey) else {
            return
        }
        do {
            serverProfiles = try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            print("[AppState] Failed to load server profiles: \(error)")
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
            print("[AppState] Failed to save server profiles: \(error)")
        }
    }
}
