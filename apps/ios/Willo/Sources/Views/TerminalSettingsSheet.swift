import SwiftUI

/// Settings sheet for adjusting terminal appearance while in-session
struct TerminalSettingsSheet: View {
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .font

    enum SettingsTab: String, CaseIterable {
        case font = "Font"
        case appearance = "Appearance"

        var icon: String {
            switch self {
            case .font: return "textformat"
            case .appearance: return "paintbrush"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SETTINGS")
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

            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()
                .background(Color.bezelLight.opacity(0.2))

            // Tab content
            TabView(selection: $selectedTab) {
                FontTabContent()
                    .tag(SettingsTab.font)

                AppearanceTabContent()
                    .tag(SettingsTab.appearance)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color.machineDark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color.machineDark)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let tab: TerminalSettingsSheet.SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .medium))

                Text(tab.rawValue)
                    .font(.willoMono(.callout, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.terminalCyan : Color.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.terminalCyan.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.terminalCyan.opacity(0.3), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Font Tab

private struct FontTabContent: View {
    @EnvironmentObject var appearanceSettings: AppearanceSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Font Family Section
                SettingsSection(title: "Font Family", icon: "character") {
                    VStack(spacing: 8) {
                        ForEach(AppearanceSettings.FontFamily.allCases, id: \.self) { family in
                            FontFamilyButton(
                                family: family,
                                isSelected: appearanceSettings.fontFamily == family
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    appearanceSettings.fontFamily = family
                                }
                            }
                        }
                    }
                }

                // Font Size Section
                SettingsSection(title: "Font Size", icon: "textformat.size") {
                    VStack(spacing: 16) {
                        // Current size display + preview
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("\(Int(appearanceSettings.fontSize))")
                                        .font(.willoDisplay(42, weight: .bold))
                                        .foregroundStyle(Color.terminalCyan)

                                    Text("pt")
                                        .font(.willoMono(.title3))
                                        .foregroundStyle(Color.textTertiary)
                                }
                            }

                            Spacer()

                            // Mini preview
                            FontPreview(
                                fontFamily: appearanceSettings.fontFamily,
                                fontSize: appearanceSettings.fontSize
                            )
                        }

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
                        HStack(spacing: 8) {
                            ForEach([16, 20, 24, 28] as [CGFloat], id: \.self) { size in
                                QuickSizeButton(size: size, current: $appearanceSettings.fontSize)
                            }
                        }
                    }
                }

                // Info
                InfoBanner(text: "Font changes take effect immediately and affect terminal grid dimensions.")
            }
            .padding(20)
        }
    }
}

// MARK: - Appearance Tab

private struct AppearanceTabContent: View {
    @EnvironmentObject var appearanceSettings: AppearanceSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsSection(title: "Color Scheme", icon: "circle.lefthalf.filled") {
                    VStack(spacing: 10) {
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

                InfoBanner(text: "Color scheme affects the terminal background and UI elements.")
            }
            .padding(20)
        }
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

// MARK: - Font Family Button

private struct FontFamilyButton: View {
    let family: AppearanceSettings.FontFamily
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Font sample
                Text("Aa")
                    .font(.custom(family.fontName, size: 20))
                    .foregroundStyle(isSelected ? Color.terminalCyan : Color.textSecondary)
                    .frame(width: 40)

                // Label
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.displayName)
                        .font(.willoMono(.body, weight: .medium))
                        .foregroundStyle(Color.textPrimary)

                    Text(family.description)
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                }

                Spacer()

                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.terminalCyan : Color.bezelLight, lineWidth: 2)
                        .frame(width: 22, height: 22)

                    if isSelected {
                        Circle()
                            .fill(Color.terminalCyan)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.terminalCyan.opacity(0.1) : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.terminalCyan.opacity(0.3) : Color.bezelLight.opacity(0.2),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Font Preview

private struct FontPreview: View {
    let fontFamily: AppearanceSettings.FontFamily
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ls -la")
                .font(.custom(fontFamily.fontName, size: min(fontSize, 16)))
                .foregroundStyle(Color.terminalGreen)

            Text("total 42")
                .font(.custom(fontFamily.fontName, size: min(fontSize, 16)))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.machineBlack)
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
            .padding(12)
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

// MARK: - Info Banner

private struct InfoBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.textTertiary)

            Text(text)
                .font(.willoCaption)
                .foregroundStyle(Color.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .recessedPanel()
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
