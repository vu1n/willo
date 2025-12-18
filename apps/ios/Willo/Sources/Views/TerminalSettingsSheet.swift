import SwiftUI

/// Settings sheet for adjusting terminal appearance while in-session
struct TerminalSettingsSheet: View {
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TERMINAL SETTINGS")
                    .font(.willoSectionHeader)
                    .tracking(2)
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.willoMono(.callout, weight: .semibold))
                        .foregroundStyle(Color.terminalCyan)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
                .background(Color.bezelLight.opacity(0.2))

            ScrollView {
                VStack(spacing: 24) {
                    // Font Size Section
                    SettingsSection(title: "Font Size", icon: "textformat.size") {
                        VStack(spacing: 16) {
                            // Current size display
                            HStack {
                                Text("\(Int(appearanceSettings.fontSize))")
                                    .font(.willoDisplay(36, weight: .bold))
                                    .foregroundStyle(Color.terminalCyan)

                                Text("pt")
                                    .font(.willoMono(.title3))
                                    .foregroundStyle(Color.textTertiary)

                                Spacer()
                            }

                            // Font preview
                            FontPreview(fontSize: appearanceSettings.fontSize)

                            // Slider
                            VStack(spacing: 8) {
                                Slider(
                                    value: $appearanceSettings.fontSize,
                                    in: AppearanceSettings.minFontSize...AppearanceSettings.maxFontSize,
                                    step: 1
                                )
                                .tint(.terminalCyan)

                                HStack {
                                    Text("\(Int(AppearanceSettings.minFontSize))pt")
                                        .font(.willoCaption)
                                        .foregroundStyle(Color.textTertiary)
                                    Spacer()
                                    Text("\(Int(AppearanceSettings.maxFontSize))pt")
                                        .font(.willoCaption)
                                        .foregroundStyle(Color.textTertiary)
                                }
                            }

                            // Quick size buttons
                            HStack(spacing: 10) {
                                ForEach([16, 20, 24, 28] as [CGFloat], id: \.self) { size in
                                    QuickSizeButton(size: size, current: $appearanceSettings.fontSize)
                                }
                            }
                        }
                    }

                    // Appearance Section
                    SettingsSection(title: "Appearance", icon: "paintbrush") {
                        VStack(spacing: 12) {
                            ForEach(AppearanceSettings.AppearanceMode.allCases, id: \.self) { mode in
                                AppearanceModeButton(
                                    mode: mode,
                                    isSelected: appearanceSettings.mode == mode
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        appearanceSettings.mode = mode
                                    }
                                }
                            }
                        }
                    }

                    // Info
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textTertiary)

                        Text("Changes take effect immediately. Font size affects terminal grid dimensions.")
                            .font(.willoCaption)
                            .foregroundStyle(Color.textTertiary)
                    }
                    .padding(16)
                    .recessedPanel()
                }
                .padding(20)
            }
        }
        .background(Color.machineDark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color.machineDark)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings Section

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.terminalCyan)

                Text(title.uppercased())
                    .font(.willoSectionHeader)
                    .tracking(1.5)
                    .foregroundStyle(Color.textSecondary)
            }

            content()
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.machineGray)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.bezelLight.opacity(0.2), lineWidth: 1)
                        }
                }
        }
    }
}

// MARK: - Font Preview

private struct FontPreview: View {
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("user@willo:~$ ls -la")
                .font(.system(size: min(fontSize, 18), design: .monospaced))
                .foregroundStyle(Color.terminalGreen)

            Text("drwxr-xr-x  12 user staff  384 Dec 19 10:30 .")
                .font(.system(size: min(fontSize, 18), design: .monospaced))
                .foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.machineBlack)
                .overlay {
                    // Scan lines effect
                    ScanLinesView(opacity: 0.03)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.terminalGreen.opacity(0.2), lineWidth: 1)
                }
        }
    }
}

// MARK: - Quick Size Button

private struct QuickSizeButton: View {
    let size: CGFloat
    @Binding var current: CGFloat

    var isSelected: Bool {
        abs(current - size) < 0.5
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                current = size
            }
        } label: {
            Text("\(Int(size))")
                .font(.willoMono(.callout, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.machineBlack : Color.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.terminalCyan : Color.bezelGray)
                        .overlay {
                            if !isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.bezelLight.opacity(0.3), lineWidth: 1)
                            }
                        }
                }
                .shadow(color: isSelected ? Color.terminalCyan.opacity(0.3) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Appearance Mode Button

private struct AppearanceModeButton: View {
    let mode: AppearanceSettings.AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Icon
                Image(systemName: mode.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? modeColor : Color.textTertiary)
                    .frame(width: 24)

                // Label
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.willoMono(.body, weight: .medium))
                        .foregroundStyle(Color.textPrimary)

                    Text(mode.description)
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                }

                Spacer()

                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? modeColor : Color.bezelLight, lineWidth: 2)
                        .frame(width: 22, height: 22)

                    if isSelected {
                        Circle()
                            .fill(modeColor)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? modeColor.opacity(0.1) : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? modeColor.opacity(0.3) : Color.bezelLight.opacity(0.2),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }

    private var modeColor: Color {
        switch mode {
        case .system: return .terminalBlue
        case .light: return .terminalAmber
        case .dark: return .terminalCyan
        }
    }
}

// MARK: - AppearanceMode Extension

extension AppearanceSettings.AppearanceMode {
    var description: String {
        switch self {
        case .system: return "Follow device settings"
        case .light: return "Light background"
        case .dark: return "Dark background"
        }
    }
}

#if os(iOS)
#Preview {
    TerminalSettingsSheet()
        .environmentObject(AppearanceSettings())
}
#endif
