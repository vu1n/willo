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

    init() {
        loadServerProfiles()

        // Set up observation for saving after init completes
        setupAutoSave()
    }

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
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
            print("Failed to load server profiles: \(error)")
        }
    }

    private func saveServerProfiles() {
        guard !isLoading else { return }

        do {
            let data = try JSONEncoder().encode(serverProfiles)
            UserDefaults.standard.set(data, forKey: Self.serverProfilesKey)
        } catch {
            print("Failed to save server profiles: \(error)")
        }
    }
}
