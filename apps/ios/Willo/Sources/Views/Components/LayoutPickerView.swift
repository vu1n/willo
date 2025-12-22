import SwiftUI

// MARK: - Layout Picker View

/// Mission control-style layout selector with schematic previews
struct LayoutPickerView: View {
    @Binding var selectedLayoutId: String?
    @Environment(\.dismiss) var dismiss

    let layouts = LayoutTemplate.builtIn
    let currentDevice = DeviceOrigin.current

    @State private var hoveredId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header explanation
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.terminalCyan)
                            .glowEffect(color: .terminalCyan, radius: 8)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("TERMINAL LAYOUT")
                                .font(.willoSectionHeader)
                                .tracking(2)
                                .foregroundStyle(Color.textSecondary)

                            Text("Configure your zellij pane arrangement")
                                .font(.willoCaption)
                                .foregroundStyle(Color.textTertiary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    // Device filter legend
                    DeviceLegend()

                    // Layout grid
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ], spacing: 16) {
                        ForEach(layouts) { layout in
                            LayoutCard(
                                layout: layout,
                                isSelected: selectedLayoutId == layout.id,
                                currentDevice: currentDevice
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedLayoutId = layout.id
                                }
                            }
                        }
                    }

                    // None option
                    NoneLayoutCard(isSelected: selectedLayoutId == nil) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedLayoutId = nil
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.machineDark)
            .overlay {
                ScanLinesView(opacity: 0.015)
                    .allowsHitTesting(false)
            }
            .navigationTitle("Layout")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.machineGray, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.willoMono(.callout, weight: .semibold))
                        .foregroundStyle(Color.terminalCyan)
                }
            }
            #endif
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Device Legend

private struct DeviceLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            ForEach(DeviceOrigin.allCases, id: \.self) { device in
                HStack(spacing: 6) {
                    Image(systemName: device.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(device == DeviceOrigin.current ? Color.terminalCyan : Color.textTertiary)

                    Text(device.displayName)
                        .font(.willoCaption)
                        .foregroundStyle(device == DeviceOrigin.current ? Color.textPrimary : Color.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .recessedPanel(cornerRadius: 8)
    }
}

// MARK: - Layout Card

private struct LayoutCard: View {
    let layout: LayoutTemplate
    let isSelected: Bool
    let currentDevice: DeviceOrigin
    let action: () -> Void

    private var isSuitableForDevice: Bool {
        layout.suitableFor.contains(currentDevice)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Schematic preview
                LayoutSchematic(layoutId: layout.id)
                    .frame(height: 80)
                    .padding(8)
                    .recessedPanel(cornerRadius: 8)

                // Info row
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(layout.name)
                            .font(.willoMono(.subheadline, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)

                        Text(layout.description)
                            .font(.willoCaption)
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Device suitability LEDs
                    DeviceLEDCluster(suitableFor: layout.suitableFor)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                isSelected ? Color.terminalCyan.opacity(0.15) : Color.bezelGray,
                                isSelected ? Color.terminalCyan.opacity(0.08) : Color.machineGray
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.terminalCyan.opacity(0.6) : Color.bezelLight.opacity(0.3),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
            }
            .shadow(color: isSelected ? Color.terminalCyan.opacity(0.3) : .clear, radius: 8)
            .opacity(isSuitableForDevice ? 1 : 0.5)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.terminalCyan)
                        .background(Circle().fill(Color.machineBlack).padding(-2))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - None Layout Card

private struct NoneLayoutCard: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.machineBlack)
                        .frame(width: 48, height: 48)

                    Image(systemName: "slash.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("No Layout")
                        .font(.willoMono(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text("Start with default zellij session")
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.terminalCyan)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                isSelected ? Color.terminalCyan.opacity(0.15) : Color.bezelGray.opacity(0.5),
                                isSelected ? Color.terminalCyan.opacity(0.08) : Color.machineGray.opacity(0.5)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.terminalCyan.opacity(0.6) : Color.bezelLight.opacity(0.2),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
            }
            .shadow(color: isSelected ? Color.terminalCyan.opacity(0.3) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Device LED Cluster

private struct DeviceLEDCluster: View {
    let suitableFor: Set<DeviceOrigin>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DeviceOrigin.allCases, id: \.self) { device in
                DeviceLED(
                    device: device,
                    isActive: suitableFor.contains(device)
                )
            }
        }
    }
}

private struct DeviceLED: View {
    let device: DeviceOrigin
    let isActive: Bool

    var body: some View {
        ZStack {
            // Glow (only when active)
            if isActive {
                Circle()
                    .fill(Color.terminalGreen.opacity(0.4))
                    .frame(width: 16, height: 16)
                    .blur(radius: 4)
            }

            // LED body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            isActive ? Color.terminalGreen : Color.bezelGray,
                            isActive ? Color.terminalGreen.opacity(0.7) : Color.machineGray
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 5
                    )
                )
                .frame(width: 10, height: 10)
                .overlay {
                    // Highlight
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(isActive ? 0.4 : 0.1), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .frame(width: 6, height: 4)
                        .offset(y: -2)
                }
        }
        .frame(width: 18, height: 18)
        .help(device.displayName)
    }
}

// MARK: - Layout Schematic

/// Visual schematic representation of a layout
private struct LayoutSchematic: View {
    let layoutId: String

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            switch layoutId {
            case "focus":
                // Single pane
                SchematicPane(label: "MAIN")
                    .frame(width: size.width, height: size.height)

            case "split":
                // Two horizontal panes
                HStack(spacing: 2) {
                    SchematicPane(label: "MAIN")
                        .frame(width: size.width * 0.6)
                    SchematicPane(label: "OUT")
                        .frame(width: size.width * 0.4 - 2)
                }
                .frame(height: size.height)

            case "monitor":
                // Stacked panes indicator
                VStack(spacing: 1) {
                    ForEach(0..<4) { i in
                        SchematicPane(label: i == 0 ? "▶ SERVER-1" : "", isStacked: true)
                    }
                }
                .frame(width: size.width, height: size.height)

            case "dev":
                // L-shape: editor + terminal/output
                HStack(spacing: 2) {
                    SchematicPane(label: "EDITOR")
                        .frame(width: size.width * 0.65)
                    VStack(spacing: 2) {
                        SchematicPane(label: "TERM")
                        SchematicPane(label: "OUT")
                    }
                    .frame(width: size.width * 0.35 - 2)
                }
                .frame(height: size.height)

            case "dashboard":
                // 2x2 grid
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        SchematicPane(label: "1")
                        SchematicPane(label: "2")
                    }
                    HStack(spacing: 2) {
                        SchematicPane(label: "3")
                        SchematicPane(label: "4")
                    }
                }
                .frame(width: size.width, height: size.height)

            case "tabs-dev":
                // Tabs with content preview
                VStack(spacing: 2) {
                    // Tab bar schematic
                    HStack(spacing: 2) {
                        SchematicTab(label: "CODE", isActive: true)
                        SchematicTab(label: "GIT", isActive: false)
                        SchematicTab(label: "SRV", isActive: false)
                        Spacer()
                    }
                    .frame(height: 14)

                    // Content
                    HStack(spacing: 2) {
                        SchematicPane(label: "EDITOR")
                            .frame(width: size.width * 0.7)
                        SchematicPane(label: "TERM")
                            .frame(width: size.width * 0.3 - 2)
                    }
                }
                .frame(width: size.width, height: size.height)

            default:
                SchematicPane(label: "?")
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}

private struct SchematicPane: View {
    let label: String
    var isStacked: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.machineBlack)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.terminalCyan.opacity(0.4), lineWidth: 1)
            }
            .overlay {
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: isStacked ? 7 : 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.terminalCyan.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
    }
}

private struct SchematicTab: View {
    let label: String
    let isActive: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 6, weight: .bold, design: .monospaced))
            .foregroundStyle(isActive ? Color.terminalCyan : Color.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isActive ? Color.terminalCyan.opacity(0.2) : Color.machineBlack)
            }
    }
}

// MARK: - Inline Layout Picker (Compact)

/// Compact horizontal layout picker for inline use
struct InlineLayoutPicker: View {
    @Binding var selectedLayoutId: String?
    @State private var showingFullPicker = false

    var body: some View {
        Button {
            showingFullPicker = true
        } label: {
            HStack(spacing: 12) {
                // Mini schematic
                if let layoutId = selectedLayoutId {
                    LayoutSchematic(layoutId: layoutId)
                        .frame(width: 48, height: 32)
                        .recessedPanel(cornerRadius: 6)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.machineBlack)
                        .frame(width: 48, height: 32)
                        .overlay {
                            Image(systemName: "slash.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.textTertiary)
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedLayout?.name ?? "No Layout")
                        .font(.willoMono(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text(selectedLayout?.description ?? "Default zellij session")
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.machineGray)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.bezelLight.opacity(0.3), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingFullPicker) {
            LayoutPickerView(selectedLayoutId: $selectedLayoutId)
        }
    }

    private var selectedLayout: LayoutTemplate? {
        guard let id = selectedLayoutId else { return nil }
        return LayoutTemplate.builtIn.first { $0.id == id }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Layout Picker") {
    LayoutPickerView(selectedLayoutId: .constant("dev"))
}

#Preview("Inline Picker") {
    VStack(spacing: 20) {
        InlineLayoutPicker(selectedLayoutId: .constant("split"))
        InlineLayoutPicker(selectedLayoutId: .constant(nil))
    }
    .padding()
    .background(Color.machineDark)
    .preferredColorScheme(.dark)
}
#endif
