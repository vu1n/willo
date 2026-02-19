import SwiftUI
import CoreText
import os.log

private let logger = Logger(subsystem: "com.willo.app", category: "Terminal")

struct TerminalWorkspaceView: View {
    let workspace: Workspace
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var layoutStore: LayoutStore
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: TerminalSession?
    @State private var sessionState: SessionState = .disconnected
    @State private var showingSettings = false
    @State private var showingCommandPalette = false
    @State private var showingSaveLayout = false
    @State private var showingTUIGallery = false
    @State private var connectionError: Error?
    @StateObject private var voiceManager = VoiceInputManager()
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Unified status bar
                TerminalStatusBar(
                    workspace: workspace,
                    sessionState: sessionState,
                    voiceManager: voiceManager,
                    onCommandPalette: { showingCommandPalette = true },
                    onTUIApps: { showingTUIGallery = true },
                    onSettings: { showingSettings = true },
                    onDisconnect: { Task { await disconnect() } },
                    onReconnect: { Task { await connect() } },
                    onVoiceText: { text in
                        // Send voice-transcribed text to terminal
                        Task {
                            if let session = session {
                                let data = Data(text.utf8)
                                try? await session.transport.send(data)
                            }
                        }
                    }
                )

                // Zellij tab bar (shows when bridge is streaming)
                if let bridge = sessionStore.getBridge(for: workspace.id) {
                    ZellijTabBar(
                        bridge: bridge,
                        onTabSelect: { tabIndex in
                            Task {
                                try? await bridge.focusTab(tabIndex)
                            }
                        },
                        onNewTab: {
                            Task {
                                try? await bridge.newTab()
                            }
                        }
                    )
                }

                // Terminal view
                TerminalContainerView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Bridge status overlay (plugin install/update prompts)
            if let bridge = sessionStore.getBridge(for: workspace.id) {
                bridgeStatusOverlay(bridge: bridge)
            }

            // Voice transcript HUD - floating above status bar
            VoiceTranscriptHUD(voiceManager: voiceManager) {
                voiceManager.cancelRecording()
            }
            .padding(.bottom, 56) // Above status bar height
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: voiceManager.state)
        }
        .background(Color.machineBlack)
        .sheet(isPresented: $showingSettings) {
            TerminalSettingsSheet()
        }
        .sheet(isPresented: $showingCommandPalette) {
            if let session = session {
                CommandPaletteView(
                    bridge: sessionStore.getBridge(for: workspace.id),
                    onSendKeys: { data in
                        Task {
                            try? await session.transport.send(data)
                        }
                    },
                    onSaveLayout: {
                        showingSaveLayout = true
                    }
                )
            }
        }
        .sheet(isPresented: $showingSaveLayout) {
            if let session = session {
                SaveLayoutSheet { completion in
                    captureLayout(session: session, completion: completion)
                }
            }
        }
        .sheet(isPresented: $showingTUIGallery) {
            TUIGalleryView(
                onLaunch: { app in
                    // Send launch command to terminal
                    Task {
                        if let session = session {
                            let command = app.launchCommand + "\n"
                            if let data = command.data(using: .utf8) {
                                try? await session.transport.send(data)
                            }
                        }
                    }
                },
                onInstall: { app in
                    // Send install command to terminal
                    Task {
                        if let session = session {
                            let command = app.installCommand + "\n"
                            if let data = command.data(using: .utf8) {
                                try? await session.transport.send(data)
                            }
                        }
                    }
                }
            )
        }
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .task {
            await connect()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && oldPhase == .background {
                Task {
                    await reconnectIfNeeded()
                }
            }
        }
        .onChange(of: networkMonitor.isConnected) { wasConnected, isNowConnected in
            if isNowConnected && !wasConnected {
                // Network restored
                Task {
                    await reconnectIfNeeded()
                }
            }
        }
        .alert("Connection Error", isPresented: .init(
            get: { connectionError != nil },
            set: { if !$0 { connectionError = nil } }
        )) {
            Button("Retry") {
                Task { await connect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let error = connectionError {
                Text(error.localizedDescription)
            }
        }
    }

    private func connect() async {
        // Check for cached terminal session first (kept alive from tab switching)
        if let cachedSession = sessionStore.getTerminalSession(for: workspace.id) {
            logger.debug("Reusing cached session for workspace \(workspace.id, privacy: .public)")
            self.session = cachedSession
            sessionState = .connected

            // Send resize in case screen size changed
            let terminalSize = calculateTerminalSize()
            try? await cachedSession.resize(cols: terminalSize.cols, rows: terminalSize.rows)

            // Start bridge if not already active (for cached sessions after app restore)
            if sessionStore.getBridge(for: workspace.id) == nil {
                startBridgeIfNeeded(session: cachedSession)
            }
            return
        }

        // Use connectWithRetry for new connections
        await connectWithRetry(maxAttempts: 3)
    }

    private func connectWithRetry(maxAttempts: Int = 3) async {
        let backoff = ExponentialBackoff()

        for attempt in 1...maxAttempts {
            sessionState = attempt == 1 ? .connecting : .reconnecting(attempt: attempt)

            do {
                let terminalSize = calculateTerminalSize()

                var config = SessionConfig(
                    name: workspace.sessionName,
                    host: workspace.serverProfile.hostname,
                    port: UInt16(workspace.serverProfile.port),
                    username: workspace.serverProfile.username,
                    connectionType: workspace.serverProfile.preferMosh ? .mosh : .ssh,
                    authMethod: workspace.serverProfile.authMethodConfig
                )
                config.terminalCols = terminalSize.cols
                config.terminalRows = terminalSize.rows
                logger.info("Connecting with size: \(terminalSize.cols)x\(terminalSize.rows)")

                let newSession: TerminalSession
                if workspace.serverProfile.preferMosh {
                    newSession = try await sessionManager.createMoshSession(config: config)
                } else {
                    newSession = try await sessionManager.createSession(config: config)
                }

                self.session = newSession
                try await sessionManager.connect(newSession)
                sessionState = .connected

                // Cache the session for tab switching
                sessionStore.setTerminalSession(newSession, for: workspace.id)
                logger.debug("Cached session for workspace \(workspace.id, privacy: .public)")

                // Execute startup command based on profile configuration
                await executeStartupCommand(session: newSession)

                // Send resize after connection to ensure remote session has correct size
                // This is especially important when reconnecting to existing zellij/tmux sessions
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for shell/multiplexer to initialize
                try? await newSession.resize(cols: terminalSize.cols, rows: terminalSize.rows)
                logger.debug("Sent resize after connect: \(terminalSize.cols)x\(terminalSize.rows)")

                // Start Zellij bridge for session observation and control
                startBridgeIfNeeded(session: newSession)

                // Success - return early
                return
            } catch {
                if attempt < maxAttempts {
                    let delay = backoff.delay(for: attempt)
                    logger.warning("Connection attempt \(attempt) failed, retrying in \(delay)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    sessionState = .error(error)
                    self.connectionError = error
                }
            }
        }
    }

    private func executeStartupCommand(session: TerminalSession) async {
        let profile = workspace.serverProfile

        // Only execute if multiplexer is configured
        guard profile.multiplexer != .none else { return }

        // Check if we have a layout to apply
        let willoSession = sessionStore.sessions.first { $0.id == workspace.id }
        let layoutId = willoSession?.layoutId

        // Small delay to let shell initialize
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // If we have a layout, write it to the server first
        var layoutToUse: LayoutTemplate?
        if let layoutId = layoutId {
            // Check built-in layouts first
            if let builtInLayout = LayoutTemplate.builtIn.first(where: { $0.id == layoutId }) {
                layoutToUse = builtInLayout
            }
            // Then check user layouts
            else if let uuid = UUID(uuidString: layoutId),
                    let userLayout = layoutStore.getLayout(uuid) {
                layoutToUse = userLayout.toLayoutTemplate()
            }

            if let layout = layoutToUse, profile.multiplexer == .zellij {
                await writeLayoutToServer(session: session, layout: layout)
            }
        }

        // Determine the command based on session name and profile behavior
        let command: String?
        let sessionName = workspace.sessionName

        if !sessionName.isEmpty {
            if let layout = layoutToUse, profile.multiplexer == .zellij {
                // Use layout with session name (versioned filename for cache invalidation)
                let layoutPath = "/tmp/willo-layout-\(layout.id)-v\(layout.contentHash).kdl"
                command = "zellij --new-session-with-layout \(layoutPath) -s \"\(sessionName)\" 2>/dev/null || zellij attach -c \"\(sessionName)\""
            } else {
                // Standard namedSession behavior
                command = StartupBehavior.namedSession.command(
                    for: profile.multiplexer,
                    sessionName: sessionName
                )
            }
        } else {
            // No session name - fall back to profile's startup behavior
            command = profile.startupBehavior.command(
                for: profile.multiplexer,
                sessionName: nil
            )
        }

        guard let command = command else { return }

        logger.info("Executing startup command: \(command, privacy: .public)")

        // Send command with newline
        let commandData = Data((command + "\n").utf8)
        try? await session.transport.send(commandData)
    }

    /// Write a layout KDL file to the server (only if not already present)
    /// Uses versioned filename based on content hash to handle app updates
    private func writeLayoutToServer(session: TerminalSession, layout: LayoutTemplate) async {
        let layoutPath = "/tmp/willo-layout-\(layout.id)-v\(layout.contentHash).kdl"

        // Only write if file doesn't exist (conditional write)
        // This avoids rewriting on every connect while ensuring updates are applied
        let writeCommand = """
        [ -f \(layoutPath) ] || cat > \(layoutPath) << 'WILLO_LAYOUT_EOF'
        \(layout.kdlContent)
        WILLO_LAYOUT_EOF

        """

        logger.debug("Ensuring layout '\(layout.name, privacy: .public)' exists at \(layoutPath, privacy: .public)")
        let commandData = Data(writeCommand.utf8)
        try? await session.transport.send(commandData)

        // Brief wait for file check/write
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }

    private func disconnect() async {
        guard let session = session else { return }

        // Stop Zellij bridge (clears stale transport)
        sessionStore.stopBridge(for: workspace.id)

        // Remove from cache since user explicitly disconnected
        sessionStore.removeTerminalSession(for: workspace.id)
        logger.debug("Removed cached session for workspace \(workspace.id, privacy: .public)")

        try? await sessionManager.disconnect(session)
        self.session = nil
        sessionState = .disconnected
    }

    private func reconnectIfNeeded() async {
        // Check if we have a session that claims to be connected
        guard let session = self.session else { return }

        // Verify the transport is still alive
        let currentState = await session.transport.state
        if currentState != .connected {
            logger.info("Session disconnected while in background, reconnecting...")
            sessionState = .reconnecting(attempt: 1)
            await connect()
        }
    }

    private func calculateTerminalSize() -> (cols: UInt16, rows: UInt16) {
        // CRITICAL: Cell dimensions MUST match GlyphAtlas's actual font metrics
        // GlyphAtlas uses CoreText to measure real glyph dimensions, not estimates
        // We need to use the same calculation here to avoid size mismatches
        let fontSize = appearanceSettings.fontSize

        // Ensure bundled fonts are registered before we try to use them
        GlyphAtlas.ensureFontsRegistered()

        // Use the SAME calculation as GlyphAtlas.setupFonts() for consistency
        // Read the configured font, falling back to Iosevka then JetBrains Mono
        let fontName = UserDefaults.standard.string(forKey: "terminalFontName") ?? "IosevkaNerdFontMono-Regular"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        let cellHeight = ceil(ascent + descent + leading)

        // Get advance width for 'M' using the same method as GlyphAtlas
        var chars: [UniChar] = [0x4D] // 'M' character
        var glyphs: [CGGlyph] = [0]
        let gotGlyphs = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)

        var advance: CGSize = .zero
        let cellWidth: CGFloat
        if gotGlyphs && glyphs[0] != 0 {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            cellWidth = ceil(advance.width)
        } else {
            // Fallback to estimate (should never happen with system fonts)
            cellWidth = ceil(fontSize * 0.6)
        }

        var availableSize = CGSize(width: 800, height: 600)

        #if os(iOS)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let bounds = windowScene.coordinateSpace.bounds
            // Account for status bar (56pt) and some padding
            availableSize = CGSize(
                width: bounds.width,
                height: bounds.height - 60
            )
        }
        #endif

        let cols = max(40, min(300, UInt16(availableSize.width / cellWidth)))
        let rows = max(10, min(100, UInt16(availableSize.height / cellHeight)))

        logger.debug("Calculated size: \(cols)x\(rows) (cell: \(cellWidth)x\(cellHeight), fontSize: \(fontSize), available: \(availableSize.width)x\(availableSize.height))")
        return (cols, rows)
    }

    // MARK: - Layout Capture

    /// Capture the current zellij layout
    ///
    /// This implementation uses a simple file-based approach:
    /// 1. Dump layout to a known file path
    /// 2. User manually pastes the content (for now)
    ///
    /// Future improvements could include:
    /// - SFTP file read
    /// - Terminal output capture in transport layer
    /// - Clipboard integration via OSC 52
    private func captureLayout(session: TerminalSession, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                // For now, provide a sample layout since we can't easily capture terminal output
                // In a production implementation, this would:
                // 1. Send: zellij action dump-layout > /tmp/willo-layout.kdl
                // 2. Use SFTP to read /tmp/willo-layout.kdl
                // 3. Parse the KDL content

                // Simulate capture delay
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms

                // For demonstration, return a template layout
                // In reality, this would be the captured content
                let templateLayout = """
                layout {
                    pane size=1 borderless=true {
                        plugin location="compact-bar"
                    }
                    pane split_direction="horizontal" {
                        pane focus=true
                    }
                }
                """

                await MainActor.run {
                    completion(.success(templateLayout))
                }

                logger.debug("Layout captured successfully (template)")

            } catch {
                logger.error("Layout capture failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Bridge Status Overlay

    @ViewBuilder
    private func bridgeStatusOverlay(bridge: ZellijBridge) -> some View {
        switch bridge.bridgeMode {
        case .needsPluginInstall, .needsPluginUpdate:
            // Center overlay for plugin install/update prompts
            BridgeStatusView(bridge: bridge)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))

        case .sessionNotFound, .unsupported:
            // Top banner for errors (positioned below status bar and tab bar)
            VStack {
                BridgeStatusView(bridge: bridge)
                    .padding(.top, 8)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))

        default:
            EmptyView()
        }
    }

    // MARK: - Bridge Auto-Start

    /// Start Zellij bridge for the session if applicable
    private func startBridgeIfNeeded(session: TerminalSession) {
        // Only start for Zellij multiplexer with named sessions
        guard workspace.serverProfile.multiplexer == .zellij,
              !workspace.sessionName.isEmpty else {
            return
        }

        // Safe cast to NIOSSHTransport
        guard let sshTransport = session.transport as? NIOSSHTransport else {
            logger.warning("Cannot start bridge - transport is not NIOSSHTransport")
            return
        }

        Task { @MainActor in
            // Retry up to 3 times with 1s delay for session to appear
            for attempt in 1...3 {
                // Clear stale bridge before retry (allows restart)
                if attempt > 1 {
                    sessionStore.stopBridge(for: workspace.id)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s delay
                }

                await sessionStore.startBridge(
                    for: workspace.id,
                    transport: sshTransport,
                    zellijSessionName: workspace.sessionName
                )

                if let bridge = sessionStore.getBridge(for: workspace.id) {
                    // Check for sessionNotFound to retry
                    if bridge.bridgeMode == .sessionNotFound {
                        if attempt < 3 {
                            logger.info("Bridge session not found, retry \(attempt + 1)/3...")
                            continue
                        }
                    }
                    // Success or other state - stop retrying
                    break
                }
            }
        }
    }
}

// MARK: - Layout Capture Error

enum LayoutCaptureError: LocalizedError {
    case timeout
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Layout capture timed out. Make sure zellij is running."
        case .notImplemented(let message):
            return message
        }
    }
}

// MARK: - Terminal Status Bar

struct TerminalStatusBar: View {
    let workspace: Workspace
    let sessionState: SessionState
    @ObservedObject var voiceManager: VoiceInputManager
    let onCommandPalette: () -> Void
    let onTUIApps: () -> Void
    let onSettings: () -> Void
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onVoiceText: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator with host info
            HStack(spacing: 10) {
                StatusLED(status: ledStatus, size: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.serverProfile.displayName)
                        .font(.willoMono(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)

                    HStack(spacing: 6) {
                        Text(sessionState.statusText)
                            .font(.willoCaption)
                            .foregroundStyle(sessionState.color)

                        if sessionState == .connected {
                            Text("•")
                                .foregroundStyle(Color.textTertiary)
                            Text(workspace.sessionName)
                                .font(.willoCaption)
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                // Voice input (only when connected)
                if sessionState == .connected {
                    VoiceInputButton(voiceManager: voiceManager) { text in
                        onVoiceText(text)
                    }
                    .help("Voice Input")
                }

                // Command palette (only when connected)
                if sessionState == .connected {
                    IndustrialIconButton(icon: "command", isActive: false, activeColor: .terminalCyan) {
                        onCommandPalette()
                    }
                    .help("Zellij Commands (⌘K)")
                }

                // TUI Apps (only when connected)
                if sessionState == .connected {
                    IndustrialIconButton(icon: "square.grid.2x2", isActive: false, activeColor: .terminalGreen) {
                        onTUIApps()
                    }
                    .help("TUI Apps")
                }

                // Settings
                IndustrialIconButton(icon: "gearshape", isActive: false) {
                    onSettings()
                }
                .help("Settings")

                // Disconnect/Reconnect
                if sessionState == .connected {
                    IndustrialIconButton(icon: "xmark.circle", activeColor: .terminalRed) {
                        onDisconnect()
                    }
                    .help("Disconnect")
                } else if sessionState == .disconnected || sessionState == .error(NSError()) {
                    IndustrialIconButton(icon: "bolt.fill", isActive: true, activeColor: .terminalGreen) {
                        onReconnect()
                    }
                    .help("Connect")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Rectangle()
                .fill(Color.machineGray)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.bezelLight.opacity(0.2))
                        .frame(height: 1)
                }
        }
    }

    private var ledStatus: StatusLED.LEDStatus {
        switch sessionState {
        case .disconnected: return .disconnected
        case .connecting, .reconnecting: return .connecting
        case .connected: return .connected
        case .error: return .error
        }
    }
}

// MARK: - Session State Extensions

extension SessionState {
    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))"
        case .error: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: return .textTertiary
        case .connecting: return .terminalAmber
        case .connected: return .terminalGreen
        case .reconnecting: return .terminalAmber
        case .error: return .terminalRed
        }
    }
}

// MARK: - Terminal Container

struct TerminalContainerView: View {
    let session: TerminalSession?
    @EnvironmentObject var appearanceSettings: AppearanceSettings

    var body: some View {
        ZStack {
            Color.machineBlack
                .ignoresSafeArea()

            if let session = session {
                SessionTerminalView(session: session)

                if case .reconnecting(let attempt) = session.state {
                    ReconnectingOverlay(attempt: attempt)
                }
            } else {
                ConnectingView()
            }
        }
    }
}

// MARK: - Connecting View

private struct ConnectingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 20) {
            // Animated terminal icon
            ZStack {
                Circle()
                    .stroke(Color.terminalCyan.opacity(0.2), lineWidth: 2)
                    .frame(width: 64, height: 64)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.terminalCyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(rotation))

                Image(systemName: "terminal")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.terminalCyan)
            }

            Text("ESTABLISHING CONNECTION")
                .font(.willoSectionHeader)
                .tracking(2)
                .foregroundStyle(Color.textSecondary)
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Reconnecting Overlay

struct ReconnectingOverlay: View {
    let attempt: Int
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            // Pulsing indicator
            ZStack {
                Circle()
                    .fill(Color.terminalAmber.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .scaleEffect(pulse ? 1.2 : 1)
                    .opacity(pulse ? 0 : 0.5)

                Circle()
                    .fill(Color.terminalAmber.opacity(0.2))
                    .frame(width: 60, height: 60)

                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.terminalAmber)
            }

            VStack(spacing: 8) {
                Text("RECONNECTING")
                    .font(.willoSectionHeader)
                    .tracking(2)
                    .foregroundStyle(Color.terminalAmber)

                Text("Attempt \(attempt)")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textTertiary)

                Text("Session preserved on server")
                    .font(.willoCaption)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.machineGray.opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.terminalAmber.opacity(0.3), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.5), radius: 20)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - Server Profile Extension

extension ServerProfile {
    var authMethodConfig: AuthMethodConfig {
        switch authMethod {
        case .password:
            let pwd = CredentialStore.shared.retrievePassword(forProfileId: id) ?? ""
            return .password(pwd)
        case .key:
            return .publicKey(keyPath: "~/.ssh/id_rsa", passphrase: nil)
        case .agent:
            return .agent
        }
    }
}

#Preview {
    TerminalWorkspaceView(
        workspace: Workspace(
            serverProfile: ServerProfile(
                displayName: "Devbox",
                hostname: "devbox.local",
                username: "dev"
            ),
            sessionName: "willo/dev/main/devbox"
        )
    )
    .environmentObject(AppState())
    .environmentObject(SessionManager(appManager: GhosttyAppManager()))
    .environmentObject(SessionStore())
    .environmentObject(AppearanceSettings())
    .preferredColorScheme(.dark)
}
