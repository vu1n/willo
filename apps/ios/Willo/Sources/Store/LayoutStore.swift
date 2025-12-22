import Foundation
import SwiftUI
import Combine

/// Manages user-created layouts captured from zellij sessions
@MainActor
final class LayoutStore: ObservableObject {
    // MARK: - Published State

    /// All user-created layouts
    @Published private(set) var userLayouts: [UserLayout] = []

    // MARK: - Dependencies

    private let cloudSync = CloudSyncManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Persistence Keys

    private static let userLayoutsKey = "willoUserLayouts"

    // MARK: - Init

    init() {
        loadLayouts()
        setupCloudSync()
    }

    // MARK: - Layout Management

    /// Add a new user layout
    func addLayout(name: String, kdlContent: String) -> UserLayout {
        let layout = UserLayout(name: name, kdlContent: kdlContent)
        userLayouts.append(layout)
        saveLayouts()
        return layout
    }

    /// Delete a user layout
    func deleteLayout(_ layoutId: UUID) {
        userLayouts.removeAll { $0.id == layoutId }
        saveLayouts()
    }

    /// Rename a user layout
    func renameLayout(_ layoutId: UUID, newName: String) {
        guard let index = userLayouts.firstIndex(where: { $0.id == layoutId }) else { return }
        let oldLayout = userLayouts[index]
        userLayouts[index] = UserLayout(
            id: oldLayout.id,
            name: newName,
            kdlContent: oldLayout.kdlContent,
            createdAt: oldLayout.createdAt,
            deviceOrigin: oldLayout.deviceOrigin
        )
        saveLayouts()
    }

    /// Get a user layout by ID
    func getLayout(_ layoutId: UUID) -> UserLayout? {
        return userLayouts.first { $0.id == layoutId }
    }

    /// Get all layouts as LayoutTemplates (for picker)
    func getAllLayoutTemplates() -> [LayoutTemplate] {
        return userLayouts.map { $0.toLayoutTemplate() }
    }

    /// Get layouts suitable for current device
    func getLayoutsForCurrentDevice() -> [UserLayout] {
        let current = DeviceOrigin.current
        return userLayouts.filter { $0.deviceOrigin == current }
    }

    // MARK: - Cloud Sync Setup

    private func setupCloudSync() {
        // Listen for external changes from iCloud
        cloudSync.syncEvents
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .layoutsChanged:
                    self.mergeCloudLayouts()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Perform initial merge with cloud data
        mergeCloudLayouts()
    }

    private func mergeCloudLayouts() {
        guard let cloudLayouts = cloudSync.loadUserLayouts() else {
            print("[LayoutStore] No cloud layouts to merge")
            return
        }

        print("[LayoutStore] Merging \(cloudLayouts.count) layouts from iCloud")
        userLayouts = cloudSync.mergeUserLayouts(local: userLayouts, cloud: cloudLayouts)

        // Save merged layouts locally
        saveLayoutsLocally()
    }

    // MARK: - Persistence

    private func loadLayouts() {
        guard let data = UserDefaults.standard.data(forKey: Self.userLayoutsKey) else {
            return
        }

        do {
            userLayouts = try JSONDecoder().decode([UserLayout].self, from: data)
            print("[LayoutStore] Loaded \(userLayouts.count) user layouts")
        } catch {
            print("[LayoutStore] Failed to load user layouts: \(error)")
        }
    }

    private func saveLayouts() {
        // Save to local storage
        saveLayoutsLocally()

        // Sync to iCloud
        cloudSync.syncUserLayouts(userLayouts)
    }

    private func saveLayoutsLocally() {
        do {
            let data = try JSONEncoder().encode(userLayouts)
            UserDefaults.standard.set(data, forKey: Self.userLayoutsKey)
            print("[LayoutStore] Saved \(userLayouts.count) user layouts")
        } catch {
            print("[LayoutStore] Failed to save user layouts: \(error)")
        }
    }
}
