import Foundation
import SwiftUI
import Combine

/// Manages thumbnail capture and storage for terminal sessions
///
/// ThumbnailManager is responsible for:
/// - Periodically capturing terminal screenshots
/// - Storing thumbnails keyed by session ID
/// - Managing memory by limiting cache size
/// - Providing thumbnails to the UI layer
@MainActor
final class ThumbnailManager: ObservableObject {
    // MARK: - Published State

    /// Thumbnails indexed by session ID
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]

    // MARK: - Configuration

    /// Capture interval in seconds (default: 3 seconds)
    private let captureInterval: TimeInterval = 3.0

    /// Maximum number of thumbnails to keep in memory
    private let maxThumbnails = 20

    // MARK: - State

    /// Timer for periodic captures
    private var captureTimer: Timer?

    /// Weak references to terminal views we're capturing from
    private var terminalViewRefs: [UUID: WeakTerminalRef] = [:]

    /// Last capture times for throttling
    private var lastCaptureTimes: [UUID: Date] = [:]

    // MARK: - Weak Reference Wrapper

    private class WeakTerminalRef {
        weak var view: WilloTerminalView?
        init(_ view: WilloTerminalView) {
            self.view = view
        }
    }

    // MARK: - Lifecycle

    init() {
        startCaptureTimer()
    }

    nonisolated deinit {
        // Timer cleanup handled by ARC - timer holds weak self
    }

    // MARK: - Public API

    /// Register a terminal view for thumbnail capture
    func registerTerminalView(_ view: WilloTerminalView, for sessionId: UUID) {
        terminalViewRefs[sessionId] = WeakTerminalRef(view)
        print("[ThumbnailManager] Registered terminal view for session \(sessionId)")

        // Capture initial thumbnail immediately
        captureSnapshot(for: sessionId)
    }

    /// Unregister a terminal view (when session is closed)
    func unregisterTerminalView(for sessionId: UUID) {
        terminalViewRefs.removeValue(forKey: sessionId)
        thumbnails.removeValue(forKey: sessionId)
        lastCaptureTimes.removeValue(forKey: sessionId)
        print("[ThumbnailManager] Unregistered terminal view for session \(sessionId)")
    }

    /// Get thumbnail for a session
    func getThumbnail(for sessionId: UUID) -> UIImage? {
        return thumbnails[sessionId]
    }

    /// Manually trigger a thumbnail capture for a session
    func captureSnapshot(for sessionId: UUID) {
        guard let terminalRef = terminalViewRefs[sessionId],
              let terminalView = terminalRef.view else {
            return
        }

        // Capture the snapshot
        if let snapshot = terminalView.captureSnapshot() {
            thumbnails[sessionId] = snapshot
            lastCaptureTimes[sessionId] = Date()
            print("[ThumbnailManager] Captured thumbnail for session \(sessionId)")

            // Enforce memory limit
            enforceMemoryLimit()
        }
    }

    /// Clear all thumbnails
    func clearAll() {
        thumbnails.removeAll()
        lastCaptureTimes.removeAll()
    }

    // MARK: - Timer Management

    private func startCaptureTimer() {
        captureTimer = Timer.scheduledTimer(
            withTimeInterval: captureInterval,
            repeats: true
        ) { [weak self] _ in
            self?.captureAllSnapshots()
        }
    }

    private func stopCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    // MARK: - Capture Logic

    private func captureAllSnapshots() {
        let now = Date()

        // Capture snapshots for all registered terminal views
        for (sessionId, terminalRef) in terminalViewRefs {
            // Check if enough time has passed since last capture
            if let lastCapture = lastCaptureTimes[sessionId],
               now.timeIntervalSince(lastCapture) < captureInterval {
                continue
            }

            // Check if view is still valid
            guard let terminalView = terminalRef.view else {
                // Clean up stale reference
                terminalViewRefs.removeValue(forKey: sessionId)
                continue
            }

            // Capture the snapshot
            if let snapshot = terminalView.captureSnapshot() {
                thumbnails[sessionId] = snapshot
                lastCaptureTimes[sessionId] = now
            }
        }

        // Enforce memory limit after batch capture
        enforceMemoryLimit()
    }

    private func enforceMemoryLimit() {
        // If we exceed the max thumbnails, remove oldest ones
        if thumbnails.count > maxThumbnails {
            // Sort by last capture time
            let sortedByTime = lastCaptureTimes.sorted { $0.value < $1.value }
            let toRemove = sortedByTime.prefix(thumbnails.count - maxThumbnails)

            for (sessionId, _) in toRemove {
                thumbnails.removeValue(forKey: sessionId)
                lastCaptureTimes.removeValue(forKey: sessionId)
                print("[ThumbnailManager] Removed old thumbnail for session \(sessionId) (memory limit)")
            }
        }
    }
}
