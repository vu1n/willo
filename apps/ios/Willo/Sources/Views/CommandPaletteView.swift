import SwiftUI

/// Zellij command palette for touch-friendly multiplexer control
///
/// Displays a searchable list of zellij commands that inject keybindings
/// into the terminal session when selected.
struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    /// Callback to send keybinding data to the terminal
    let onSendKeys: (Data) -> Void

    /// All available zellij commands (using zellij default keybindings)
    /// Ctrl+P = Pane mode (\u{10}), Ctrl+T = Tab mode (\u{14}), Ctrl+S = Scroll mode (\u{13}), Ctrl+O = Session mode (\u{0F})
    private let commands: [ZellijCommand] = [
        // Pane management (Ctrl+P mode)
        ZellijCommand(name: "New Pane Right", icon: "rectangle.righthalf.inset.filled", keys: "\u{10}n", category: .panes),
        ZellijCommand(name: "New Pane Down", icon: "rectangle.bottomhalf.inset.filled", keys: "\u{10}d", category: .panes),
        ZellijCommand(name: "Close Pane", icon: "xmark.square", keys: "\u{10}x", category: .panes),
        ZellijCommand(name: "Toggle Fullscreen", icon: "arrow.up.left.and.arrow.down.right", keys: "\u{10}f", category: .panes),
        ZellijCommand(name: "Toggle Floating", icon: "pip.enter", keys: "\u{10}w", category: .panes),
        ZellijCommand(name: "Toggle Embed", icon: "pip.exit", keys: "\u{10}e", category: .panes),
        ZellijCommand(name: "Focus Left", icon: "arrow.left", keys: "\u{10}h", category: .panes),
        ZellijCommand(name: "Focus Down", icon: "arrow.down", keys: "\u{10}j", category: .panes),
        ZellijCommand(name: "Focus Up", icon: "arrow.up", keys: "\u{10}k", category: .panes),
        ZellijCommand(name: "Focus Right", icon: "arrow.right", keys: "\u{10}l", category: .panes),

        // Tab management (Ctrl+T mode)
        ZellijCommand(name: "New Tab", icon: "plus.rectangle", keys: "\u{14}n", category: .tabs),
        ZellijCommand(name: "Close Tab", icon: "xmark.rectangle", keys: "\u{14}x", category: .tabs),
        ZellijCommand(name: "Next Tab", icon: "chevron.right.2", keys: "\u{14}l", category: .tabs),
        ZellijCommand(name: "Previous Tab", icon: "chevron.left.2", keys: "\u{14}h", category: .tabs),
        ZellijCommand(name: "Rename Tab", icon: "pencil", keys: "\u{14}r", category: .tabs),
        ZellijCommand(name: "Go to Tab 1", icon: "1.square", keys: "\u{14}1", category: .tabs),
        ZellijCommand(name: "Go to Tab 2", icon: "2.square", keys: "\u{14}2", category: .tabs),
        ZellijCommand(name: "Go to Tab 3", icon: "3.square", keys: "\u{14}3", category: .tabs),

        // Session management (Ctrl+O mode)
        ZellijCommand(name: "Detach", icon: "eject", keys: "\u{0F}d", category: .session),
        ZellijCommand(name: "Session Manager", icon: "list.bullet.rectangle", keys: "\u{0F}w", category: .session),
        ZellijCommand(name: "Quit Zellij", icon: "power", keys: "\u{11}q", category: .session),  // Ctrl+Q

        // Scroll/Copy mode (Ctrl+S mode)
        ZellijCommand(name: "Scroll Mode", icon: "scroll", keys: "\u{13}s", category: .scroll),
        ZellijCommand(name: "Search", icon: "magnifyingglass", keys: "\u{13}/", category: .scroll),
    ]

    /// Filtered commands based on search text
    private var filteredCommands: [ZellijCommand] {
        if searchText.isEmpty {
            return commands
        }
        let search = searchText.lowercased()
        return commands.filter { cmd in
            cmd.name.lowercased().contains(search) ||
            cmd.category.rawValue.lowercased().contains(search)
        }
    }

    /// Commands grouped by category
    private var groupedCommands: [(category: ZellijCommand.Category, commands: [ZellijCommand])] {
        let filtered = filteredCommands
        let grouped = Dictionary(grouping: filtered, by: { $0.category })
        return ZellijCommand.Category.allCases.compactMap { category in
            guard let commands = grouped[category], !commands.isEmpty else { return nil }
            return (category, commands)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ZELLIJ COMMANDS")
                    .font(.willoSectionHeader)
                    .tracking(2)
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 28, height: 28)
                        .background {
                            Circle()
                                .fill(Color.bezelGray)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Search bar
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textTertiary)

                TextField("Search commands...", text: $searchText)
                    .font(.willoMono(.body))
                    .foregroundStyle(Color.textPrimary)
                    .focused($isSearchFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .recessedPanel(cornerRadius: 10)
            .padding(.horizontal, 20)

            // Divider
            Rectangle()
                .fill(Color.bezelLight.opacity(0.2))
                .frame(height: 1)
                .padding(.top, 16)

            // Command list
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(groupedCommands, id: \.category) { group in
                        Section {
                            ForEach(group.commands) { command in
                                CommandRow(command: command) {
                                    executeCommand(command)
                                }
                            }
                        } header: {
                            CommandSectionHeader(category: group.category)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color.machineDark)
        .onAppear {
            isSearchFocused = true
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color.machineDark)
        .preferredColorScheme(.dark)
    }

    /// Zellij mode prefixes (control characters)
    private static let modePrefixes: Set<Character> = [
        "\u{10}",  // Ctrl+P (Pane mode)
        "\u{14}",  // Ctrl+T (Tab mode)
        "\u{13}",  // Ctrl+S (Scroll mode)
        "\u{0F}",  // Ctrl+O (Session mode)
        "\u{11}",  // Ctrl+Q (Quit - not a mode but handled same way)
    ]

    private func executeCommand(_ command: ZellijCommand) {
        // Zellij uses modal keybindings: first send the mode key,
        // wait briefly, then send the action key
        let keys = command.keys

        // Check if this is a modal command (starts with a mode prefix)
        if let firstChar = keys.first, Self.modePrefixes.contains(firstChar) && keys.count > 1 {
            // Send mode key first
            let modeKey = String(keys.prefix(1))
            if let modeData = modeKey.data(using: .utf8) {
                onSendKeys(modeData)
            }

            // Send action key after a brief delay for zellij to process mode switch
            let actionKeys = String(keys.dropFirst(1))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [onSendKeys] in
                if let actionData = actionKeys.data(using: .utf8) {
                    onSendKeys(actionData)
                }
            }
        } else {
            // Non-modal command - send directly
            if let data = keys.data(using: .utf8) {
                onSendKeys(data)
            }
        }
        dismiss()
    }
}

// MARK: - Command Section Header

private struct CommandSectionHeader: View {
    let category: ZellijCommand.Category

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(category.color)

            Text(category.displayName.uppercased())
                .font(.willoSectionHeader)
                .tracking(1)
                .foregroundStyle(Color.textTertiary)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.machineGray)
    }
}

// MARK: - Command Row

private struct CommandRow: View {
    let command: ZellijCommand
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Icon
                Image(systemName: command.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(command.category.color)
                    .frame(width: 24)

                // Name
                Text(command.name)
                    .font(.willoMono(.body))
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                // Keybinding badge
                KeybindingBadge(keys: command.keybindingDisplay)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isPressed ? Color.bezelGray : Color.clear)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}

// MARK: - Keybinding Badge

private struct KeybindingBadge: View {
    let keys: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys.split(separator: " "), id: \.self) { part in
                Text(String(part))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.terminalCyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.machineBlack)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.terminalCyan.opacity(0.3), lineWidth: 1)
                            }
                    }
            }
        }
    }
}

// MARK: - Zellij Command Model

struct ZellijCommand: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let keys: String  // Raw keybinding to send (e.g., "\u{10}" for Ctrl+P)
    let category: Category

    enum Category: String, CaseIterable {
        case panes
        case tabs
        case session
        case scroll

        var displayName: String {
            switch self {
            case .panes: return "Panes"
            case .tabs: return "Tabs"
            case .session: return "Session"
            case .scroll: return "Scroll & Copy"
            }
        }

        var icon: String {
            switch self {
            case .panes: return "rectangle.split.2x2"
            case .tabs: return "rectangle.stack"
            case .session: return "server.rack"
            case .scroll: return "scroll"
            }
        }

        var color: Color {
            switch self {
            case .panes: return .terminalCyan
            case .tabs: return .terminalAmber
            case .session: return .terminalGreen
            case .scroll: return .terminalBlue
            }
        }
    }

    /// Human-readable keybinding display
    var keybindingDisplay: String {
        // Translate raw keys to readable format
        let display = keys
            .replacingOccurrences(of: "\u{10}", with: "^P ")   // Ctrl+P (Pane mode)
            .replacingOccurrences(of: "\u{14}", with: "^T ")   // Ctrl+T (Tab mode)
            .replacingOccurrences(of: "\u{13}", with: "^S ")   // Ctrl+S (Scroll mode)
            .replacingOccurrences(of: "\u{0F}", with: "^O ")   // Ctrl+O (Session mode)
            .replacingOccurrences(of: "\u{11}", with: "^Q ")   // Ctrl+Q (Quit)
            .replacingOccurrences(of: "\u{1B}[A", with: "Up")
            .replacingOccurrences(of: "\u{1B}[B", with: "Down")
            .replacingOccurrences(of: "\u{1B}[C", with: "Right")
            .replacingOccurrences(of: "\u{1B}[D", with: "Left")
        return display.trimmingCharacters(in: .whitespaces)
    }
}

#if os(iOS)
#Preview {
    CommandPaletteView { data in
        print("Sending: \(data)")
    }
}
#endif
