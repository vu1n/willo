#if os(iOS)
import SwiftUI

/// Shows bridge status and prompts for plugin installation/update
///
/// Displays contextual UI when the bridge needs attention:
/// - Plugin not installed: prompt to install
/// - Plugin update needed: prompt to update with version info
/// - Connection errors: show error message
struct BridgeStatusView: View {
    @ObservedObject var bridge: ZellijBridge
    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        switch bridge.bridgeMode {
        case .needsPluginInstall:
            pluginPrompt(
                title: "Install Willo Bridge",
                message: "Install the Willo Bridge plugin to enable Zellij tab sync and control.",
                buttonTitle: "Install Plugin",
                buttonIcon: "square.and.arrow.down"
            )

        case .needsPluginUpdate(let installed, let required):
            pluginPrompt(
                title: "Update Willo Bridge",
                message: "Update the plugin from v\(installed) to v\(required) for compatibility.",
                buttonTitle: "Update Plugin",
                buttonIcon: "arrow.triangle.2.circlepath"
            )

        case .sessionNotFound:
            statusBanner(
                icon: "questionmark.folder",
                message: "Zellij session not found",
                color: .terminalAmber
            )

        case .unsupported(let reason):
            statusBanner(
                icon: "exclamationmark.triangle",
                message: reason,
                color: .terminalRed
            )

        default:
            EmptyView()
        }
    }

    // MARK: - Plugin Prompt

    @ViewBuilder
    private func pluginPrompt(title: String, message: String, buttonTitle: String, buttonIcon: String) -> some View {
        VStack(spacing: 16) {
            // Icon
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.terminalCyan)

            // Text
            VStack(spacing: 6) {
                Text(title)
                    .font(.willoMono(.headline, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                Text(message)
                    .font(.willoCaption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Error message if any
            if let error = installError {
                Text(error)
                    .font(.willoCaption)
                    .foregroundStyle(Color.terminalRed)
                    .multilineTextAlignment(.center)
            }

            // Install button
            Button {
                installPlugin()
            } label: {
                HStack(spacing: 8) {
                    if isInstalling {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .machineBlack))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(isInstalling ? "Installing..." : buttonTitle)
                        .font(.willoMono(.subheadline, weight: .semibold))
                }
                .foregroundStyle(Color.machineBlack)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background {
                    Capsule()
                        .fill(Color.terminalCyan)
                }
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.machineGray)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.terminalCyan.opacity(0.3), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    // MARK: - Status Banner

    @ViewBuilder
    private func statusBanner(icon: String, message: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)

            Text(message)
                .font(.willoMono(.caption, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(color.opacity(0.3), lineWidth: 1)
                }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Install Plugin

    private func installPlugin() {
        isInstalling = true
        installError = nil

        Task {
            do {
                try await bridge.installBundledPluginAndRetry()
            } catch {
                await MainActor.run {
                    installError = error.localizedDescription
                }
            }
            await MainActor.run {
                isInstalling = false
            }
        }
    }
}

// MARK: - Compact Status Indicator

/// Compact bridge status indicator for status bar integration
struct BridgeStatusIndicator: View {
    @ObservedObject var bridge: ZellijBridge

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            if showStatusText {
                Text(bridge.bridgeMode.statusText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusColor: Color {
        switch bridge.bridgeMode {
        case .streaming: return .terminalGreen
        case .connecting, .awaitingHello: return .terminalAmber
        case .needsPluginInstall, .needsPluginUpdate: return .terminalCyan
        case .sessionNotFound, .unsupported: return .terminalRed
        case .disconnected: return .textTertiary
        }
    }

    private var showStatusText: Bool {
        switch bridge.bridgeMode {
        case .streaming, .disconnected:
            return false
        default:
            return true
        }
    }
}

#Preview("Plugin Install") {
    ZStack {
        Color.machineBlack.ignoresSafeArea()

        BridgeStatusView(bridge: ZellijBridge(sessionName: "preview"))
    }
}
#endif
