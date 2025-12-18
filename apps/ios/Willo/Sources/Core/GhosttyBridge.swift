import Foundation
import SwiftUI
import Metal
import QuartzCore

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Ghostty Bridge Stubs
//
// These are stub classes to maintain API compatibility during migration
// from full GhosttyKit to the lighter libwillo approach.
//
// The actual terminal rendering is now handled by:
// - WilloTerminal (Sources/Bridging/WilloTerminal.swift) - VT parser
// - WilloTerminalView (Sources/Renderer/WilloTerminalView.swift) - Metal rendering
//
// TODO: Remove these stubs and refactor SessionManager/WilloApp to use
// WilloTerminal directly once the migration is complete.

// MARK: - GhosttyAppManager (Stub)

/// Stub manager - the actual terminal is managed by WilloTerminal
final class GhosttyAppManager: ObservableObject {
    enum State: String {
        case loading
        case ready
        case error
    }

    @Published private(set) var state: State = .ready

    init() {
        // No-op - terminal functionality is in WilloTerminal
    }

    func tick() {}
    func setFocus(_ focused: Bool) {}
    func setColorScheme(_ scheme: ColorScheme) {}
}

// MARK: - GhosttyConfig (Stub)

/// Stub config - configuration is handled differently in libwillo
final class GhosttyConfig {
    var loaded: Bool { true }

    init() {}

    var backgroundColor: Color { .black }
}

// MARK: - GhosttySurface (Stub)

/// Stub surface - the actual terminal surface is WilloTerminalView
final class GhosttySurface: ObservableObject {
    private weak var app: GhosttyAppManager?

    let uuid = UUID()

    @Published var title: String = "Terminal"
    @Published var pwd: String?
    @Published var healthy: Bool = true
    @Published private(set) var isInitialized: Bool = false

    init(app: GhosttyAppManager) {
        self.app = app
    }

    #if os(iOS)
    func initializeWithView(_ view: UIView) {
        isInitialized = true
    }
    #else
    func initializeWithView(_ view: NSView) {
        isInitialized = true
    }
    #endif

    func setSize(width: UInt32, height: UInt32) {}
    func setContentScale(_ scale: Double) {}
    func setFocus(_ focused: Bool) {}
    func draw() {}
    func refresh() {}
    func sendText(_ text: String) {}

    var mouseCaptured: Bool { false }
    func getSelectionText() -> String? { nil }
    var hasSelection: Bool { false }
    func requestClose() {}
    var processExited: Bool { false }

    func feedData(_ data: Data) {
        // In the stub, this is a no-op
        // Actual feeding happens through WilloTerminal
    }

    func feedString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        feedData(data)
    }
}

// MARK: - GhosttyTerminalView (Stub)

#if os(iOS)
/// Stub terminal view - use WilloTerminalView instead
struct GhosttyTerminalView: UIViewRepresentable {
    @ObservedObject var surface: GhosttySurface

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#else
/// Stub terminal view - use WilloTerminalView instead
struct GhosttyTerminalView: NSViewRepresentable {
    @ObservedObject var surface: GhosttySurface

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
