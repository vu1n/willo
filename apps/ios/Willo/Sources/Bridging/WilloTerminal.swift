import Foundation

/// Swift wrapper for the Willo terminal C API
///
/// This class wraps the C functions from willo_bridge.h, providing a
/// Swift-friendly interface to the Ghostty VT parser.
///
/// Note: Requires libwillo.a to be linked. Until then, this class
/// provides a mock implementation for development.
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
    }

    // MARK: - Properties

    private(set) var rows: Int
    private(set) var cols: Int
    private var cells: [RenderCell]
    private var cursorX: Int = 0
    private var cursorY: Int = 0
    private var isDirty: Bool = true

    // Current text attributes (SGR state)
    private var currentFgColor: UInt32 = 0xFFFFFFFF  // White
    private var currentBgColor: UInt32 = 0xFF080808  // Dark bg
    private var currentFlags: UInt16 = 0

    // Debug logging (set to true to trace VT parsing)
    private static let debugParsing = true

    // For native implementation (when libwillo.a is linked)
    // private var terminalHandle: OpaquePointer?

    // MARK: - Initialization

    init(rows: Int = 24, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        self.cells = [RenderCell](repeating: RenderCell(), count: rows * cols)

        // TODO: When libwillo.a is linked:
        // terminalHandle = willo_term_new(UInt16(rows), UInt16(cols))
    }

    deinit {
        // TODO: When libwillo.a is linked:
        // willo_term_free(terminalHandle)
    }

    // MARK: - Public API

    /// Feed raw terminal data (ANSI escape sequences, UTF-8) to the parser
    func feed(_ data: Data) {
        // TODO: When libwillo.a is linked:
        // data.withUnsafeBytes { bytes in
        //     willo_term_feed(terminalHandle, bytes.baseAddress, bytes.count)
        // }

        // Mock implementation: parse simple text
        mockFeed(data)
        isDirty = true
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
        cells = [RenderCell](repeating: RenderCell(), count: rows * cols)
        cursorX = min(cursorX, cols - 1)
        cursorY = min(cursorY, rows - 1)

        // TODO: When libwillo.a is linked:
        // willo_term_resize(terminalHandle, UInt16(rows), UInt16(cols))

        isDirty = true
    }

    /// Get the current terminal info
    func getInfo() -> TerminalInfo {
        // TODO: When libwillo.a is linked:
        // var info = WilloTerminalInfo()
        // willo_term_get_info(terminalHandle, &info)
        // return TerminalInfo(...)

        return TerminalInfo(
            rows: UInt16(rows),
            cols: UInt16(cols),
            cursorX: UInt16(cursorX),
            cursorY: UInt16(cursorY),
            bgColor: 0xFF080808,
            fgColor: 0xFFFFFFFF,
            cursorColor: 0xFFFFFFFF,
            cursorVisible: true,
            cursorStyle: 1  // block
        )
    }

    /// Render the terminal grid to a buffer
    func render() -> [RenderCell] {
        // TODO: When libwillo.a is linked:
        // var buffer = [WilloRenderCell](repeating: WilloRenderCell(), count: rows * cols)
        // let count = willo_term_render(terminalHandle, &buffer, buffer.count)
        // return buffer.prefix(count).map { RenderCell(...) }

        // Update cursor flag in mock
        for i in 0..<cells.count {
            cells[i].flags &= ~RenderCell.flagCursor
        }
        let cursorIndex = cursorY * cols + cursorX
        if cursorIndex >= 0 && cursorIndex < cells.count {
            cells[cursorIndex].flags |= RenderCell.flagCursor
        }

        return cells
    }

    /// Check if terminal has dirty regions
    func checkDirty() -> Bool {
        // TODO: When libwillo.a is linked:
        // return willo_term_is_dirty(terminalHandle)
        return isDirty
    }

    /// Clear the dirty flag
    func clearDirty() {
        // TODO: When libwillo.a is linked:
        // willo_term_clear_dirty(terminalHandle)
        isDirty = false
    }

    // MARK: - Mock Implementation

    /// Simple mock terminal parser for development
    /// IMPORTANT: Iterates unicode scalars directly to avoid CR+LF grapheme cluster issues
    private func mockFeed(_ data: Data) {
        guard let string = String(data: data, encoding: .utf8) else {
            if Self.debugParsing {
                print("[VT] mockFeed: failed to decode \(data.count) bytes as UTF-8")
            }
            return
        }

        if Self.debugParsing {
            // Log raw input (escape as printable)
            let escaped = string.unicodeScalars.map { scalar -> String in
                if scalar.value == 0x1B {
                    return "\\e"
                } else if scalar.value < 32 {
                    return String(format: "\\x%02X", scalar.value)
                } else {
                    return String(scalar)
                }
            }.joined()
            print("[VT] Feed: \"\(escaped)\" (\(data.count) bytes)")
        }

        // CRITICAL: Iterate unicode scalars directly, NOT Characters!
        // Swift's Character type combines CR+LF into a single grapheme cluster,
        // which would cause us to skip the LF when processing CR.
        let scalars = Array(string.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalarValue = scalars[i].value

            if scalarValue == 0x1B {
                // Start of escape sequence (ESC)
                i = parseEscapeSequenceFromScalars(scalars, from: i)
            } else if scalarValue == 0x0D {
                // Carriage return (CR)
                if Self.debugParsing {
                    print("[VT] CR: cursor to column 0")
                }
                cursorX = 0
                i += 1
            } else if scalarValue == 0x0A {
                // Line feed (LF)
                if Self.debugParsing {
                    print("[VT] LF: cursor from row \(cursorY) to \(cursorY + 1)")
                }
                cursorY += 1
                if cursorY >= rows {
                    scrollUp()
                    cursorY = rows - 1
                }
                i += 1
            } else if scalarValue == 0x09 {
                // Tab
                cursorX = ((cursorX / 8) + 1) * 8
                if cursorX >= cols {
                    cursorX = cols - 1
                }
                i += 1
            } else if scalarValue == 0x08 {
                // Backspace
                if cursorX > 0 {
                    cursorX -= 1
                }
                i += 1
            } else if scalarValue == 0x07 {
                // Bell - ignore
                i += 1
            } else if scalarValue >= 32 {
                // Regular printable character
                printScalar(scalars[i])
                i += 1
            } else {
                // Unknown control character - skip
                if Self.debugParsing {
                    print("[VT] Skipping control char: 0x\(String(format: "%02X", scalarValue))")
                }
                i += 1
            }
        }
    }

    // MARK: - Scalar-based Escape Sequence Parsing

    private func parseEscapeSequenceFromScalars(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start + 1
        guard i < scalars.count else { return i }

        let next = scalars[i].value

        if next == 0x5B { // '['
            // CSI sequence
            i += 1
            return parseCSIFromScalars(scalars, from: i)
        } else if next == 0x5D { // ']'
            // OSC sequence - skip for now
            i += 1
            while i < scalars.count && scalars[i].value != 0x07 && scalars[i].value != 0x1B {
                i += 1
            }
            if i < scalars.count && scalars[i].value == 0x07 {
                i += 1
            }
            return i
        }

        return i
    }

    private func parseCSIFromScalars(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start
        var params: [Int] = []
        var currentParam = 0
        var hasParam = false

        while i < scalars.count {
            let c = scalars[i].value

            if c >= 0x30 && c <= 0x39 { // '0'-'9'
                currentParam = currentParam * 10 + Int(c - 0x30)
                hasParam = true
                i += 1
            } else if c == 0x3B { // ';'
                params.append(hasParam ? currentParam : 0)
                currentParam = 0
                hasParam = false
                i += 1
            } else if c >= 0x40 && c <= 0x7E { // '@'-'~' (final byte)
                if hasParam {
                    params.append(currentParam)
                }
                executeCSI(Character(scalars[i]), params: params)
                return i + 1
            } else if c == 0x3F { // '?' - private mode indicator
                // Skip '?' but continue parsing
                i += 1
            } else {
                // Intermediate bytes or unknown
                i += 1
            }
        }

        return i
    }

    private func printScalar(_ scalar: Unicode.Scalar) {
        guard cursorX < cols && cursorY < rows else { return }

        let index = cursorY * cols + cursorX
        guard index < cells.count else { return }

        cells[index].codepoint = scalar.value
        cells[index].fgColor = currentFgColor
        cells[index].bgColor = currentBgColor
        cells[index].flags = currentFlags

        if Self.debugParsing && scalar.value >= 32 {
            print("[VT] Print '\(Character(scalar))' at (\(cursorX), \(cursorY))")
        }

        cursorX += 1
        if cursorX >= cols {
            cursorX = 0
            cursorY += 1
            if cursorY >= rows {
                scrollUp()
                cursorY = rows - 1
            }
        }
    }

    // Legacy String-based functions (kept for reference but no longer used)
    private func parseEscapeSequence(_ string: String, from start: String.Index) -> String.Index {
        var i = string.index(after: start)
        guard i < string.endIndex else { return i }

        let next = string[i]

        if next == "[" {
            // CSI sequence
            i = string.index(after: i)
            return parseCSI(string, from: i)
        } else if next == "]" {
            // OSC sequence - skip for now
            i = string.index(after: i)
            while i < string.endIndex && string[i] != "\u{07}" && string[i] != "\u{1B}" {
                i = string.index(after: i)
            }
            if i < string.endIndex && string[i] == "\u{07}" {
                i = string.index(after: i)
            }
            return i
        }

        return i
    }

    private func parseCSI(_ string: String, from start: String.Index) -> String.Index {
        var i = start
        var params: [Int] = []
        var currentParam = 0
        var hasParam = false

        while i < string.endIndex {
            let c = string[i]

            if c >= "0" && c <= "9" {
                currentParam = currentParam * 10 + Int(c.asciiValue! - 48)
                hasParam = true
                i = string.index(after: i)
            } else if c == ";" {
                params.append(hasParam ? currentParam : 0)
                currentParam = 0
                hasParam = false
                i = string.index(after: i)
            } else if c >= "@" && c <= "~" {
                // Final byte
                if hasParam {
                    params.append(currentParam)
                }
                executeCSI(c, params: params)
                return string.index(after: i)
            } else {
                // Intermediate bytes or unknown
                i = string.index(after: i)
            }
        }

        return i
    }

    private func executeCSI(_ command: Character, params: [Int]) {
        if Self.debugParsing {
            print("[VT] CSI \(params) \(command)")
        }

        switch command {
        case "H", "f":
            // Cursor position
            cursorY = max(0, min(rows - 1, (params.first ?? 1) - 1))
            cursorX = max(0, min(cols - 1, (params.count > 1 ? params[1] : 1) - 1))

        case "J":
            // Erase display
            let mode = params.first ?? 0
            if mode == 0 {
                // Clear from cursor to end of screen
                let startIndex = cursorY * cols + cursorX
                for i in startIndex..<cells.count {
                    cells[i] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
                }
            } else if mode == 1 {
                // Clear from beginning to cursor
                let endIndex = cursorY * cols + cursorX
                for i in 0...min(endIndex, cells.count - 1) {
                    cells[i] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
                }
            } else if mode == 2 || mode == 3 {
                // Clear entire screen (3 also clears scrollback)
                for i in 0..<cells.count {
                    cells[i] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
                }
            }

        case "K":
            // Erase line
            let mode = params.first ?? 0
            let rowStart = cursorY * cols
            if mode == 0 {
                // Clear to end of line
                for x in cursorX..<cols {
                    cells[rowStart + x] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
                }
            } else if mode == 1 {
                // Clear from beginning of line to cursor
                for x in 0...cursorX {
                    cells[rowStart + x] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
                }
            } else if mode == 2 {
                // Clear entire line
                for x in 0..<cols {
                    cells[rowStart + x] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
                }
            }

        case "m":
            // SGR - Select Graphic Rendition (colors and attributes)
            executeSGR(params)

        case "A":
            // Cursor up
            cursorY = max(0, cursorY - max(1, params.first ?? 1))

        case "B":
            // Cursor down
            cursorY = min(rows - 1, cursorY + max(1, params.first ?? 1))

        case "C":
            // Cursor forward
            cursorX = min(cols - 1, cursorX + max(1, params.first ?? 1))

        case "D":
            // Cursor back
            cursorX = max(0, cursorX - max(1, params.first ?? 1))

        case "G":
            // Cursor horizontal absolute
            cursorX = max(0, min(cols - 1, (params.first ?? 1) - 1))

        case "d":
            // Cursor vertical absolute
            cursorY = max(0, min(rows - 1, (params.first ?? 1) - 1))

        case "E":
            // Cursor next line
            cursorX = 0
            cursorY = min(rows - 1, cursorY + max(1, params.first ?? 1))

        case "F":
            // Cursor previous line
            cursorX = 0
            cursorY = max(0, cursorY - max(1, params.first ?? 1))

        case "L":
            // Insert lines
            let count = max(1, params.first ?? 1)
            for _ in 0..<count {
                insertLine(at: cursorY)
            }

        case "M":
            // Delete lines
            let count = max(1, params.first ?? 1)
            for _ in 0..<count {
                deleteLine(at: cursorY)
            }

        case "P":
            // Delete characters
            let count = max(1, params.first ?? 1)
            deleteCharacters(count: count)

        case "@":
            // Insert characters
            let count = max(1, params.first ?? 1)
            insertCharacters(count: count)

        case "X":
            // Erase characters (replace with spaces)
            let count = max(1, params.first ?? 1)
            let rowStart = cursorY * cols
            for x in cursorX..<min(cursorX + count, cols) {
                cells[rowStart + x] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
            }

        case "r":
            // Set scrolling region - ignore for now (would need scroll margin support)
            break

        case "s":
            // Save cursor position - simplified
            break

        case "u":
            // Restore cursor position - simplified
            break

        case "h", "l":
            // Set/reset mode - ignore most for now
            break

        case "n":
            // Device status report - ignore
            break

        case "c":
            // Device attributes - ignore
            break

        default:
            if Self.debugParsing {
                print("[VT] Unhandled CSI: \\e[\(params.map(String.init).joined(separator: ";"))\(command)")
            }
        }
    }

    // MARK: - SGR (Select Graphic Rendition)

    private func executeSGR(_ params: [Int]) {
        // If no params, treat as reset
        let effectiveParams = params.isEmpty ? [0] : params

        var i = 0
        while i < effectiveParams.count {
            let code = effectiveParams[i]

            switch code {
            case 0:
                // Reset all attributes
                currentFgColor = 0xFFFFFFFF
                currentBgColor = 0xFF080808
                currentFlags = 0

            case 1:
                // Bold
                currentFlags |= RenderCell.flagBold

            case 3:
                // Italic
                currentFlags |= RenderCell.flagItalic

            case 4:
                // Underline
                currentFlags |= RenderCell.flagUnderline

            case 5, 6:
                // Blink
                currentFlags |= RenderCell.flagBlink

            case 7:
                // Inverse
                currentFlags |= RenderCell.flagInverse

            case 8:
                // Invisible
                currentFlags |= RenderCell.flagInvisible

            case 9:
                // Strikethrough
                currentFlags |= RenderCell.flagStrikethrough

            case 22:
                // Not bold
                currentFlags &= ~RenderCell.flagBold

            case 23:
                // Not italic
                currentFlags &= ~RenderCell.flagItalic

            case 24:
                // Not underline
                currentFlags &= ~RenderCell.flagUnderline

            case 25:
                // Not blink
                currentFlags &= ~RenderCell.flagBlink

            case 27:
                // Not inverse
                currentFlags &= ~RenderCell.flagInverse

            case 28:
                // Not invisible
                currentFlags &= ~RenderCell.flagInvisible

            case 29:
                // Not strikethrough
                currentFlags &= ~RenderCell.flagStrikethrough

            case 30...37:
                // Standard foreground colors
                currentFgColor = standardColor(code - 30)

            case 38:
                // Extended foreground color
                if i + 1 < effectiveParams.count {
                    if effectiveParams[i + 1] == 5 && i + 2 < effectiveParams.count {
                        // 256 color mode: 38;5;n
                        currentFgColor = color256(effectiveParams[i + 2])
                        i += 2
                    } else if effectiveParams[i + 1] == 2 && i + 4 < effectiveParams.count {
                        // RGB mode: 38;2;r;g;b
                        let r = UInt32(effectiveParams[i + 2] & 0xFF)
                        let g = UInt32(effectiveParams[i + 3] & 0xFF)
                        let b = UInt32(effectiveParams[i + 4] & 0xFF)
                        currentFgColor = 0xFF000000 | (b << 16) | (g << 8) | r
                        i += 4
                    }
                }

            case 39:
                // Default foreground color
                currentFgColor = 0xFFFFFFFF

            case 40...47:
                // Standard background colors
                currentBgColor = standardColor(code - 40)

            case 48:
                // Extended background color
                if i + 1 < effectiveParams.count {
                    if effectiveParams[i + 1] == 5 && i + 2 < effectiveParams.count {
                        // 256 color mode: 48;5;n
                        currentBgColor = color256(effectiveParams[i + 2])
                        i += 2
                    } else if effectiveParams[i + 1] == 2 && i + 4 < effectiveParams.count {
                        // RGB mode: 48;2;r;g;b
                        let r = UInt32(effectiveParams[i + 2] & 0xFF)
                        let g = UInt32(effectiveParams[i + 3] & 0xFF)
                        let b = UInt32(effectiveParams[i + 4] & 0xFF)
                        currentBgColor = 0xFF000000 | (b << 16) | (g << 8) | r
                        i += 4
                    }
                }

            case 49:
                // Default background color
                currentBgColor = 0xFF080808

            case 90...97:
                // Bright foreground colors
                currentFgColor = brightColor(code - 90)

            case 100...107:
                // Bright background colors
                currentBgColor = brightColor(code - 100)

            default:
                if Self.debugParsing {
                    print("[VT] Unhandled SGR code: \(code)")
                }
            }

            i += 1
        }
    }

    // MARK: - Color Helpers

    private func standardColor(_ index: Int) -> UInt32 {
        // Standard 8 colors (0-7) - format: 0xAABBGGRR
        let colors: [UInt32] = [
            0xFF000000,  // 0: Black
            0xFF0000CD,  // 1: Red
            0xFF00CD00,  // 2: Green
            0xFF00CDCD,  // 3: Yellow
            0xFFCD0000,  // 4: Blue
            0xFFCD00CD,  // 5: Magenta
            0xFFCDCD00,  // 6: Cyan
            0xFFE5E5E5,  // 7: White
        ]
        return colors[index & 7]
    }

    private func brightColor(_ index: Int) -> UInt32 {
        // Bright 8 colors (8-15) - format: 0xAABBGGRR
        let colors: [UInt32] = [
            0xFF7F7F7F,  // 8: Bright Black (Gray)
            0xFF0000FF,  // 9: Bright Red
            0xFF00FF00,  // 10: Bright Green
            0xFF00FFFF,  // 11: Bright Yellow
            0xFFFF0000,  // 12: Bright Blue
            0xFFFF00FF,  // 13: Bright Magenta
            0xFFFFFF00,  // 14: Bright Cyan
            0xFFFFFFFF,  // 15: Bright White
        ]
        return colors[index & 7]
    }

    private func color256(_ index: Int) -> UInt32 {
        if index < 8 {
            return standardColor(index)
        } else if index < 16 {
            return brightColor(index - 8)
        } else if index < 232 {
            // 216 color cube (6x6x6)
            let n = index - 16
            let r = (n / 36) % 6
            let g = (n / 6) % 6
            let b = n % 6
            let rv = UInt32(r == 0 ? 0 : 55 + r * 40)
            let gv = UInt32(g == 0 ? 0 : 55 + g * 40)
            let bv = UInt32(b == 0 ? 0 : 55 + b * 40)
            return 0xFF000000 | (bv << 16) | (gv << 8) | rv
        } else {
            // Grayscale (24 shades)
            let gray = UInt32(8 + (index - 232) * 10)
            return 0xFF000000 | (gray << 16) | (gray << 8) | gray
        }
    }

    // MARK: - Line Operations

    private func insertLine(at row: Int) {
        guard row >= 0 && row < rows else { return }
        // Move lines down
        for r in stride(from: rows - 1, to: row, by: -1) {
            for c in 0..<cols {
                cells[r * cols + c] = cells[(r - 1) * cols + c]
            }
        }
        // Clear the inserted line
        for c in 0..<cols {
            cells[row * cols + c] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
        }
    }

    private func deleteLine(at row: Int) {
        guard row >= 0 && row < rows else { return }
        // Move lines up
        for r in row..<(rows - 1) {
            for c in 0..<cols {
                cells[r * cols + c] = cells[(r + 1) * cols + c]
            }
        }
        // Clear the last line
        for c in 0..<cols {
            cells[(rows - 1) * cols + c] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
        }
    }

    private func insertCharacters(count: Int) {
        let rowStart = cursorY * cols
        // Shift characters right
        for x in stride(from: cols - 1, to: cursorX + count - 1, by: -1) {
            if x - count >= cursorX {
                cells[rowStart + x] = cells[rowStart + x - count]
            }
        }
        // Clear inserted positions
        for x in cursorX..<min(cursorX + count, cols) {
            cells[rowStart + x] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
        }
    }

    private func deleteCharacters(count: Int) {
        let rowStart = cursorY * cols
        // Shift characters left
        for x in cursorX..<(cols - count) {
            cells[rowStart + x] = cells[rowStart + x + count]
        }
        // Clear end of line
        for x in max(cursorX, cols - count)..<cols {
            cells[rowStart + x] = RenderCell(fgColor: currentFgColor, bgColor: currentBgColor)
        }
    }

    private func printChar(_ char: Character) {
        guard cursorX < cols && cursorY < rows else { return }

        let index = cursorY * cols + cursorX
        guard index < cells.count else { return }

        cells[index].codepoint = char.unicodeScalars.first?.value ?? 0
        cells[index].fgColor = currentFgColor
        cells[index].bgColor = currentBgColor
        cells[index].flags = currentFlags

        if Self.debugParsing && char.asciiValue ?? 0 >= 32 {
            // Log printable characters
            print("[VT] Print '\(char)' at (\(cursorX), \(cursorY))")
        }

        cursorX += 1
        if cursorX >= cols {
            cursorX = 0
            cursorY += 1
            if cursorY >= rows {
                scrollUp()
                cursorY = rows - 1
            }
        }
    }

    private func scrollUp() {
        // Move all rows up by one
        for row in 0..<(rows - 1) {
            for col in 0..<cols {
                cells[row * cols + col] = cells[(row + 1) * cols + col]
            }
        }
        // Clear the last row
        let lastRow = (rows - 1) * cols
        for col in 0..<cols {
            cells[lastRow + col] = RenderCell()
        }
    }
}
