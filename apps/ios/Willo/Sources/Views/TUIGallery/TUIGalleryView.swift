import SwiftUI

/// Main gallery view for browsing and launching TUI applications
struct TUIGalleryView: View {
    @StateObject private var store = TUIAppStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Callback when user wants to launch an app
    var onLaunch: ((TUIApp) -> Void)?

    /// Callback when user wants to install an app
    var onInstall: ((TUIApp) -> Void)?

    @State private var selectedApp: TUIApp?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category tabs
                categoryTabs

                // Search bar
                searchBar

                // App grid
                ScrollView {
                    if store.selectedCategory == nil {
                        // Show all categories
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(TUICategory.allCases) { category in
                                if let apps = store.appsByCategory[category], !apps.isEmpty {
                                    categorySection(category: category, apps: apps)
                                }
                            }
                        }
                        .padding()
                    } else {
                        // Show filtered apps in grid
                        appGrid(apps: store.filteredApps)
                            .padding()
                    }
                }
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("TUI Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedApp) { app in
                TUIAppDetailView(
                    app: app,
                    installState: store.installState(for: app),
                    onLaunch: {
                        dismiss()
                        onLaunch?(app)
                    },
                    onInstall: {
                        onInstall?(app)
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // All tab
                categoryTab(title: "All", icon: "square.grid.2x2", isSelected: store.selectedCategory == nil) {
                    store.selectedCategory = nil
                }

                ForEach(TUICategory.allCases) { category in
                    categoryTab(
                        title: category.rawValue,
                        icon: category.icon,
                        isSelected: store.selectedCategory == category
                    ) {
                        store.selectedCategory = category
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func categoryTab(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color(UIColor.tertiarySystemBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search apps...", text: $store.searchQuery)
                .textFieldStyle(.plain)
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func categorySection(category: TUICategory, apps: [TUIApp]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: category.icon)
                    .foregroundColor(.accentColor)
                Text(category.rawValue)
                    .font(.title2.bold())
                Spacer()
                Button {
                    store.selectedCategory = category
                } label: {
                    Text("See All")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(apps.prefix(6)) { app in
                        TUIAppCard(
                            app: app,
                            installState: store.installState(for: app),
                            onTap: { selectedApp = app }
                        )
                        .frame(width: 160)
                    }
                }
            }
        }
    }

    private func appGrid(apps: [TUIApp]) -> some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)
        ], spacing: 16) {
            ForEach(apps) { app in
                TUIAppCard(
                    app: app,
                    installState: store.installState(for: app),
                    onTap: { selectedApp = app }
                )
            }
        }
    }
}

// MARK: - App Card

struct TUIAppCard: View {
    let app: TUIApp
    let installState: TUIAppInstallState
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: 8) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.15))
                    Image(systemName: app.displayIcon)
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }
                .frame(height: 64)

                // Name
                Text(app.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                // Description
                Text(app.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                // Install state indicator
                HStack {
                    switch installState {
                    case .installed:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    case .checking:
                        ProgressView()
                            .scaleEffect(0.7)
                    case .notInstalled:
                        Label("Not Installed", systemImage: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    default:
                        EmptyView()
                    }
                    Spacer()
                }
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Detail View

struct TUIAppDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let app: TUIApp
    let installState: TUIAppInstallState
    var onLaunch: (() -> Void)?
    var onInstall: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.accentColor.opacity(0.15))
                            Image(systemName: app.displayIcon)
                                .font(.system(size: 40))
                                .foregroundColor(.accentColor)
                        }
                        .frame(width: 80, height: 80)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.title.bold())
                            Text(app.category.rawValue)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    // Description
                    Text(app.description)
                        .font(.body)

                    // Action buttons
                    HStack(spacing: 12) {
                        Button {
                            onLaunch?()
                        } label: {
                            Label("Launch", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }

                        if installState == .notInstalled {
                            Button {
                                onInstall?()
                            } label: {
                                Label("Install", systemImage: "arrow.down.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                        }
                    }

                    // Command info
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Commands")
                            .font(.headline)

                        commandRow(title: "Launch", command: app.launchCommand)
                        commandRow(title: "Install", command: app.installCommand)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)

                    // Website link
                    if let website = app.website, let url = URL(string: website) {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "safari")
                                Text("Visit Website")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }

                    Spacer()
                }
                .padding()
            }
            .background(Color(UIColor.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(command)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.tertiarySystemBackground))
                .cornerRadius(8)
        }
    }
}

// MARK: - Preview

#Preview {
    TUIGalleryView()
}
