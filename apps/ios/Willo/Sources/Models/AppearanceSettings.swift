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

    enum FontFamily: String, CaseIterable {
        case iosevkaTerm = "IosevkaTerm"
        case jetBrainsMono = "JetBrainsMono"
        case sfMono = "SFMono"
        case menlo = "Menlo"

        var displayName: String {
            switch self {
            case .iosevkaTerm: return "Iosevka Term"
            case .jetBrainsMono: return "JetBrains Mono"
            case .sfMono: return "SF Mono"
            case .menlo: return "Menlo"
            }
        }

        /// PostScript name for the regular weight
        var fontName: String {
            switch self {
            case .iosevkaTerm: return "IosevkaTermNF"
            case .jetBrainsMono: return "JetBrainsMonoNerdFont-Regular"
            case .sfMono: return "SFMono-Regular"
            case .menlo: return "Menlo-Regular"
            }
        }

        var boldFontName: String {
            switch self {
            case .iosevkaTerm: return "IosevkaTermNF-Bold"
            case .jetBrainsMono: return "JetBrainsMonoNerdFont-Bold"
            case .sfMono: return "SFMono-Bold"
            case .menlo: return "Menlo-Bold"
            }
        }

        var description: String {
            switch self {
            case .iosevkaTerm: return "Nerd Font, clean & narrow"
            case .jetBrainsMono: return "Nerd Font with icons"
            case .sfMono: return "Apple's monospace font"
            case .menlo: return "Classic terminal font"
            }
        }
    }

    /// Stored appearance mode - using explicit UserDefaults for reliability
    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
        }
    }

    /// Terminal font family
    @Published var fontFamily: FontFamily {
        didSet {
            UserDefaults.standard.set(fontFamily.rawValue, forKey: "terminalFontFamily")
            // Also store the PostScript name for GlyphAtlas to read directly
            UserDefaults.standard.set(fontFamily.fontName, forKey: "terminalFontName")
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

        // Load saved font family or default to Iosevka Term
        if let savedFamily = UserDefaults.standard.string(forKey: "terminalFontFamily"),
           let family = FontFamily(rawValue: savedFamily) {
            self.fontFamily = family
        } else {
            self.fontFamily = .iosevkaTerm
        }

        // Ensure the PostScript font name is always written
        UserDefaults.standard.set(fontFamily.fontName, forKey: "terminalFontName")

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
