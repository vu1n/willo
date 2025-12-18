import SwiftUI

/// Industrial-style appearance mode toggle
/// Inspired by cockpit switches and audio equipment - tactile, purposeful, premium
struct AppearanceToggle: View {
    @ObservedObject var settings: AppearanceSettings
    @Environment(\.colorScheme) var systemScheme

    private let modes = AppearanceSettings.AppearanceMode.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(modes, id: \.self) { mode in
                ToggleSegment(
                    mode: mode,
                    isSelected: settings.mode == mode,
                    action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            settings.mode = mode
                        }
                    }
                )
            }
        }
        .padding(3)
        .background {
            // Outer bezel - machined metal look
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: systemScheme == .dark ? 0.15 : 0.88),
                            Color(white: systemScheme == .dark ? 0.08 : 0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(white: systemScheme == .dark ? 0.25 : 0.95),
                                    Color(white: systemScheme == .dark ? 0.05 : 0.75)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
        }
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

private struct ToggleSegment: View {
    let mode: AppearanceSettings.AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: mode.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                Text(mode.displayName)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .foregroundStyle(isSelected ? selectedForeground : unselectedForeground)
            .frame(width: 52, height: 44)
            .background {
                if isSelected {
                    selectedBackground
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        indicatorColor.opacity(0.9),
                        indicatorColor
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                // Inner glow / highlight
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.3),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: indicatorColor.opacity(0.4), radius: 4, y: 2)
    }

    private var indicatorColor: Color {
        switch mode {
        case .system:
            return Color(red: 0.45, green: 0.55, blue: 0.68) // Steel blue
        case .light:
            return Color(red: 0.95, green: 0.75, blue: 0.35) // Warm amber
        case .dark:
            return Color(red: 0.35, green: 0.45, blue: 0.62) // Deep slate
        }
    }

    private var selectedForeground: Color {
        switch mode {
        case .light:
            return Color(white: 0.15)
        default:
            return .white
        }
    }

    private var unselectedForeground: Color {
        colorScheme == .dark ? Color(white: 0.5) : Color(white: 0.4)
    }
}

/// Compact single-button toggle that cycles through modes
struct AppearanceToggleCompact: View {
    @ObservedObject var settings: AppearanceSettings
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                settings.mode = nextMode
            }
        } label: {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(white: colorScheme == .dark ? 0.3 : 0.8),
                                Color(white: colorScheme == .dark ? 0.15 : 0.65)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )

                // Icon
                Image(systemName: settings.mode.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .rotationEffect(.degrees(iconRotation))
            }
            .frame(width: 32, height: 32)
            .background {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(white: colorScheme == .dark ? 0.18 : 0.92),
                                Color(white: colorScheme == .dark ? 0.1 : 0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    private var nextMode: AppearanceSettings.AppearanceMode {
        switch settings.mode {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    private var iconColor: Color {
        switch settings.mode {
        case .system:
            return Color(red: 0.45, green: 0.55, blue: 0.68)
        case .light:
            return Color(red: 0.95, green: 0.7, blue: 0.2)
        case .dark:
            return Color(red: 0.6, green: 0.7, blue: 0.9)
        }
    }

    private var iconRotation: Double {
        switch settings.mode {
        case .system: return 0
        case .light: return 15
        case .dark: return -15
        }
    }
}

#Preview("Full Toggle") {
    VStack(spacing: 40) {
        AppearanceToggle(settings: AppearanceSettings())
        AppearanceToggle(settings: AppearanceSettings())
            .environment(\.colorScheme, .dark)
    }
    .padding(40)
    .background(Color(.systemBackground))
}

#Preview("Compact Toggle") {
    HStack(spacing: 20) {
        AppearanceToggleCompact(settings: AppearanceSettings())
        AppearanceToggleCompact(settings: AppearanceSettings())
            .environment(\.colorScheme, .dark)
    }
    .padding(40)
    .background(Color(.systemBackground))
}
