import Foundation

/// Bridge capability detection result
enum BridgeCapabilities: Equatable {
    /// Full streaming support available
    case streaming

    /// Plugin needs to be installed
    case needsPluginInstall

    /// Plugin version mismatch
    case needsPluginUpdate(installed: String, required: String)

    /// Session not found
    case sessionNotFound

    /// Bridge not supported (e.g., old Zellij version)
    case unsupported(reason: String)

    static func == (lhs: BridgeCapabilities, rhs: BridgeCapabilities) -> Bool {
        switch (lhs, rhs) {
        case (.streaming, .streaming),
             (.needsPluginInstall, .needsPluginInstall),
             (.sessionNotFound, .sessionNotFound):
            return true
        case (.needsPluginUpdate(let lI, let lR), .needsPluginUpdate(let rI, let rR)):
            return lI == rI && lR == rR
        case (.unsupported(let lReason), .unsupported(let rReason)):
            return lReason == rReason
        default:
            return false
        }
    }
}

/// Semantic version parsing
struct Version: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(string: String) {
        // Parse "0.42.1" or "zellij 0.42.1"
        let versionPattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: versionPattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let majorRange = Range(match.range(at: 1), in: string),
              let minorRange = Range(match.range(at: 2), in: string),
              let patchRange = Range(match.range(at: 3), in: string),
              let major = Int(string[majorRange]),
              let minor = Int(string[minorRange]),
              let patch = Int(string[patchRange]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Capability detection utilities
enum CapabilityDetector {
    /// Minimum Zellij version required for pipe support
    static let minimumZellijVersion = Version(0, 40, 0)

    /// Current plugin version (loaded from bundled plugin)
    static let pluginVersion = BundledPlugin.pluginVersion()

    /// Detect bridge capabilities on the remote server
    static func detect(
        transport: NIOSSHTransport,
        sessionName: String
    ) async throws -> BridgeCapabilities {
        // 1. Check zellij version
        let versionOutput = try await transport.executeCommand("zellij --version 2>/dev/null || echo 'not-found'")
        let versionStr = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        if versionStr == "not-found" || versionStr.isEmpty {
            return .unsupported(reason: "Zellij not installed on server")
        }

        guard let version = Version(string: versionStr), version >= minimumZellijVersion else {
            return .unsupported(reason: "Zellij 0.40.0+ required for pipe support (found: \(versionStr))")
        }

        // 2. Check if session exists (whitelist approach)
        let sessionsOutput = try await transport.executeCommand("zellij list-sessions --short 2>/dev/null || echo ''")
        let sessions = sessionsOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)

        guard sessions.contains(sessionName) else {
            return .sessionNotFound
        }

        // 3. Check plugin exists and version matches
        // Use $HOME instead of ~ for reliable expansion
        let pluginCheck = try await transport.executeCommand("""
            if [ -f "$HOME/.willo/willo-bridge.wasm" ]; then
                cat "$HOME/.willo/willo-bridge.version" 2>/dev/null || echo "unknown"
            else
                echo "missing"
            fi
        """)

        let installedVersion = pluginCheck.trimmingCharacters(in: .whitespacesAndNewlines)

        if installedVersion == "missing" {
            return .needsPluginInstall
        } else if installedVersion != pluginVersion && installedVersion != "unknown" {
            return .needsPluginUpdate(installed: installedVersion, required: pluginVersion)
        }

        return .streaming
    }

    /// Validate that a session exists
    static func validateSession(
        _ name: String,
        transport: NIOSSHTransport
    ) async throws -> Bool {
        let output = try await transport.executeCommand("zellij list-sessions --short 2>/dev/null || echo ''")
        let sessions = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)
        return sessions.contains(name)
    }

    /// Deploy the bridge plugin to the remote server using chunked upload
    /// This handles large WASM files that would exceed command line limits
    static func deployPlugin(
        transport: NIOSSHTransport,
        pluginData: Data
    ) async throws {
        // Create .willo directory
        _ = try await transport.executeCommand("mkdir -p \"$HOME/.willo\"")

        // Clear any existing partial upload
        _ = try await transport.executeCommand("rm -f \"$HOME/.willo/willo-bridge.wasm.tmp\"")

        // Upload in chunks to avoid command line length limits
        // Each chunk is ~48KB base64 encoded (~64KB after encoding)
        let chunkSize = 48_000
        let base64Data = pluginData.base64EncodedData()
        var offset = 0

        while offset < base64Data.count {
            let end = min(offset + chunkSize, base64Data.count)
            let chunk = base64Data[offset..<end]

            guard let chunkString = String(data: chunk, encoding: .utf8) else {
                throw PluginDeploymentError.encodingFailed
            }

            // Append chunk to temp file (using printf to handle special chars)
            let appendCmd = offset == 0
                ? "printf '%s' '\(chunkString)' > \"$HOME/.willo/willo-bridge.wasm.b64\""
                : "printf '%s' '\(chunkString)' >> \"$HOME/.willo/willo-bridge.wasm.b64\""

            _ = try await transport.executeCommand(appendCmd)
            offset = end
        }

        // Decode base64 to final binary and verify
        let decodeResult = try await transport.executeCommand("""
            base64 -d "$HOME/.willo/willo-bridge.wasm.b64" > "$HOME/.willo/willo-bridge.wasm.tmp" && \
            mv "$HOME/.willo/willo-bridge.wasm.tmp" "$HOME/.willo/willo-bridge.wasm" && \
            rm -f "$HOME/.willo/willo-bridge.wasm.b64" && \
            echo "OK:\(pluginData.count)" || echo "FAIL"
        """)

        // Verify deployment
        let result = decodeResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("OK:") else {
            throw PluginDeploymentError.deploymentFailed(result)
        }

        // Verify size matches
        let expectedSize = "OK:\(pluginData.count)"
        if !result.contains(String(pluginData.count)) {
            print("[BridgeCapabilities] Warning: size mismatch - expected \(expectedSize), got \(result)")
        }

        // Write version file
        _ = try await transport.executeCommand("""
            echo '\(pluginVersion)' > "$HOME/.willo/willo-bridge.version"
        """)
    }
}

// MARK: - Plugin Deployment Errors

enum PluginDeploymentError: LocalizedError {
    case encodingFailed
    case deploymentFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode plugin data"
        case .deploymentFailed(let reason):
            return "Plugin deployment failed: \(reason)"
        case .verificationFailed:
            return "Plugin verification failed"
        }
    }
}
