import Foundation
import willo

/// Swift wrapper for the Willo terminal C API
///
/// This class wraps the C functions from willo_bridge.h, providing a
/// Swift-friendly interface to the Ghostty VT parser.
final class WilloTerminal {

    // MARK: - Types

    /// Render cell matching WilloRenderCell from C header
    struct RenderCell {
        var codepoint: UInt32
        var fgColor: UInt32   // 0xAABBGGRR
        var bgColor: UInt32   // 0xAABBGGRR
        var flags: UInt16
        var padding: UInt16 = 0

        // Flag constants (must match willo_bridge.h)
        static let flagBold: UInt16         = 1 << 0
        static let flagItalic: UInt16       = 1 << 1
        static let flagUnderline: UInt16    = 1 << 2
        static let flagStrikethrough: UInt16 = 1 << 3
        static let flagBlink: UInt16        = 1 << 4
        static let flagInverse: UInt16      = 1 << 5
        static let flagInvisible: UInt16    = 1 << 6
        static let flagCursor: UInt16       = 1 << 7
        static let flagWide: UInt16         = 1 << 8
        static let flagWideSpacer: UInt16   = 1 << 9

        init(codepoint: UInt32 = 0,
             fgColor: UInt32 = 0xFFFFFFFF,
             bgColor: UInt32 = 0xFF080808,
             flags: UInt16 = 0) {
            self.codepoint = codepoint
            self.fgColor = fgColor
            self.bgColor = bgColor
            self.flags = flags
        }

        init(from cCell: WilloRenderCell) {
            self.codepoint = cCell.codepoint
            self.fgColor = cCell.fg_color
            self.bgColor = cCell.bg_color
            self.flags = cCell.flags
            self.padding = cCell._padding
        }
    }

    /// Terminal info structure
    struct TerminalInfo {
        var rows: UInt16
        var cols: UInt16
        var cursorX: UInt16
        var cursorY: UInt16
        var bgColor: UInt32
        var fgColor: UInt32
        var cursorColor: UInt32
        var cursorVisible: Bool
        var cursorStyle: UInt8  // 0=bar, 1=block, 2=underline

        init(from cInfo: WilloTerminalInfo) {
            self.rows = cInfo.rows
            self.cols = cInfo.cols
            self.cursorX = cInfo.cursor_x
            self.cursorY = cInfo.cursor_y
            self.bgColor = cInfo.bg_color
            self.fgColor = cInfo.fg_color
            self.cursorColor = cInfo.cursor_color
            self.cursorVisible = cInfo.cursor_visible
            self.cursorStyle = cInfo.cursor_style
        }
    }

    // MARK: - Properties

    private(set) var rows: Int
    private(set) var cols: Int

    /// Handle to native Ghostty terminal instance
    private var terminalHandle: OpaquePointer?

    // Debug logging
    private static let debug = false

    // MARK: - Initialization

    init(rows: Int = 24, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        self.terminalHandle = willo_term_new(UInt16(rows), UInt16(cols))

        if Self.debug {
            if terminalHandle != nil {
                print("[WilloTerminal] Created native terminal \(rows)x\(cols)")
            } else {
                print("[WilloTerminal] ERROR: Failed to create native terminal")
            }
        }
    }

    deinit {
        if let handle = terminalHandle {
            willo_term_free(handle)
            if Self.debug {
                print("[WilloTerminal] Freed native terminal")
            }
        }
    }

    // MARK: - Public API

    /// Feed raw terminal data (ANSI escape sequences, UTF-8) to the parser
    func feed(_ data: Data) {
        guard let handle = terminalHandle else { return }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            willo_term_feed(handle, baseAddress.assumingMemoryBound(to: UInt8.self), bytes.count)
        }

        if Self.debug {
            print("[WilloTerminal] Fed \(data.count) bytes")
        }
    }

    /// Feed a string to the terminal
    func feed(_ string: String) {
        if let data = string.data(using: .utf8) {
            feed(data)
        }
    }

    /// Resize the terminal
    func resize(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols

        guard let handle = terminalHandle else { return }
        willo_term_resize(handle, UInt16(rows), UInt16(cols))

        if Self.debug {
            print("[WilloTerminal] Resized to \(rows)x\(cols)")
        }
    }

    /// Get the current terminal info
    func getInfo() -> TerminalInfo {
        guard let handle = terminalHandle else {
            return TerminalInfo(from: WilloTerminalInfo())
        }

        var cInfo = WilloTerminalInfo()
        willo_term_get_info(handle, &cInfo)
        return TerminalInfo(from: cInfo)
    }

    /// Render the terminal grid to a buffer
    func render() -> [RenderCell] {
        guard let handle = terminalHandle else {
            return []
        }

        let cellCount = rows * cols
        var buffer = [WilloRenderCell](repeating: WilloRenderCell(), count: cellCount)

        let actualCount = buffer.withUnsafeMutableBufferPointer { ptr in
            willo_term_render(handle, ptr.baseAddress, cellCount)
        }

        // Convert C cells to Swift cells
        return buffer.prefix(actualCount).map { RenderCell(from: $0) }
    }

    /// Check if terminal has dirty regions
    func checkDirty() -> Bool {
        guard let handle = terminalHandle else { return false }
        return willo_term_is_dirty(handle)
    }

    /// Clear the dirty flag
    func clearDirty() {
        guard let handle = terminalHandle else { return }
        willo_term_clear_dirty(handle)
    }
}
