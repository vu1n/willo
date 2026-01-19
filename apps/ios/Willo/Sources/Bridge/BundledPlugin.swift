import Foundation

/// Utilities for accessing the bundled Willo Bridge plugin
enum BundledPlugin {
    /// The bundle containing our resources (SPM uses Bundle.module)
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    /// Load the bundled willo-bridge.wasm plugin
    /// - Returns: The plugin data, or nil if not found
    static func loadPluginData() -> Data? {
        guard let url = resourceBundle.url(forResource: "willo-bridge", withExtension: "wasm") else {
            print("[BundledPlugin] willo-bridge.wasm not found in bundle")
            return nil
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            print("[BundledPlugin] Failed to load willo-bridge.wasm: \(error)")
            return nil
        }
    }

    /// Get the bundled plugin version
    /// - Returns: Version string, or "unknown" if not found
    static func pluginVersion() -> String {
        guard let url = resourceBundle.url(forResource: "willo-bridge", withExtension: "version"),
              let version = try? String(contentsOf: url, encoding: .utf8) else {
            return "unknown"
        }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
