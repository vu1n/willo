import SwiftUI

/// Quick actions overlay for zellij pane navigation
/// Activated via 3-finger tap on the terminal
struct ZellijQuickActionsOverlay: View {
    let onAction: (ZellijAction) -> Void
    let onDismiss: () -> Void

    @State private var activeDirection: Direction?

    var body: some View {
        ZStack {
            // Dimmed backdrop - tap to dismiss
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 24) {
                // Title
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.terminalCyan)

                    Text("FOCUS PANE")
                        .font(.willoSectionHeader)
                        .tracking(2)
                        .foregroundStyle(Color.textSecondary)
                }

                // D-Pad for pane navigation
                DPadControl(activeDirection: $activeDirection) { direction in
                    onAction(.moveFocus(direction))
                }

                // Quick actions row
                HStack(spacing: 16) {
                    QuickActionButton(
                        icon: "plus.rectangle",
                        label: "New Pane",
                        color: .terminalGreen
                    ) {
                        onAction(.newPane)
                    }

                    QuickActionButton(
                        icon: "arrow.up.left.and.arrow.down.right",
                        label: "Fullscreen",
                        color: .terminalAmber
                    ) {
                        onAction(.toggleFullscreen)
                    }

                    QuickActionButton(
                        icon: "xmark.rectangle",
                        label: "Close",
                        color: .terminalRed
                    ) {
                        onAction(.closePane)
                    }
                }

                // Dismiss hint
                Text("Tap anywhere to dismiss")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(32)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.machineGray.opacity(0.95))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.terminalCyan.opacity(0.3), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: - Zellij Actions

enum ZellijAction {
    case moveFocus(Direction)
    case newPane
    case closePane
    case toggleFullscreen
    case nextTab
    case previousTab

    /// The zellij CLI command to execute
    var command: String {
        switch self {
        case .moveFocus(let direction):
            return "zellij action move-focus \(direction.rawValue)"
        case .newPane:
            return "zellij action new-pane"
        case .closePane:
            return "zellij action close-pane"
        case .toggleFullscreen:
            return "zellij action toggle-fullscreen-focus"
        case .nextTab:
            return "zellij action go-to-next-tab"
        case .previousTab:
            return "zellij action go-to-previous-tab"
        }
    }
}

enum Direction: String, CaseIterable {
    case up, down, left, right

    var icon: String {
        switch self {
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        }
    }
}

// MARK: - D-Pad Control

struct DPadControl: View {
    @Binding var activeDirection: Direction?
    let onDirection: (Direction) -> Void

    private let buttonSize: CGFloat = 56
    private let spacing: CGFloat = 4

    var body: some View {
        VStack(spacing: spacing) {
            // Up
            DPadButton(
                direction: .up,
                size: buttonSize,
                isActive: activeDirection == .up
            ) {
                triggerDirection(.up)
            }

            HStack(spacing: spacing) {
                // Left
                DPadButton(
                    direction: .left,
                    size: buttonSize,
                    isActive: activeDirection == .left
                ) {
                    triggerDirection(.left)
                }

                // Center (decorative)
                ZStack {
                    Circle()
                        .fill(Color.machineBlack)
                        .frame(width: buttonSize, height: buttonSize)

                    Circle()
                        .strokeBorder(Color.bezelLight.opacity(0.3), lineWidth: 1)
                        .frame(width: buttonSize, height: buttonSize)

                    // Inner LED indicator
                    Circle()
                        .fill(Color.terminalCyan.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .blur(radius: 4)

                    Circle()
                        .fill(Color.terminalCyan)
                        .frame(width: 6, height: 6)
                }

                // Right
                DPadButton(
                    direction: .right,
                    size: buttonSize,
                    isActive: activeDirection == .right
                ) {
                    triggerDirection(.right)
                }
            }

            // Down
            DPadButton(
                direction: .down,
                size: buttonSize,
                isActive: activeDirection == .down
            ) {
                triggerDirection(.down)
            }
        }
    }

    private func triggerDirection(_ direction: Direction) {
        // Visual feedback
        withAnimation(.easeOut(duration: 0.1)) {
            activeDirection = direction
        }

        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        // Execute action
        onDirection(direction)

        // Reset active state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.1)) {
                activeDirection = nil
            }
        }
    }
}

struct DPadButton: View {
    let direction: Direction
    let size: CGFloat
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Button background
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                isActive ? Color.terminalCyan.opacity(0.4) : Color.bezelGray,
                                isActive ? Color.terminalCyan.opacity(0.2) : Color.machineGray
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size, height: size)

                // Border
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.terminalCyan.opacity(0.8) : Color.bezelLight.opacity(0.4),
                        lineWidth: isActive ? 2 : 1
                    )
                    .frame(width: size, height: size)

                // Icon
                Image(systemName: direction.icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isActive ? Color.terminalCyan : Color.textPrimary)

                // Active glow
                if isActive {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.terminalCyan.opacity(0.2))
                        .frame(width: size, height: size)
                        .blur(radius: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isActive ? 0.95 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    // Background
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.machineBlack)
                        .frame(width: 52, height: 52)

                    // Border
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(color.opacity(0.4), lineWidth: 1)
                        .frame(width: 52, height: 52)

                    // Icon
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(color)
                }

                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Floating D-Pad (Minimal Version)

/// Compact floating D-pad that can be shown without full overlay
struct FloatingDPad: View {
    let onDirection: (Direction) -> Void
    let onDismiss: () -> Void

    @State private var activeDirection: Direction?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 2) {
            // Drag handle
            Capsule()
                .fill(Color.textTertiary.opacity(0.5))
                .frame(width: 32, height: 4)
                .padding(.bottom, 4)

            // Compact D-pad
            VStack(spacing: 2) {
                DPadMiniButton(direction: .up, isActive: activeDirection == .up) {
                    triggerDirection(.up)
                }

                HStack(spacing: 2) {
                    DPadMiniButton(direction: .left, isActive: activeDirection == .left) {
                        triggerDirection(.left)
                    }

                    // Center dismiss button
                    Button(action: onDismiss) {
                        ZStack {
                            Circle()
                                .fill(Color.machineBlack)
                                .frame(width: 40, height: 40)

                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    DPadMiniButton(direction: .right, isActive: activeDirection == .right) {
                        triggerDirection(.right)
                    }
                }

                DPadMiniButton(direction: .down, isActive: activeDirection == .down) {
                    triggerDirection(.down)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.machineGray.opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.terminalCyan.opacity(0.3), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.3), radius: 10)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
        )
    }

    private func triggerDirection(_ direction: Direction) {
        withAnimation(.easeOut(duration: 0.1)) {
            activeDirection = direction
        }

        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()

        onDirection(direction)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.1)) {
                activeDirection = nil
            }
        }
    }
}

struct DPadMiniButton: View {
    let direction: Direction
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.terminalCyan.opacity(0.3) : Color.machineBlack)
                    .frame(width: 40, height: 40)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.terminalCyan : Color.bezelLight.opacity(0.3),
                        lineWidth: 1
                    )
                    .frame(width: 40, height: 40)

                Image(systemName: direction.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isActive ? Color.terminalCyan : Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Three Finger Tap Gesture

/// UIKit-based 3-finger tap gesture recognizer wrapped for SwiftUI
struct ThreeFingerTapGestureView: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap)
        )
        tapGesture.numberOfTouchesRequired = 3
        tapGesture.numberOfTapsRequired = 1
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended {
                action()
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Quick Actions Overlay") {
    ZStack {
        Color.machineBlack.ignoresSafeArea()

        ZellijQuickActionsOverlay(
            onAction: { action in
                print("Action: \(action.command)")
            },
            onDismiss: {
                print("Dismissed")
            }
        )
    }
}

#Preview("Floating D-Pad") {
    ZStack {
        Color.machineBlack.ignoresSafeArea()

        FloatingDPad(
            onDirection: { direction in
                print("Direction: \(direction)")
            },
            onDismiss: {
                print("Dismissed")
            }
        )
    }
}
#endif
