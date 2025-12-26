import MetalKit
import SwiftUI

#if os(iOS)
/// SwiftUI wrapper for WilloTerminalView with transport integration
struct WilloTerminalViewRepresentable: UIViewRepresentable {
    typealias UIViewType = WilloTerminalView

    /// Transport to read data from (optional)
    let transport: TerminalTransport?

    /// Font size for terminal rendering
    var fontSize: CGFloat

    /// Callback for input data (key presses)
    var onInput: ((Data) -> Void)?

    /// Callback for resize events
    var onResize: ((Int, Int) -> Void)?  // (cols, rows)

    /// Session ID for thumbnail capture (optional)
    var sessionId: UUID?

    /// Thumbnail manager for capturing screenshots (optional)
    var thumbnailManager: ThumbnailManager?

    /// Session store for activity tracking (optional)
    var sessionStore: SessionStore?

    init(
        transport: TerminalTransport? = nil,
        fontSize: CGFloat = 24.0,
        onInput: ((Data) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil,
        sessionId: UUID? = nil,
        thumbnailManager: ThumbnailManager? = nil,
        sessionStore: SessionStore? = nil
    ) {
        self.transport = transport
        self.fontSize = fontSize
        self.onInput = onInput
        self.onResize = onResize
        self.sessionId = sessionId
        self.thumbnailManager = thumbnailManager
        self.sessionStore = sessionStore
    }

    /// Coordinator manages the data stream subscription
    class Coordinator {
        var terminalView: WilloTerminalView?
        var dataTask: Task<Void, Never>?
        var currentFontSize: CGFloat = 24.0
        var activityDetector: ActivityDetector?

        deinit {
            dataTask?.cancel()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WilloTerminalView {
        let view = WilloTerminalView(frame: .zero)
        context.coordinator.terminalView = view
        context.coordinator.currentFontSize = fontSize

        // Initialize activity detector if session store is available
        if sessionStore != nil {
            context.coordinator.activityDetector = ActivityDetector()
        }

        // Ensure the view fills its container
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Apply initial font size if different from default
        if abs(fontSize - 24.0) > 0.5 {
            view.updateFontSize(fontSize)
        }

        // Wire up input callback
        let inputCallback = onInput
        view.onInput = { data in
            inputCallback?(data)
        }

        // Wire up resize callback
        let resizeCallback = onResize
        view.onResize = { cols, rows in
            print("[TerminalView] Resize callback: \(cols)x\(rows)")
            resizeCallback?(cols, rows)
        }

        // Start reading from transport if available
        if let transport = transport {
            startDataStream(transport: transport, context: context)
        }

        // Register with thumbnail manager if available
        if let sessionId = sessionId, let thumbnailManager = thumbnailManager {
            Task { @MainActor in
                thumbnailManager.registerTerminalView(view, for: sessionId)
            }
        }

        return view
    }

    func updateUIView(_ uiView: WilloTerminalView, context: Context) {
        // Check if font size changed
        let delta = abs(fontSize - context.coordinator.currentFontSize)
        print("[Representable] updateUIView - fontSize: \(fontSize), stored: \(context.coordinator.currentFontSize), delta: \(delta)")

        if delta > 0.5 {
            print("[Representable] Font size changed! Calling updateFontSize(\(fontSize))")
            context.coordinator.currentFontSize = fontSize
            uiView.updateFontSize(fontSize)

            // Force layout to ensure bounds are correct before resize calculation
            uiView.setNeedsLayout()
            uiView.layoutIfNeeded()
            print("[Representable] Layout forced, bounds now: \(uiView.bounds.size)")
        }
    }

    private func startDataStream(transport: TerminalTransport, context: Context) {
        // Cancel any existing subscription
        context.coordinator.dataTask?.cancel()

        // Use callback-based approach for both Mosh and SSH transports
        // This avoids AsyncStream multiple consumer issues with TransportPTYBridge
        let coordinator = context.coordinator
        let capturedSessionId = sessionId
        let capturedSessionStore = sessionStore

        if let moshTransport = transport as? MoshTransport {
            print("[TerminalView] Setting up Mosh data callback")
            moshTransport.setDataCallback { [weak coordinator] data in
                // Must dispatch to main thread since callback comes from background
                DispatchQueue.main.async {
                    print("[TerminalView] Mosh data received: \(data.count) bytes, coordinator=\(coordinator != nil), view=\(coordinator?.terminalView != nil)")
                    if let view = coordinator?.terminalView {
                        view.feed(data)
                    } else {
                        print("[TerminalView] ERROR: terminalView is nil!")
                    }
                    // Process activity detection
                    Self.processActivityDetection(
                        data: data,
                        coordinator: coordinator,
                        sessionId: capturedSessionId,
                        sessionStore: capturedSessionStore
                    )
                }
            }
        } else if let sshTransport = transport as? NIOSSHTransport {
            print("[TerminalView] Setting up SSH data callback")
            sshTransport.setDataCallback { [weak coordinator] data in
                // Must dispatch to main thread since callback comes from NIO event loop
                DispatchQueue.main.async {
                    print("[TerminalView] SSH data received: \(data.count) bytes, coordinator=\(coordinator != nil), view=\(coordinator?.terminalView != nil)")
                    if let view = coordinator?.terminalView {
                        view.feed(data)
                    } else {
                        print("[TerminalView] ERROR: terminalView is nil!")
                    }
                    // Process activity detection
                    Self.processActivityDetection(
                        data: data,
                        coordinator: coordinator,
                        sessionId: capturedSessionId,
                        sessionStore: capturedSessionStore
                    )
                }
            }
        } else {
            // Fallback for other transport types - use AsyncStream
            context.coordinator.dataTask = Task { @MainActor in
                print("[TerminalView] Starting data stream subscription (fallback)")
                for await data in transport.dataStream {
                    if let view = context.coordinator.terminalView {
                        view.feed(data)
                    }
                    // Process activity detection
                    Self.processActivityDetection(
                        data: data,
                        coordinator: context.coordinator,
                        sessionId: capturedSessionId,
                        sessionStore: capturedSessionStore
                    )
                }
                print("[TerminalView] Data stream ended")
            }
        }
    }

    /// Process activity detection for incoming data
    private static func processActivityDetection(
        data: Data,
        coordinator: Coordinator?,
        sessionId: UUID?,
        sessionStore: SessionStore?
    ) {
        guard let coordinator = coordinator,
              let detector = coordinator.activityDetector,
              let sessionId = sessionId,
              let sessionStore = sessionStore else {
            return
        }

        Task { @MainActor in
            // Process output through detector
            if let newState = detector.processOutput(data) {
                // State changed - update session store
                print("[ActivityDetector] State changed to: \(newState)")

                // Check if session is in background (not active)
                let isBackground = sessionStore.activeSessionId != sessionId

                if isBackground {
                    // Session is in background - increment unread counter
                    sessionStore.incrementUnread(sessionId)
                    print("[ActivityDetector] Incremented unread for background session")
                } else {
                    // Session is active - just update state
                    sessionStore.setActivityState(sessionId, state: newState)
                }
            }
        }
    }

    /// Feed data directly to the terminal
    static func feed(_ string: String, coordinator: Coordinator) {
        coordinator.terminalView?.feed(string)
    }

    static func feed(_ data: Data, coordinator: Coordinator) {
        coordinator.terminalView?.feed(data)
    }
}

/// Simple terminal view for sessions (connects transport to terminal)
struct SessionTerminalView: View {
    let session: TerminalSession
    @EnvironmentObject var appearanceSettings: AppearanceSettings
    @EnvironmentObject var sessionStore: SessionStore
    @State private var currentSize: (cols: Int, rows: Int) = (80, 24)
    @State private var viewBounds: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            WilloTerminalViewRepresentable(
                transport: session.transport,
                fontSize: appearanceSettings.fontSize,
                onInput: { data in
                    Task {
                        try? await session.transport.send(data)
                    }
                },
                onResize: { cols, rows in
                    currentSize = (cols, rows)
                    Task {
                        try? await session.transport.resize(cols: UInt16(cols), rows: UInt16(rows))
                    }
                },
                sessionId: session.id,
                thumbnailManager: sessionStore.thumbnailManager,
                sessionStore: sessionStore
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: geometry.size) { newSize in
                viewBounds = newSize
            }
        }
    }
}

/// Demo view for testing the Metal terminal renderer
struct MetalTerminalDemoView: View {
    @State private var inputText = ""

    /// Test ANSI sequences
    private let testSequences: [(String, String)] = [
        ("Clear", "\u{1B}[2J\u{1B}[H"),
        ("Colors", "\u{1B}[31mRed \u{1B}[32mGreen \u{1B}[33mYellow \u{1B}[34mBlue\u{1B}[0m\r\n"),
        ("Bold", "\u{1B}[1mBold Text\u{1B}[0m\r\n"),
        ("Prompt", "\r\n\u{1B}[1;34muser@willo\u{1B}[0m:\u{1B}[1;36m~\u{1B}[0m$ "),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Metal terminal view
            WilloTerminalViewRepresentable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            // Control panel
            VStack(spacing: 12) {
                // Quick action buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(testSequences, id: \.0) { name, sequence in
                            Button(name) {
                                // Note: Direct feed not working through representable yet
                                // This demonstrates the API
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal)
                }

                // Info bar
                HStack {
                    Text("Metal Renderer")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Spacer()

                    Label("120fps", systemImage: "speedometer")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Metal Terminal")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack {
        MetalTerminalDemoView()
    }
}
#else
// macOS stubs
struct WilloTerminalViewRepresentable: NSViewRepresentable {
    let transport: TerminalTransport?
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    init(transport: TerminalTransport? = nil, onInput: ((Data) -> Void)? = nil, onResize: ((Int, Int) -> Void)? = nil) {
        self.transport = transport
        self.onInput = onInput
        self.onResize = onResize
    }

    class Coordinator {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SessionTerminalView: View {
    let session: TerminalSession
    var body: some View {
        Color.black
    }
}

struct MetalTerminalDemoView: View {
    var body: some View {
        Color.black
            .navigationTitle("Metal Terminal")
    }
}
#endif
