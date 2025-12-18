import SwiftUI

/// Demo terminal view for testing Ghostty rendering with direct data feed
///
/// This view creates a Ghostty surface and feeds static ANSI data to validate
/// the Metal rendering pipeline without requiring network connectivity.
struct TerminalDemoView: View {
    /// Use shared app manager to avoid StateObject recreation issues
    private var appManager: GhosttyAppManager { AppServices.shared.sessionManager.appManager }
    @State private var surface: GhosttySurface?
    @State private var initError: String?

    /// ANSI test sequences to render
    private let testSequences: [(String, String)] = [
        ("Clear + Welcome", "\u{1B}[2J\u{1B}[H\u{1B}[1;32mWillo Terminal\u{1B}[0m - Ghostty Direct Feed Test\r\n\r\n"),
        ("Colors", "\u{1B}[31mRed \u{1B}[32mGreen \u{1B}[33mYellow \u{1B}[34mBlue \u{1B}[35mMagenta \u{1B}[36mCyan\u{1B}[0m\r\n"),
        ("Bold/Dim", "\u{1B}[1mBold\u{1B}[0m \u{1B}[2mDim\u{1B}[0m \u{1B}[3mItalic\u{1B}[0m \u{1B}[4mUnderline\u{1B}[0m\r\n"),
        ("256 Colors", generateColorBar()),
        ("Prompt", "\r\n\u{1B}[1;34muser@server\u{1B}[0m:\u{1B}[1;36m~/code/willo\u{1B}[0m$ "),
        ("Cursor", "\u{1B}[5m▌\u{1B}[0m")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Terminal view or status
            if let error = initError {
                // Error state - Ghostty init failed
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                            .padding(.top, 40)

                        Text("Ghostty Initialization")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 12) {
                            InfoRow(label: "Status", value: "Not Ready")
                            InfoRow(label: "Error", value: error)
                            InfoRow(label: "App State", value: appManager.state.rawValue)
                        }
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Status:")
                                .font(.headline)
                                .foregroundColor(.white)

                            Text("• ghostty_init() - Working")
                                .foregroundColor(.green)
                            Text("• ghostty_config_new() - Working")
                                .foregroundColor(.green)
                            Text("• ghostty_app_new() - Working")
                                .foregroundColor(.green)
                            Text("• ghostty_surface_new() - Requires real device")
                                .foregroundColor(.orange)

                            Text("\niOS Simulator Limitation:")
                                .font(.headline)
                                .foregroundColor(.orange)
                                .padding(.top, 8)

                            Text("Ghostty's Metal renderer uses APIs not available on iOS Simulator. Connect a real iPad to test terminal rendering.")

                            Text("\nDirect Feed API:")
                                .font(.headline)
                                .foregroundColor(.green)
                                .padding(.top, 8)

                            Text("feedData() method is ready. Once running on real hardware, ANSI data will render through Ghostty's Metal pipeline.")
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)

                        Spacer()
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else if let surface = surface {
                // Terminal ready
                GhosttyTerminalView(surface: surface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Initializing Ghostty...")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("App State: \(appManager.state.rawValue)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }

            // Control panel
            VStack(spacing: 12) {
                Text("Direct Feed Test Controls")
                    .font(.headline)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(testSequences, id: \.0) { name, sequence in
                            Button(name) {
                                feedSequence(sequence)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(surface == nil)
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 16) {
                    Button("Clear Screen") {
                        feedSequence("\u{1B}[2J\u{1B}[H")
                    }
                    .buttonStyle(.bordered)
                    .disabled(surface == nil)

                    Button("Run All Tests") {
                        runAllTests()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(surface == nil)

                    Button("Shell Simulation") {
                        simulateShell()
                    }
                    .buttonStyle(.bordered)
                    .disabled(surface == nil)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Terminal Demo")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            initializeGhostty()
        }
        .onChange(of: appManager.state) { _, newState in
            if newState == .ready && surface == nil {
                createSurface()
            } else if newState == .error {
                initError = "Ghostty app failed to initialize"
            }
        }
    }

    private func initializeGhostty() {
        switch appManager.state {
        case .ready:
            createSurface()
        case .error:
            initError = "Ghostty app failed to initialize"
        case .loading:
            // Wait for onChange to handle it
            break
        }
    }

    private func createSurface() {
        #if targetEnvironment(simulator)
        // Skip surface creation on simulator - Ghostty's Metal renderer
        // uses APIs not available on iOS Simulator
        initError = "Simulator: Metal renderer requires real device"
        return
        #else
        let newSurface = GhosttySurface(app: appManager)
        self.surface = newSurface

        // Run initial tests after a short delay to allow view to appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            runAllTests()
        }
        #endif
    }

    private func feedSequence(_ sequence: String) {
        surface?.feedString(sequence)
    }

    private func runAllTests() {
        guard let surface = surface else { return }
        var delay: Double = 0
        for (_, sequence) in testSequences {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                surface.feedString(sequence)
            }
            delay += 0.1
        }
    }

    private func simulateShell() {
        guard let surface = surface else { return }

        // Simulate a shell session with typical commands
        let commands = [
            "\u{1B}[2J\u{1B}[H",  // Clear
            "\u{1B}[1;32mwillo\u{1B}[0m \u{1B}[1;34m~/code\u{1B}[0m $ ",
            "ls -la\r\n",
            "\u{1B}[1;34mdrwxr-xr-x\u{1B}[0m  5 user staff  160 Dec 17 10:30 \u{1B}[1;34m.\u{1B}[0m\r\n",
            "\u{1B}[1;34mdrwxr-xr-x\u{1B}[0m 12 user staff  384 Dec 17 09:15 \u{1B}[1;34m..\u{1B}[0m\r\n",
            "-rw-r--r--  1 user staff  2048 Dec 17 10:30 Package.swift\r\n",
            "\u{1B}[1;34mdrwxr-xr-x\u{1B}[0m  8 user staff  256 Dec 17 10:25 \u{1B}[1;34mSources\u{1B}[0m\r\n",
            "-rw-r--r--  1 user staff   512 Dec 17 09:00 README.md\r\n",
            "\r\n\u{1B}[1;32mwillo\u{1B}[0m \u{1B}[1;34m~/code\u{1B}[0m $ ",
            "echo \"Hello from Willo!\"\r\n",
            "Hello from Willo!\r\n",
            "\u{1B}[1;32mwillo\u{1B}[0m \u{1B}[1;34m~/code\u{1B}[0m $ \u{1B}[5m▌\u{1B}[0m"
        ]

        var delay: Double = 0
        for cmd in commands {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                surface.feedString(cmd)
            }
            delay += 0.15
        }
    }
}

/// Generate a 256-color bar ANSI sequence
private func generateColorBar() -> String {
    var result = "\r\n"
    // 16 standard colors
    for i in 0..<16 {
        result += "\u{1B}[48;5;\(i)m  "
    }
    result += "\u{1B}[0m\r\n"

    // 216 color cube (subset)
    for row in 0..<3 {
        for i in 0..<36 {
            let colorIndex = 16 + row * 36 + i
            result += "\u{1B}[48;5;\(colorIndex)m "
        }
        result += "\u{1B}[0m\r\n"
    }

    // Grayscale
    for i in 232..<256 {
        result += "\u{1B}[48;5;\(i)m "
    }
    result += "\u{1B}[0m\r\n"

    return result
}

// MARK: - Helper Views

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .foregroundColor(.white)
                .lineLimit(2)
        }
    }
}

#Preview {
    NavigationStack {
        TerminalDemoView()
    }
}
