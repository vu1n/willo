import SwiftUI

/// User appearance preferences
/// Persisted via AppStorage for automatic system integration
@MainActor
final class AppearanceSettings: ObservableObject {
    enum AppearanceMode: String, CaseIterable {
        case system = "system"
        case light = "light"
        case dark = "dark"

        var displayName: String {
            switch self {
            case .system: return "Auto"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var icon: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// Stored appearance mode - using explicit UserDefaults for reliability
    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
        }
    }

    /// Terminal font size (14-32pt range)
    @Published var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "terminalFontSize")
        }
    }

    /// Default font size
    static let defaultFontSize: CGFloat = 24.0
    static let minFontSize: CGFloat = 14.0
    static let maxFontSize: CGFloat = 32.0

    init() {
        // Load saved mode or default to system
        if let savedValue = UserDefaults.standard.string(forKey: "appearanceMode"),
           let savedMode = AppearanceMode(rawValue: savedValue) {
            self.mode = savedMode
        } else {
            self.mode = .system
        }

        // Load saved font size or default
        let savedFontSize = UserDefaults.standard.double(forKey: "terminalFontSize")
        if savedFontSize >= Self.minFontSize && savedFontSize <= Self.maxFontSize {
            self.fontSize = savedFontSize
        } else {
            self.fontSize = Self.defaultFontSize
        }
    }

    /// The resolved color scheme based on user preference and system
    func resolvedColorScheme(systemScheme: ColorScheme) -> ColorScheme {
        mode.colorScheme ?? systemScheme
    }
}
