import SwiftUI

struct CommandPaletteView: View {
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var filteredCommands: [PaletteCommand] {
        if searchText.isEmpty {
            return PaletteCommand.allCommands
        }
        return PaletteCommand.allCommands.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.keywords.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search commands...", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onSubmit {
                            if let first = filteredCommands.first {
                                execute(first)
                            }
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(.bar)

                Divider()

                // Commands list
                List {
                    ForEach(groupedCommands.keys.sorted(), id: \.self) { category in
                        Section(category) {
                            ForEach(groupedCommands[category] ?? []) { command in
                                CommandRow(command: command) {
                                    execute(command)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Command Palette")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            isSearchFocused = true
        }
        .presentationDetents([.medium, .large])
    }

    private var groupedCommands: [String: [PaletteCommand]] {
        Dictionary(grouping: filteredCommands, by: { $0.category })
    }

    private func execute(_ command: PaletteCommand) {
        command.action()
        dismiss()
    }
}

struct CommandRow: View {
    let command: PaletteCommand
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: command.icon)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)

                    if let subtitle = command.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let category: String
    let shortcut: String?
    let keywords: [String]
    let action: () -> Void

    static let allCommands: [PaletteCommand] = [
        // Workspace
        PaletteCommand(
            title: "New Workspace",
            subtitle: "Open a new terminal tab",
            icon: "plus.square",
            category: "Workspace",
            shortcut: "⌘T",
            keywords: ["tab", "new", "create"],
            action: { NotificationCenter.default.post(name: .newWorkspace, object: nil) }
        ),
        PaletteCommand(
            title: "Close Workspace",
            subtitle: "Close current terminal tab",
            icon: "xmark.square",
            category: "Workspace",
            shortcut: "⌘W",
            keywords: ["close", "tab"],
            action: { NotificationCenter.default.post(name: .closeWorkspace, object: nil) }
        ),

        // Connection
        PaletteCommand(
            title: "Reconnect",
            subtitle: "Reconnect to server",
            icon: "arrow.clockwise",
            category: "Connection",
            shortcut: "⌘R",
            keywords: ["connect", "refresh"],
            action: { NotificationCenter.default.post(name: .reconnect, object: nil) }
        ),
        PaletteCommand(
            title: "Disconnect",
            subtitle: "Close connection",
            icon: "wifi.slash",
            category: "Connection",
            shortcut: nil,
            keywords: ["close", "stop"],
            action: { NotificationCenter.default.post(name: .disconnect, object: nil) }
        ),

        // Zellij
        PaletteCommand(
            title: "New Pane",
            subtitle: "Create new Zellij pane",
            icon: "rectangle.split.2x1",
            category: "Zellij",
            shortcut: nil,
            keywords: ["split", "pane", "zellij"],
            action: { NotificationCenter.default.post(name: .zellijNewPane, object: nil) }
        ),
        PaletteCommand(
            title: "New Tab",
            subtitle: "Create new Zellij tab",
            icon: "plus.rectangle.on.rectangle",
            category: "Zellij",
            shortcut: nil,
            keywords: ["tab", "zellij"],
            action: { NotificationCenter.default.post(name: .zellijNewTab, object: nil) }
        ),
        PaletteCommand(
            title: "Apply Layout",
            subtitle: "Apply a workspace layout",
            icon: "rectangle.3.group",
            category: "Zellij",
            shortcut: nil,
            keywords: ["layout", "template", "swarm"],
            action: { NotificationCenter.default.post(name: .zellijApplyLayout, object: nil) }
        ),

        // Edit
        PaletteCommand(
            title: "Copy",
            subtitle: "Copy selection to clipboard",
            icon: "doc.on.doc",
            category: "Edit",
            shortcut: "⌘C",
            keywords: ["copy", "clipboard"],
            action: { NotificationCenter.default.post(name: .copy, object: nil) }
        ),
        PaletteCommand(
            title: "Paste",
            subtitle: "Paste from clipboard",
            icon: "doc.on.clipboard",
            category: "Edit",
            shortcut: "⌘V",
            keywords: ["paste", "clipboard"],
            action: { NotificationCenter.default.post(name: .paste, object: nil) }
        ),
        PaletteCommand(
            title: "Find in Scrollback",
            subtitle: "Search terminal history",
            icon: "magnifyingglass",
            category: "Edit",
            shortcut: "⌘F",
            keywords: ["search", "find", "history"],
            action: { NotificationCenter.default.post(name: .find, object: nil) }
        ),
    ]
}

extension Notification.Name {
    static let newWorkspace = Notification.Name("newWorkspace")
    static let closeWorkspace = Notification.Name("closeWorkspace")
    static let reconnect = Notification.Name("reconnect")
    static let disconnect = Notification.Name("disconnect")
    static let zellijNewPane = Notification.Name("zellijNewPane")
    static let zellijNewTab = Notification.Name("zellijNewTab")
    static let zellijApplyLayout = Notification.Name("zellijApplyLayout")
    static let copy = Notification.Name("copy")
    static let paste = Notification.Name("paste")
    static let find = Notification.Name("find")
}

#Preview {
    CommandPaletteView()
}
