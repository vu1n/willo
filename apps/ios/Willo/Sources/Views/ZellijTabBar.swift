#if os(iOS)
import SwiftUI

/// Displays Zellij tabs when bridge is connected and streaming
///
/// Shows a horizontal scrollable tab bar with:
/// - Tab names from Zellij session state
/// - Active tab highlighted
/// - Tap to switch tabs via bridge API
/// - Plus button to create new tab
struct ZellijTabBar: View {
    @ObservedObject var bridge: ZellijBridge
    let onTabSelect: (Int) -> Void
    let onNewTab: () -> Void

    var body: some View {
        // Only show if streaming with tabs
        if bridge.bridgeMode == .streaming,
           let state = bridge.zellijState,
           !state.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    // Tab items
                    ForEach(state.tabs) { tab in
                        ZellijTabItem(
                            tab: tab,
                            isActive: tab.active
                        ) {
                            onTabSelect(tab.position)
                        }
                    }

                    // New tab button
                    Button {
                        onNewTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.textTertiary)
                            .frame(width: 28, height: 28)
                            .background {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.bezelGray.opacity(0.5))
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background {
                Rectangle()
                    .fill(Color.machineGray.opacity(0.8))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.bezelLight.opacity(0.15))
                            .frame(height: 1)
                    }
            }
        }
    }
}

// MARK: - Tab Item

private struct ZellijTabItem: View {
    let tab: ZellijTab
    let isActive: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Tab indicator dot
                Circle()
                    .fill(isActive ? Color.terminalGreen : Color.textTertiary.opacity(0.5))
                    .frame(width: 6, height: 6)

                // Tab name
                Text(displayName)
                    .font(.willoMono(.caption, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(1)

                // Mode indicator (if not normal)
                if let mode = tab.mode, mode != "Normal" {
                    Text(modeAbbreviation(mode))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(modeColor(mode))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(modeColor(mode).opacity(0.2))
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(backgroundColor)
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.terminalGreen.opacity(0.3), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }

    private var displayName: String {
        // Use tab name, or "Tab N" as fallback
        tab.name.isEmpty ? "Tab \(tab.position + 1)" : tab.name
    }

    private var backgroundColor: Color {
        if isPressed {
            return Color.bezelGray
        } else if isActive {
            return Color.machineBlack.opacity(0.6)
        } else {
            return Color.clear
        }
    }

    private func modeAbbreviation(_ mode: String) -> String {
        switch mode.lowercased() {
        case "pane": return "P"
        case "tab": return "T"
        case "resize": return "R"
        case "move": return "M"
        case "scroll": return "S"
        case "search": return "/"
        case "session": return "O"
        case "locked": return "L"
        default: return String(mode.prefix(1)).uppercased()
        }
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode.lowercased() {
        case "pane": return .terminalCyan
        case "tab": return .terminalAmber
        case "resize": return .terminalMagenta
        case "move": return .terminalBlue
        case "scroll", "search": return .terminalGreen
        case "session": return .terminalAmber
        case "locked": return .terminalRed
        default: return .textTertiary
        }
    }
}

#Preview {
    // Create a mock bridge for preview
    let bridge = ZellijBridge(sessionName: "preview")

    return VStack(spacing: 0) {
        ZellijTabBar(
            bridge: bridge,
            onTabSelect: { index in
                print("Selected tab \(index)")
            },
            onNewTab: {
                print("New tab")
            }
        )

        Spacer()
    }
    .background(Color.machineBlack)
}
#endif
