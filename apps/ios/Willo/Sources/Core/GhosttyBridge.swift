import Foundation
import SwiftUI
import GhosttyKit
import Metal
import QuartzCore

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Ghostty Global Initialization

/// Ensures Ghostty is initialized exactly once before any API calls
private let ghosttyInitialized: Bool = {
    // ghostty_init requires argc/argv - we pass empty args for iOS
    let result = ghostty_init(0, nil)
    if result != 0 {
        print("[Ghostty] Warning: ghostty_init returned \(result)")
    } else {
        print("[Ghostty] Initialized successfully")
    }
    return result == 0
}()

/// Call this to ensure Ghostty is initialized before using any APIs
func ensureGhosttyInitialized() -> Bool {
    return ghosttyInitialized
}

/// Bridge between Willo and GhosttyKit
///
/// This provides a Swift-idiomatic interface to the Ghostty terminal emulation library.
///
/// ARCHITECTURE NOTE:
/// Ghostty's surface API is designed around owning a PTY. For Willo's mosh/SSH transport,
/// we need to inject data externally. Current approach options:
///
/// 1. Bridge Process: Spawn a helper that relays between Ghostty PTY and our transport
/// 2. SwiftTerm Fallback: Use SwiftTerm for external I/O support
/// 3. Ghostty Extension: Contribute external I/O API upstream
///
/// For MVP, we'll use option 1 with a local shell, then iterate on transport integration.

// MARK: - Ghostty App Manager

/// Manages the Ghostty application state and configuration
final class GhosttyAppManager: ObservableObject {
    enum State: String {
        case loading
        case ready
        case error
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var config: GhosttyConfig

    private(set) var app: ghostty_app_t?

    init() {
        // Ensure Ghostty global state is initialized first
        guard ensureGhosttyInitialized() else {
            print("[GhosttyAppManager] Failed to initialize Ghostty global state")
            self.config = GhosttyConfig()
            state = .error
            return
        }

        self.config = GhosttyConfig()

        guard config.handle != nil else {
            state = .error
            return
        }

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                GhosttyAppManager.handleWakeup(userdata)
            },
            action_cb: { app, target, action in
                GhosttyAppManager.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyAppManager.handleReadClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                GhosttyAppManager.handleConfirmReadClipboard(userdata, string: string, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyAppManager.handleWriteClipboard(userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyAppManager.handleCloseSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtimeConfig, config.handle) else {
            state = .error
            return
        }

        self.app = app
        self.state = .ready
    }

    deinit {
        if let app = app {
            ghostty_app_free(app)
        }
    }

    // MARK: - App Operations

    func tick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app = app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func setColorScheme(_ scheme: ColorScheme) {
        guard let app = app else { return }
        let ghosttyScheme: ghostty_color_scheme_e = scheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(app, ghosttyScheme)
    }

    // MARK: - Callbacks (iOS)

    private static func handleWakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata = userdata else { return }
        let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.tick()
        }
    }

    private static func handleAction(_ app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // TODO: Implement action handling for iOS
        // Most actions are macOS-specific (new window, tabs, etc.)
        // For iOS we mainly need: quit, clipboard, notifications
        return false
    }

    private static func handleReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        // TODO: Implement iOS clipboard read
    }

    private static func handleConfirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // TODO: Implement clipboard confirmation
    }

    private static func handleWriteClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        // TODO: Implement iOS clipboard write
        guard let content = content, len > 0 else { return }

        // Get the first text/plain content
        for i in 0..<len {
            let item = content[i]
            if let mime = item.mime, String(cString: mime) == "text/plain",
               let data = item.data {
                let text = String(cString: data)
                #if os(iOS)
                UIPasteboard.general.string = text
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #endif
                break
            }
        }
    }

    private static func handleCloseSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        // TODO: Handle surface close notification
    }
}

// MARK: - Ghostty Config

/// Wraps Ghostty configuration
final class GhosttyConfig {
    private(set) var handle: ghostty_config_t?

    var loaded: Bool { handle != nil }

    init() {
        handle = ghostty_config_new()
        guard let handle = handle else { return }

        // Finalize the config (applies defaults)
        ghostty_config_finalize(handle)
    }

    init(clone source: ghostty_config_t?) {
        guard let source = source else {
            handle = nil
            return
        }
        handle = ghostty_config_clone(source)
    }

    deinit {
        if let handle = handle {
            ghostty_config_free(handle)
        }
    }

    // MARK: - Config Properties

    /// Get the background color from config
    var backgroundColor: Color {
        // TODO: Extract from config
        return Color.black
    }
}

// MARK: - Ghostty Surface

/// Represents a terminal surface (a single terminal view)
final class GhosttySurface: ObservableObject {
    private(set) var surface: ghostty_surface_t?
    private weak var app: GhosttyAppManager?

    let uuid = UUID()

    @Published var title: String = "Terminal"
    @Published var pwd: String?
    @Published var healthy: Bool = true

    /// Whether the surface has been initialized with a view
    private(set) var isInitialized: Bool = false

    init(app: GhosttyAppManager) {
        self.app = app
        // Note: Surface is not created here - it requires a view reference
        // Call initializeWithView() once the view is available
    }

    /// Initialize the Ghostty surface with a native view
    /// This must be called once the UIView/NSView is available
    #if os(iOS)
    func initializeWithView(_ view: UIView) {
        guard !isInitialized, let ghosttyApp = app?.app else { return }

        // Check if Metal is available (iOS Simulator has limited support)
        guard MTLCreateSystemDefaultDevice() != nil else {
            print("[GhosttySurface] Metal not available - cannot initialize surface")
            return
        }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform.ios.uiview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.scale_factor = view.contentScaleFactor

        // NOTE: This may crash on iOS Simulator due to Metal limitations.
        // Ghostty's Metal renderer uses APIs that may not be available on simulator.
        // For full testing, use a real device.
        surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
        isInitialized = surface != nil

        if isInitialized {
            print("[GhosttySurface] Surface initialized successfully")
            // Set initial size
            let scale = view.contentScaleFactor
            setContentScale(scale)
            setSize(
                width: UInt32(view.bounds.width * scale),
                height: UInt32(view.bounds.height * scale)
            )
        } else {
            print("[GhosttySurface] Failed to create surface - may need real device")
        }
    }
    #else
    func initializeWithView(_ view: NSView) {
        guard !isInitialized, let ghosttyApp = app?.app else { return }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        if let window = view.window {
            surfaceConfig.scale_factor = window.backingScaleFactor
        }

        surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
        isInitialized = surface != nil

        if isInitialized, let window = view.window {
            let scale = window.backingScaleFactor
            setContentScale(scale)
            setSize(
                width: UInt32(view.bounds.width * scale),
                height: UInt32(view.bounds.height * scale)
            )
        }
    }
    #endif

    deinit {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Surface Operations

    func setSize(width: UInt32, height: UInt32) {
        guard let surface = surface else { return }
        ghostty_surface_set_size(surface, width, height)
    }

    func setContentScale(_ scale: Double) {
        guard let surface = surface else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    func setFocus(_ focused: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func draw() {
        guard let surface = surface else { return }
        ghostty_surface_draw(surface)
    }

    func refresh() {
        guard let surface = surface else { return }
        ghostty_surface_refresh(surface)
    }

    /// Send text input (keyboard) to the terminal
    func sendText(_ text: String) {
        guard let surface = surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Check if mouse is captured by the terminal
    var mouseCaptured: Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    /// Get current selection text
    func getSelectionText() -> String? {
        guard let surface = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Check if there's an active selection
    var hasSelection: Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    /// Request the surface to close
    func requestClose() {
        guard let surface = surface else { return }
        ghostty_surface_request_close(surface)
    }

    /// Check if the child process has exited
    var processExited: Bool {
        guard let surface = surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    // MARK: - External Data Feed (Direct Feed Architecture)

    /// Feed raw terminal data (ANSI sequences) from external transport
    ///
    /// This enables the Direct Feed architecture where external transports
    /// (SSH, Mosh) feed data directly to Ghostty's terminal parser instead
    /// of using PTY bridging. This is faster and simpler for iOS.
    ///
    /// - Parameter data: Raw terminal output data containing ANSI escape sequences
    func feedData(_ data: Data) {
        guard let surface = surface else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, ptr, UInt(buffer.count))
        }
    }

    /// Feed a string directly to the terminal
    ///
    /// Convenience method for feeding string data (e.g., for testing).
    ///
    /// - Parameter string: Terminal output string containing ANSI escape sequences
    func feedString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        feedData(data)
    }
}

// MARK: - Ghostty Terminal SwiftUI View

#if os(iOS)
/// SwiftUI wrapper for a Ghostty terminal surface (iOS)
struct GhosttyTerminalView: UIViewRepresentable {
    @ObservedObject var surface: GhosttySurface

    func makeUIView(context: Context) -> GhosttyTerminalUIView {
        let view = GhosttyTerminalUIView(surface: surface)
        return view
    }

    func updateUIView(_ uiView: GhosttyTerminalUIView, context: Context) {
        // Update view if needed
    }
}

/// UIKit view that hosts the Metal layer for terminal rendering
class GhosttyTerminalUIView: UIView {
    private let surface: GhosttySurface
    private var displayLink: CADisplayLink?

    init(surface: GhosttySurface) {
        self.surface = surface
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupView() {
        // The layer must be CAMetalLayer for Ghostty rendering
        backgroundColor = .black

        // Configure metal layer
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.contentsScale = contentScaleFactor

            // Get the default Metal device
            if let device = MTLCreateSystemDefaultDevice() {
                metalLayer.device = device
            }
        }
    }

    override class var layerClass: AnyClass {
        return CAMetalLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Update metal layer drawable size
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = contentScaleFactor
            metalLayer.drawableSize = CGSize(
                width: bounds.width * contentScaleFactor,
                height: bounds.height * contentScaleFactor
            )
        }

        // Update Ghostty surface size
        let scale = contentScaleFactor
        surface.setContentScale(scale)
        surface.setSize(
            width: UInt32(bounds.width * scale),
            height: UInt32(bounds.height * scale)
        )

        // Request redraw
        if surface.isInitialized {
            surface.refresh()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            // Initialize surface with this view if not already done
            if !surface.isInitialized {
                surface.initializeWithView(self)
            }

            surface.setFocus(true)
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    // MARK: - Display Link for Rendering

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(render))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func render() {
        guard surface.isInitialized else { return }
        surface.draw()
    }

    // MARK: - Input Handling

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // TODO: Convert UIPress to Ghostty key events
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
    }

    // Touch handling for mouse events
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // TODO: Convert touches to Ghostty mouse events
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
    }
}
#else
/// SwiftUI wrapper for a Ghostty terminal surface (macOS)
struct GhosttyTerminalView: NSViewRepresentable {
    @ObservedObject var surface: GhosttySurface

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        let view = GhosttyTerminalNSView(surface: surface)
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {
        // Update view if needed
    }
}

/// AppKit view that hosts the Metal layer for terminal rendering
class GhosttyTerminalNSView: NSView {
    private let surface: GhosttySurface

    init(surface: GhosttySurface) {
        self.surface = surface
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupView() {
        wantsLayer = true
        layer = CAMetalLayer()
    }

    override func layout() {
        super.layout()

        guard let window = window else { return }
        let scale = window.backingScaleFactor
        surface.setContentScale(scale)
        surface.setSize(
            width: UInt32(bounds.width * scale),
            height: UInt32(bounds.height * scale)
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            surface.setFocus(true)
            surface.draw()
        }
    }
}
#endif

// MARK: - Transport Integration Note
//
// For transport integration (SSH, Mosh), see:
// - Sources/Transport/TransportProtocol.swift - Transport abstraction
// - Sources/Transport/PTYBridge.swift - PTY pair management
// - Sources/Session/SessionManager.swift - Session orchestration
//
// The PTY bridge connects Ghostty surfaces to external transports
// by creating a PTY pair where Ghostty owns the slave end and
// the transport communicates via the master end.
