import MetalKit
import SwiftUI

/// SwiftUI wrapper for WilloTerminalView with transport integration
struct WilloTerminalViewRepresentable: UIViewRepresentable {
    typealias UIViewType = WilloTerminalView

    /// Transport to read data from (optional)
    let transport: TerminalTransport?

    /// Callback for input data (key presses)
    var onInput: ((Data) -> Void)?

    /// Callback for resize events
    var onResize: ((Int, Int) -> Void)?  // (cols, rows)

    init(transport: TerminalTransport? = nil, onInput: ((Data) -> Void)? = nil, onResize: ((Int, Int) -> Void)? = nil) {
        self.transport = transport
        self.onInput = onInput
        self.onResize = onResize
    }

    /// Coordinator manages the data stream subscription
    class Coordinator {
        var terminalView: WilloTerminalView?
        var dataTask: Task<Void, Never>?

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

        return view
    }

    func updateUIView(_ uiView: WilloTerminalView, context: Context) {
        // Updates handled by data stream
    }

    private func startDataStream(transport: TerminalTransport, context: Context) {
        // Cancel any existing subscription
        context.coordinator.dataTask?.cancel()

        // Use callback-based approach to avoid AsyncStream multiple consumer issues
        if let moshTransport = transport as? MoshTransport {
            print("[TerminalView] Setting up direct data callback")
            let coordinator = context.coordinator
            moshTransport.setDataCallback { [weak coordinator] data in
                print("[TerminalView] Received \(data.count) bytes via callback")
                // Must dispatch to main thread since callback comes from background
                DispatchQueue.main.async {
                    if let view = coordinator?.terminalView {
                        view.feed(data)
                    } else {
                        print("[TerminalView] WARNING: terminalView is nil!")
                    }
                }
            }
        } else {
            // Fallback for other transport types - use AsyncStream
            context.coordinator.dataTask = Task { @MainActor in
                print("[TerminalView] Starting data stream subscription (fallback)")
                for await data in transport.dataStream {
                    print("[TerminalView] Received \(data.count) bytes from transport")
                    if let view = context.coordinator.terminalView {
                        view.feed(data)
                    } else {
                        print("[TerminalView] WARNING: terminalView is nil!")
                    }
                }
                print("[TerminalView] Data stream ended")
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

    var body: some View {
        WilloTerminalViewRepresentable(
            transport: session.transport,
            onInput: { data in
                Task {
                    try? await session.transport.send(data)
                }
            },
            onResize: { cols, rows in
                Task {
                    try? await session.transport.resize(cols: UInt16(cols), rows: UInt16(rows))
                }
            }
        )
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
