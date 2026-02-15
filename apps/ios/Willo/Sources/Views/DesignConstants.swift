import Foundation
import CoreGraphics

/// Centralized design constants for the Willo app.
/// Replaces magic numbers scattered throughout views.
enum DesignConstants {
    /// Status bar
    static let statusBarHeight: CGFloat = 56
    static let statusBarPadding: CGFloat = 60

    /// Swipe and gesture thresholds
    static let swipeThreshold: CGFloat = 60

    /// Terminal
    static let minFontSize: CGFloat = 14.0
    static let maxFontSize: CGFloat = 32.0
    static let defaultFontSize: CGFloat = 24.0

    /// Grid limits (prevents buffer overflow on resize)
    static let maxGridRows: Int = 500
    static let maxGridCols: Int = 500

    /// Timing (nanoseconds)
    static let shellInitDelay: UInt64 = 300_000_000       // 300ms
    static let resizeDebounceDelay: UInt64 = 200_000_000   // 200ms
    static let syncFallbackDelay: TimeInterval = 0.016     // ~1 frame at 60fps

    /// Mosh
    static let moshConnectionTimeout: UInt64 = 3_000_000_000  // 3s for UDP handshake

    /// Reconnection
    static let maxReconnectAttempts: Int = 5

    /// Animation
    static let defaultCornerRadius: CGFloat = 8
    static let cardThumbnailHeight: CGFloat = 100
}
