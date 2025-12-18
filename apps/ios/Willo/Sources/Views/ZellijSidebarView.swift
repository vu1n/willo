import SwiftUI

struct ZellijSidebarView: View {
    let session: ZellijSession?
    @State private var showingLayoutPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Zellij")
                    .font(.headline)

                Spacer()

                Menu {
                    Button("New Tab", systemImage: "plus.square") {
                        // TODO: Send new tab command
                    }
                    Button("New Pane", systemImage: "rectangle.split.2x1") {
                        // TODO: Send new pane command
                    }
                    Divider()
                    Button("Apply Layout...", systemImage: "rectangle.3.group") {
                        showingLayoutPicker = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding()
            .background(.bar)

            Divider()

            if let session = session {
                // Session content
                List {
                    ForEach(session.tabs) { tab in
                        TabSection(tab: tab, isActive: tab.id == session.activeTabIndex)
                    }
                }
                .listStyle(.plain)
            } else {
                // Not connected or no zellij
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "wifi.slash")
                } description: {
                    Text("Connect to a server with Zellij to see session structure")
                }
            }
        }
        .sheet(isPresented: $showingLayoutPicker) {
            LayoutPickerView()
        }
    }
}

struct TabSection: View {
    let tab: ZellijTab
    let isActive: Bool

    var body: some View {
        Section {
            ForEach(tab.panes) { pane in
                PaneRow(pane: pane)
            }
        } header: {
            HStack {
                Image(systemName: isActive ? "square.fill" : "square")
                    .font(.caption)
                    .foregroundStyle(isActive ? .blue : .secondary)

                Text(tab.name)
                    .fontWeight(isActive ? .semibold : .regular)

                Spacer()

                Text("\(tab.panes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PaneRow: View {
    let pane: ZellijPane

    var body: some View {
        HStack(spacing: 8) {
            // Focus indicator
            Circle()
                .fill(pane.isFocused ? Color.blue : Color.clear)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.subheadline)
                    .lineLimit(1)

                if let command = pane.command {
                    Text(command)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Status indicator
            if let exitCode = pane.exitCode {
                Text("Exit \(exitCode)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(exitCode == 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .clipShape(Capsule())
            } else if pane.isFloating {
                Image(systemName: "square.on.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            // TODO: Focus this pane
        }
    }
}

struct LayoutPickerView: View {
    @Environment(\.dismiss) var dismiss

    let layouts = [
        ("Agent Swarm", "Agent panes with editor, logs, tests"),
        ("Ops", "Logs, monitoring, deploy"),
        ("Research", "REPL, notes, browser"),
        ("Default", "Single pane layout"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(layouts, id: \.0) { layout in
                    Button {
                        // TODO: Apply layout
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(layout.0)
                                .font(.headline)
                            Text(layout.1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Apply Layout")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ZellijSidebarView(session: ZellijSession(
        id: "willo/dev/main",
        tabs: [
            ZellijTab(
                id: 0,
                name: "Editor",
                panes: [
                    ZellijPane(id: 0, title: "nvim", command: "nvim .", isFloating: false, isFocused: true),
                    ZellijPane(id: 1, title: "logs", command: "tail -f app.log", isFloating: false, isFocused: false),
                ],
                activePaneId: 0,
                isFullscreen: false
            ),
            ZellijTab(
                id: 1,
                name: "Tests",
                panes: [
                    ZellijPane(id: 2, title: "test runner", command: "npm test", isFloating: false, exitCode: 0, isFocused: false),
                ],
                activePaneId: 2,
                isFullscreen: false
            ),
        ],
        activeTabIndex: 0
    ))
    .frame(width: 280)
}
