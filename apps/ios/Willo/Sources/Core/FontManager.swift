import Foundation
import CoreText
import CoreGraphics

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Manages custom font registration for the terminal
final class FontManager {
    static let shared = FontManager()

    /// Font family info
    struct FontFamily {
        let name: String
        let regular: String
        let bold: String
        let italic: String
        let boldItalic: String
    }

    /// Available terminal fonts
    static let jetBrainsMono = FontFamily(
        name: "JetBrainsMono Nerd Font",
        regular: "JetBrainsMonoNerdFont-Regular",
        bold: "JetBrainsMonoNerdFont-Bold",
        italic: "JetBrainsMonoNerdFont-Italic",
        boldItalic: "JetBrainsMonoNerdFont-BoldItalic"
    )

    private var registeredFonts: Set<String> = []
    private let queue = DispatchQueue(label: "com.willo.fontmanager")

    private init() {}

    /// Register all bundled fonts
    /// Call this once at app startup
    func registerBundledFonts() {
        queue.async { [weak self] in
            self?.registerFontsInBundle()
        }
    }

    /// Check if a font is available
    func isFontAvailable(_ fontName: String) -> Bool {
        #if os(iOS)
        return UIFont(name: fontName, size: 12) != nil
        #else
        return NSFont(name: fontName, size: 12) != nil
        #endif
    }

    /// Iosevka Nerd Font Mono info
    static let iosevkaMono = FontFamily(
        name: "Iosevka Nerd Font Mono",
        regular: "IosevkaNerdFontMono-Regular",
        bold: "IosevkaNerdFontMono-Bold",
        italic: "IosevkaNerdFontMono-Italic",
        boldItalic: "IosevkaNerdFontMono-BoldItalic"
    )

    /// Get the best available terminal font
    func terminalFontName() -> String {
        // Prefer Iosevka if available
        if isFontAvailable(Self.iosevkaMono.regular) {
            return Self.iosevkaMono.regular
        }

        // Then JetBrains Mono
        if isFontAvailable(Self.jetBrainsMono.regular) {
            return Self.jetBrainsMono.regular
        }

        // Fall back to SF Mono (always available on Apple platforms)
        return "SFMono-Regular"
    }

    // MARK: - Private

    private func registerFontsInBundle() {
        // Find fonts in the bundle resources
        // Bundle.module is synthesized by SPM for packages with resources
        let bundle = Bundle(for: BundleToken.self)
        guard let fontsURL = bundle.url(forResource: "Fonts", withExtension: nil)
                ?? Bundle.main.url(forResource: "Fonts", withExtension: nil) else {
            print("[FontManager] Fonts directory not found in bundle")
            return
        }

        do {
            let fontFiles = try FileManager.default.contentsOfDirectory(
                at: fontsURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )

            for fontURL in fontFiles where fontURL.pathExtension == "ttf" || fontURL.pathExtension == "otf" {
                registerFont(at: fontURL)
            }

            print("[FontManager] Registered \(registeredFonts.count) fonts")
        } catch {
            print("[FontManager] Error reading fonts directory: \(error)")
        }
    }

    private func registerFont(at url: URL) {
        guard let fontData = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: fontData as CFData),
              let font = CGFont(provider) else {
            print("[FontManager] Failed to load font at \(url.lastPathComponent)")
            return
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(font, &error) {
            if let fontName = font.postScriptName as String? {
                registeredFonts.insert(fontName)
                print("[FontManager] Registered font: \(fontName)")
            }
        } else if let error = error?.takeRetainedValue() {
            // Font might already be registered - that's fine
            let errorDesc = CFErrorCopyDescription(error) as String? ?? "Unknown error"
            if !errorDesc.contains("already registered") {
                print("[FontManager] Error registering \(url.lastPathComponent): \(errorDesc)")
            }
        }
    }
}

// Token class for bundle lookup
private final class BundleToken {}
