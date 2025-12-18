import SwiftUI

// MARK: - Willo Design System
// Mission Control Terminal aesthetic: industrial, tactile, premium
// Dark-first with high-contrast terminal accents

// MARK: - Color Palette

extension Color {
    // Terminal accent colors (glowing indicators)
    static let terminalGreen = Color(red: 0.2, green: 0.9, blue: 0.4)
    static let terminalAmber = Color(red: 0.95, green: 0.75, blue: 0.35)
    static let terminalRed = Color(red: 0.95, green: 0.3, blue: 0.3)
    static let terminalCyan = Color(red: 0.3, green: 0.85, blue: 0.9)
    static let terminalBlue = Color(red: 0.4, green: 0.6, blue: 0.95)

    // Surface colors (machined metal)
    static let machineBlack = Color(red: 0.06, green: 0.06, blue: 0.08)
    static let machineDark = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let machineGray = Color(red: 0.14, green: 0.14, blue: 0.16)
    static let bezelGray = Color(red: 0.18, green: 0.18, blue: 0.20)
    static let bezelLight = Color(red: 0.24, green: 0.24, blue: 0.26)

    // Text colors
    static let textPrimary = Color(white: 0.92)
    static let textSecondary = Color(white: 0.6)
    static let textTertiary = Color(white: 0.4)

    // Semantic status colors
    static let statusConnected = terminalGreen
    static let statusConnecting = terminalAmber
    static let statusDisconnected = Color(white: 0.4)
    static let statusError = terminalRed
}

// MARK: - Typography

extension Font {
    /// Primary monospace font for terminal content and technical UI
    static func willoMono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }

    /// Display font for headers and titles
    static func willoDisplay(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Caption for labels and hints
    static let willoCaption = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// Small caps for section headers
    static let willoSectionHeader = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

// MARK: - View Extensions

extension View {
    /// Apply machined metal background with bezel
    func machinedSurface(cornerRadius: CGFloat = 12) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.bezelGray, Color.machineGray],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.bezelLight.opacity(0.6), Color.black.opacity(0.3)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
            }
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    /// Apply recessed panel background (for inset areas)
    func recessedPanel(cornerRadius: CGFloat = 8) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.machineBlack)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.black.opacity(0.5), Color.bezelGray.opacity(0.3)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
            }
    }

    /// Apply glowing effect for status indicators
    func glowEffect(color: Color, radius: CGFloat = 8, isActive: Bool = true) -> some View {
        self
            .shadow(color: isActive ? color.opacity(0.6) : .clear, radius: radius / 2)
            .shadow(color: isActive ? color.opacity(0.3) : .clear, radius: radius)
    }

    /// Mission control grid background
    func gridBackground() -> some View {
        self.background {
            GridPatternView()
        }
    }
}

// MARK: - Grid Pattern Background

struct GridPatternView: View {
    var body: some View {
        Canvas { context, size in
            let gridSize: CGFloat = 32
            let lineWidth: CGFloat = 0.5
            let lineColor = Color.bezelGray.opacity(0.3)

            // Vertical lines
            var x: CGFloat = 0
            while x <= size.width {
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: .color(lineColor), lineWidth: lineWidth)
                x += gridSize
            }

            // Horizontal lines
            var y: CGFloat = 0
            while y <= size.height {
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(lineColor), lineWidth: lineWidth)
                y += gridSize
            }
        }
        .background(Color.machineDark)
    }
}

// MARK: - Scan Lines Overlay

struct ScanLinesView: View {
    var opacity: Double = 0.03

    var body: some View {
        Canvas { context, size in
            let lineSpacing: CGFloat = 2
            var y: CGFloat = 0
            while y <= size.height {
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.black.opacity(opacity)), lineWidth: 1)
                y += lineSpacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Status LED Indicator

struct StatusLED: View {
    let status: LEDStatus
    var size: CGFloat = 8
    var showPulse: Bool = true

    enum LEDStatus {
        case connected
        case connecting
        case disconnected
        case error

        var color: Color {
            switch self {
            case .connected: return .terminalGreen
            case .connecting: return .terminalAmber
            case .disconnected: return .statusDisconnected
            case .error: return .terminalRed
            }
        }

        var shouldPulse: Bool {
            switch self {
            case .connecting: return true
            default: return false
            }
        }
    }

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(status.color.opacity(0.3))
                .frame(width: size * 2, height: size * 2)
                .blur(radius: size / 2)
                .opacity(status == .disconnected ? 0 : 1)

            // Main LED
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            status.color,
                            status.color.opacity(0.8)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size / 2
                    )
                )
                .frame(width: size, height: size)
                .overlay {
                    // Highlight
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.4), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .frame(width: size * 0.6, height: size * 0.4)
                        .offset(y: -size * 0.15)
                }

            // Pulse ring
            if showPulse && status.shouldPulse {
                Circle()
                    .stroke(status.color.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(isPulsing ? 2.5 : 1)
                    .opacity(isPulsing ? 0 : 0.8)
            }
        }
        .frame(width: size * 2.5, height: size * 2.5)
        .onAppear {
            if status.shouldPulse && showPulse {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
        }
        .onChange(of: status) { _, newStatus in
            isPulsing = false
            if newStatus.shouldPulse && showPulse {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
        }
    }
}

// MARK: - Industrial Button

struct IndustrialButton: View {
    let title: String
    var icon: String? = nil
    var style: ButtonStyle = .primary
    var size: ButtonSize = .regular
    let action: () -> Void

    enum ButtonStyle {
        case primary    // Highlighted action
        case secondary  // Standard action
        case danger     // Destructive action
        case ghost      // Minimal/text-only

        var backgroundColor: Color {
            switch self {
            case .primary: return .terminalCyan
            case .secondary: return .bezelGray
            case .danger: return .terminalRed
            case .ghost: return .clear
            }
        }

        var foregroundColor: Color {
            switch self {
            case .primary: return .machineBlack
            case .secondary: return .textPrimary
            case .danger: return .white
            case .ghost: return .textSecondary
            }
        }
    }

    enum ButtonSize {
        case small, regular, large

        var horizontalPadding: CGFloat {
            switch self {
            case .small: return 12
            case .regular: return 16
            case .large: return 24
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .small: return 6
            case .regular: return 10
            case .large: return 14
            }
        }

        var font: Font {
            switch self {
            case .small: return .willoMono(.caption, weight: .semibold)
            case .regular: return .willoMono(.callout, weight: .semibold)
            case .large: return .willoMono(.body, weight: .semibold)
            }
        }
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(size.font)
                }
                Text(title)
                    .font(size.font)
            }
            .foregroundStyle(isEnabled ? style.foregroundColor : Color.textTertiary)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background {
                if style != .ghost {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    style.backgroundColor.opacity(isEnabled ? 1 : 0.3),
                                    style.backgroundColor.opacity(isEnabled ? 0.85 : 0.25)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.2),
                                            Color.black.opacity(0.2)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        }
                }
            }
            .shadow(color: style == .primary ? style.backgroundColor.opacity(0.3) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Industrial Card

struct IndustrialCard<Content: View>: View {
    var showBezel: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background {
                if showBezel {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.bezelGray, Color.machineGray],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.bezelLight.opacity(0.5), Color.black.opacity(0.4)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.machineGray.opacity(0.5))
                }
            }
    }
}

// MARK: - Section Header

struct IndustrialSectionHeader: View {
    let title: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.willoCaption)
                    .foregroundStyle(Color.terminalCyan)
            }

            Text(title.uppercased())
                .font(.willoSectionHeader)
                .tracking(1.5)
                .foregroundStyle(Color.textSecondary)

            // Decorative line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.bezelLight, Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Icon Button (for toolbar)

struct IndustrialIconButton: View {
    let icon: String
    var isActive: Bool = false
    var activeColor: Color = .terminalCyan
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : Color.textSecondary)
                .frame(width: 36, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.bezelGray.opacity(isActive ? 0.8 : 0.5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.bezelLight.opacity(0.3), lineWidth: 1)
                        }
                }
                .shadow(color: isActive ? activeColor.opacity(0.3) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Design System") {
    ScrollView {
        VStack(spacing: 32) {
            // Status LEDs
            VStack(alignment: .leading, spacing: 16) {
                IndustrialSectionHeader(title: "Status Indicators", icon: "circle.fill")

                HStack(spacing: 24) {
                    VStack {
                        StatusLED(status: .connected)
                        Text("Connected").font(.willoCaption)
                    }
                    VStack {
                        StatusLED(status: .connecting)
                        Text("Connecting").font(.willoCaption)
                    }
                    VStack {
                        StatusLED(status: .disconnected)
                        Text("Offline").font(.willoCaption)
                    }
                    VStack {
                        StatusLED(status: .error)
                        Text("Error").font(.willoCaption)
                    }
                }
                .foregroundStyle(Color.textSecondary)
            }
            .padding()
            .machinedSurface()

            // Buttons
            VStack(alignment: .leading, spacing: 16) {
                IndustrialSectionHeader(title: "Buttons", icon: "rectangle.fill")

                HStack(spacing: 12) {
                    IndustrialButton(title: "Connect", icon: "bolt.fill", style: .primary) {}
                    IndustrialButton(title: "Settings", icon: "gearshape", style: .secondary) {}
                    IndustrialButton(title: "Delete", style: .danger) {}
                }

                HStack(spacing: 12) {
                    IndustrialButton(title: "Small", size: .small, action: {})
                    IndustrialButton(title: "Regular", size: .regular, action: {})
                    IndustrialButton(title: "Large", size: .large, action: {})
                }
            }
            .padding()
            .machinedSurface()

            // Card
            IndustrialCard {
                HStack {
                    StatusLED(status: .connected, size: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("devbox.local")
                            .font(.willoMono(.headline, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("user@devbox • zellij")
                            .font(.willoCaption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    IndustrialIconButton(icon: "chevron.right") {}
                }
            }

            // Icon Buttons
            VStack(alignment: .leading, spacing: 16) {
                IndustrialSectionHeader(title: "Icon Buttons", icon: "square.grid.2x2")

                HStack(spacing: 8) {
                    IndustrialIconButton(icon: "command", isActive: true) {}
                    IndustrialIconButton(icon: "gearshape") {}
                    IndustrialIconButton(icon: "xmark.circle") {}
                    IndustrialIconButton(icon: "bolt.fill", activeColor: .terminalGreen) {}
                }
            }
            .padding()
            .machinedSurface()
        }
        .padding(24)
    }
    .background(Color.machineDark)
    .preferredColorScheme(.dark)
}
#endif
