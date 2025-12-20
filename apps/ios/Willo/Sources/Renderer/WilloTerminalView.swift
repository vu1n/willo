import MetalKit
#if os(iOS)
import UIKit
import GameController
#else
import AppKit
#endif

#if os(iOS)
/// Custom Metal-based terminal view for Willo
///
/// This view renders terminal content using Metal for optimal performance.
/// It uses a glyph atlas for text rendering and supports 120fps on iPad Pro.
///
/// Architecture:
///   1. Glyph atlas (GlyphAtlas.swift) - CoreText → Metal texture
///   2. Grid buffer - Flat array of cells from Ghostty VT parser
///   3. Shaders (TerminalShaders.metal) - GPU-accelerated rendering
final class WilloTerminalView: MTKView, MTKViewDelegate, UIKeyInput {

    // MARK: - Types

    /// Type alias for render cell from WilloTerminal
    typealias RenderCell = WilloTerminal.RenderCell

    /// Vertex for cell rendering
    struct CellVertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
        var fgColor: SIMD4<Float>
        var bgColor: SIMD4<Float>
    }

    /// Uniforms passed to shaders
    struct Uniforms {
        var viewportSize: SIMD2<Float>
        var cellSize: SIMD2<Float>
        var gridSize: SIMD2<UInt32>
        var time: Float
        var padding: Float
    }

    // MARK: - Properties

    /// Terminal dimensions
    private(set) var rows: Int = 24
    private(set) var cols: Int = 80

    /// Cell size in points (updated from glyph atlas)
    private var cellWidth: CGFloat = 12.0
    private var cellHeight: CGFloat = 24.0

    /// Metal resources
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var glyphAtlas: GlyphAtlas?

    /// Render buffers
    private var vertexBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var cellBuffer: MTLBuffer?

    /// Terminal instance (Ghostty VT parser wrapper)
    private var terminal: WilloTerminal?

    /// Grid data
    private var cells: [RenderCell] = []

    /// Animation
    private var startTime: CFTimeInterval = 0

    /// Input callback - called when user types
    var onInput: ((Data) -> Void)?

    /// Resize callback - called when terminal grid dimensions change
    var onResize: ((Int, Int) -> Void)?  // (cols, rows)

    /// Tracks whether a hardware keyboard is connected
    private var hasHardwareKeyboard: Bool = false

    /// Whether we should auto-show the software keyboard
    private var shouldAutoShowKeyboard: Bool = true

    // MARK: - Initialization

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    convenience init(frame: CGRect = .zero) {
        self.init(frame: frame, device: MTLCreateSystemDefaultDevice())
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether Metal rendering is available
    private var metalAvailable = false

    private func commonInit() {
        guard let device = self.device else {
            print("WilloTerminalView: No Metal device available")
            return
        }

        // Configure MTKView
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
        self.preferredFramesPerSecond = 60
        self.isPaused = true  // Don't use automatic render loop
        self.enableSetNeedsDisplay = true  // Only render when setNeedsDisplay() called

        // Create command queue
        commandQueue = device.makeCommandQueue()

        // Create glyph atlas - 24pt is good for iPad retina displays
        glyphAtlas = GlyphAtlas(device: device, fontSize: 24.0)

        // Use atlas cell metrics for proper sizing
        if let atlas = glyphAtlas {
            cellWidth = atlas.cellWidth > 0 ? atlas.cellWidth : 12.0
            cellHeight = atlas.cellHeight > 0 ? atlas.cellHeight : 24.0
            print("[Terminal] Cell size from atlas: \(cellWidth)x\(cellHeight)")
        }

        // Create pipeline state - may fail if shaders aren't compiled
        setupPipeline(device: device)

        // Initialize terminal with VT parser
        initializeTerminal()

        startTime = CACurrentMediaTime()

        // Check if Metal rendering is fully available
        metalAvailable = pipelineState != nil && commandQueue != nil
        if !metalAvailable {
            print("WilloTerminalView: Metal rendering unavailable, using fallback")
        }

        // Setup hardware keyboard detection
        setupKeyboardDetection()

        // Trigger initial render
        setNeedsDisplay()
    }

    private func setupKeyboardDetection() {
        // Check initial keyboard state
        hasHardwareKeyboard = GCKeyboard.coalesced != nil
        print("[Keyboard] Initial state - hardware keyboard: \(hasHardwareKeyboard)")

        // Subscribe to keyboard connection notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidConnect),
            name: .GCKeyboardDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidDisconnect),
            name: .GCKeyboardDidDisconnect,
            object: nil
        )
    }

    @objc private func keyboardDidConnect(_ notification: Notification) {
        hasHardwareKeyboard = true
        print("[Keyboard] Hardware keyboard connected")
    }

    @objc private func keyboardDidDisconnect(_ notification: Notification) {
        hasHardwareKeyboard = GCKeyboard.coalesced != nil
        print("[Keyboard] Hardware keyboard disconnected, remaining: \(hasHardwareKeyboard)")

        // Show software keyboard if no hardware keyboard and we should auto-show
        if !hasHardwareKeyboard && shouldAutoShowKeyboard && !isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                self?.becomeFirstResponder()
            }
        }
    }

    /// Called when the view is added to a window - good time to auto-show keyboard
    override func didMoveToWindow() {
        super.didMoveToWindow()

        // Auto-show software keyboard when no hardware keyboard is attached
        if window != nil && !hasHardwareKeyboard && shouldAutoShowKeyboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.window != nil else { return }
                if !self.isFirstResponder {
                    self.becomeFirstResponder()
                }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Recalculate grid size on layout changes
        let size = bounds.size
        print("[Terminal] layoutSubviews called - bounds: \(size), cellSize: \(cellWidth)x\(cellHeight)")
        guard size.width > 0 && size.height > 0 else {
            print("[Terminal] layoutSubviews - bounds are zero, skipping")
            return
        }

        let newCols = max(1, Int(size.width / cellWidth))
        let newRows = max(1, Int(size.height / cellHeight))

        print("[Terminal] layoutSubviews - calculated grid: \(newCols)x\(newRows), current: \(cols)x\(rows)")
        if newCols != cols || newRows != rows {
            print("[Terminal] layoutSubviews: \(size), grid: \(newCols)x\(newRows)")
            resizeGrid(rows: newRows, cols: newCols)
        }
    }

    // MARK: - Pipeline Setup

    private func setupPipeline(device: MTLDevice) {
        // Try to load Metal library from package bundle first, then default
        let library: MTLLibrary?
        if let bundleLibrary = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = bundleLibrary
            print("WilloTerminalView: Loaded Metal library from Bundle.module")
        } else if let defaultLibrary = device.makeDefaultLibrary() {
            library = defaultLibrary
            print("WilloTerminalView: Loaded Metal library from default bundle")
        } else {
            print("WilloTerminalView: Failed to load Metal library from any bundle")
            library = nil
        }

        guard let library = library else {
            print("WilloTerminalView: No Metal library available")
            return
        }

        let vertexFunction = library.makeFunction(name: "terminalVertex")
        let fragmentFunction = library.makeFunction(name: "terminalFragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        // Enable alpha blending for glyph rendering
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Vertex descriptor for CellVertex
        let vertexDescriptor = MTLVertexDescriptor()
        // position
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // texCoord
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        // fgColor
        vertexDescriptor.attributes[2].format = .float4
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD2<Float>>.stride * 2
        vertexDescriptor.attributes[2].bufferIndex = 0
        // bgColor
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD2<Float>>.stride * 2 + MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.attributes[3].bufferIndex = 0

        vertexDescriptor.layouts[0].stride = MemoryLayout<CellVertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        pipelineDescriptor.vertexDescriptor = vertexDescriptor

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("WilloTerminalView: Failed to create pipeline state: \(error)")
        }

        // Create uniform buffer
        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )
    }

    // MARK: - Terminal Setup

    private func initializeTerminal() {
        // Create terminal with VT parser
        terminal = WilloTerminal(rows: rows, cols: cols)

        // Feed some test data
        let testSequences = [
            "\u{1B}[2J\u{1B}[H",  // Clear screen, move to home
            "\u{1B}[1;32mWillo Terminal\u{1B}[0m - Metal Renderer Test\r\n\r\n",
            "\u{1B}[31mRed \u{1B}[32mGreen \u{1B}[33mYellow \u{1B}[34mBlue \u{1B}[35mMagenta \u{1B}[36mCyan\u{1B}[0m\r\n\r\n",
            "\u{1B}[1mBold\u{1B}[0m \u{1B}[3mItalic\u{1B}[0m \u{1B}[4mUnderline\u{1B}[0m\r\n\r\n",
            "\u{1B}[1;34muser@willo\u{1B}[0m:\u{1B}[1;36m~/code\u{1B}[0m$ ",
        ]

        for sequence in testSequences {
            terminal?.feed(sequence)
        }

        // Get rendered cells
        updateCellsFromTerminal()
    }

    private func updateCellsFromTerminal() {
        guard let terminal = terminal else {
            // Fallback to empty grid
            cells = [RenderCell](repeating: RenderCell(), count: rows * cols)
            return
        }

        cells = terminal.render()
    }

    // MARK: - Public API

    /// Feed data to the terminal (ANSI sequences, UTF-8 text)
    func feed(_ data: Data) {
        terminal?.feed(data)
        updateCellsFromTerminal()
        setNeedsDisplay()
    }

    /// Feed a string to the terminal
    func feed(_ string: String) {
        terminal?.feed(string)
        updateCellsFromTerminal()
        setNeedsDisplay()
    }

    /// Update the terminal grid with new cell data
    func updateGrid(cells: [RenderCell]) {
        self.cells = cells
    }

    /// Resize the terminal grid
    func resizeGrid(rows: Int, cols: Int) {
        print("[Terminal] Resizing grid to \(cols)x\(rows)")
        self.rows = rows
        self.cols = cols

        terminal?.resize(rows: rows, cols: cols)
        updateCellsFromTerminal()
        setNeedsDisplay()

        // Notify transport of resize
        onResize?(cols, rows)
    }

    /// Update font size and rebuild glyph atlas
    func updateFontSize(_ newSize: CGFloat) {
        guard let device = self.device else {
            print("[Terminal] updateFontSize - NO DEVICE!")
            return
        }

        let clampedSize = max(14.0, min(32.0, newSize))
        print("[Terminal] ===== updateFontSize START =====")
        print("[Terminal] Requested: \(newSize)pt, clamped: \(clampedSize)pt")
        print("[Terminal] BEFORE - cellWidth: \(cellWidth), cellHeight: \(cellHeight), grid: \(cols)x\(rows)")

        // Rebuild glyph atlas with new size
        glyphAtlas = GlyphAtlas(device: device, fontSize: clampedSize)

        // Update cell metrics - ALWAYS update, don't keep old values
        if let atlas = glyphAtlas {
            let oldWidth = cellWidth
            let oldHeight = cellHeight
            cellWidth = atlas.cellWidth
            cellHeight = atlas.cellHeight
            print("[Terminal] Atlas returned: cellWidth=\(atlas.cellWidth), cellHeight=\(atlas.cellHeight)")
            print("[Terminal] Cell size changed: \(oldWidth)x\(oldHeight) → \(cellWidth)x\(cellHeight)")

            // Sanity check - if atlas returns 0, something is very wrong
            if cellWidth <= 0 || cellHeight <= 0 {
                print("[Terminal] ERROR: Atlas returned invalid cell size! Using fallback.")
                cellWidth = ceil(clampedSize * 0.6)
                cellHeight = ceil(clampedSize * 1.2)
                print("[Terminal] Fallback cell size: \(cellWidth)x\(cellHeight)")
            }
        } else {
            print("[Terminal] ERROR: GlyphAtlas creation failed!")
            cellWidth = ceil(clampedSize * 0.6)
            cellHeight = ceil(clampedSize * 1.2)
        }

        // Recalculate grid dimensions based on new cell size
        let size = bounds.size
        print("[Terminal] View bounds: \(size.width)x\(size.height)")

        if size.width > 0 && size.height > 0 {
            let newCols = max(1, Int(size.width / cellWidth))
            let newRows = max(1, Int(size.height / cellHeight))

            print("[Terminal] Grid calculation: \(size.width)/\(cellWidth) = \(newCols) cols")
            print("[Terminal] Grid calculation: \(size.height)/\(cellHeight) = \(newRows) rows")
            print("[Terminal] Current grid: \(cols)x\(rows), New grid: \(newCols)x\(newRows)")

            // ALWAYS resize on font change - even if grid dimensions happen to match
            print("[Terminal] RESIZING GRID: \(cols)x\(rows) → \(newCols)x\(newRows)")
            resizeGrid(rows: newRows, cols: newCols)
        } else {
            print("[Terminal] WARNING: bounds are zero (\(size)), skipping resize")
            setNeedsDisplay()
        }
        print("[Terminal] ===== updateFontSize END =====")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Recalculate grid dimensions based on new size
        // Use scale factor to get proper cell count
        let scale = view.contentScaleFactor
        let pointWidth = size.width / scale
        let pointHeight = size.height / scale

        let newCols = max(1, Int(pointWidth / cellWidth))
        let newRows = max(1, Int(pointHeight / cellHeight))

        print("[Terminal] Drawable size changed: \(size), scale: \(scale), grid: \(newCols)x\(newRows)")

        if newCols != cols || newRows != rows {
            resizeGrid(rows: newRows, cols: newCols)
        } else {
            // Size changed but grid didn't - still need to redraw
            setNeedsDisplay()
        }
    }

    func draw(in view: MTKView) {
        // If Metal rendering isn't available, just clear the view
        guard metalAvailable else {
            // Fallback: Just present a cleared drawable
            guard let drawable = currentDrawable,
                  let commandQueue = commandQueue,
                  let renderPassDescriptor = currentRenderPassDescriptor else {
                return
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        guard let device = device,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState,
              let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor else {
            return
        }

        // Scale factor to convert points to pixels
        let scale = contentScaleFactor

        // Update uniforms - all in pixels
        let currentTime = Float(CACurrentMediaTime() - startTime)
        var uniforms = Uniforms(
            viewportSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            cellSize: SIMD2<Float>(Float(cellWidth * scale), Float(cellHeight * scale)),
            gridSize: SIMD2<UInt32>(UInt32(cols), UInt32(rows)),
            time: currentTime,
            padding: 0
        )

        uniformBuffer?.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<Uniforms>.stride
        )

        // Build vertex buffer for visible cells
        var vertices: [CellVertex] = []
        vertices.reserveCapacity(cells.count * 6)  // 6 vertices per cell (2 triangles)

        // Cell dimensions in pixels
        let cellW = Float(cellWidth * scale)
        let cellH = Float(cellHeight * scale)

        for row in 0..<rows {
            for col in 0..<cols {
                let cellIndex = row * cols + col
                guard cellIndex < cells.count else { continue }

                let cell = cells[cellIndex]
                let x = Float(col) * cellW
                let y = Float(row) * cellH
                let w = cellW
                let h = cellH

                let fgColor = unpackColor(cell.fgColor)
                let bgColor = unpackColor(cell.bgColor)

                // Cursor cell gets inverted colors
                let finalFg: SIMD4<Float>
                let finalBg: SIMD4<Float>
                if cell.flags & RenderCell.flagCursor != 0 {
                    finalFg = bgColor
                    finalBg = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)  // Light cursor block
                } else {
                    finalFg = fgColor
                    finalBg = bgColor
                }

                // Get glyph texture coordinates from atlas
                let isBold = cell.flags & RenderCell.flagBold != 0
                let isItalic = cell.flags & RenderCell.flagItalic != 0

                // Texture coordinates - default to 0 if no glyph (shows background only)
                var texLeft: Float = 0
                var texTop: Float = 0
                var texRight: Float = 0
                var texBottom: Float = 0

                // Look up glyph in atlas if there's a character
                if cell.codepoint >= 32 {  // Only lookup printable chars
                    if let glyphInfo = glyphAtlas?.getGlyph(
                        codepoint: cell.codepoint,
                        bold: isBold,
                        italic: isItalic
                    ) {
                        let tc = glyphInfo.texCoords
                        texLeft = Float(tc.minX)
                        texRight = Float(tc.maxX)
                        texTop = Float(tc.minY)
                        texBottom = Float(tc.maxY)
                    }
                }

                // Two triangles per cell (quad)
                // Triangle 1: top-left, top-right, bottom-left
                vertices.append(CellVertex(
                    position: SIMD2<Float>(x, y),
                    texCoord: SIMD2<Float>(texLeft, texTop),
                    fgColor: finalFg,
                    bgColor: finalBg
                ))
                vertices.append(CellVertex(
                    position: SIMD2<Float>(x + w, y),
                    texCoord: SIMD2<Float>(texRight, texTop),
                    fgColor: finalFg,
                    bgColor: finalBg
                ))
                vertices.append(CellVertex(
                    position: SIMD2<Float>(x, y + h),
                    texCoord: SIMD2<Float>(texLeft, texBottom),
                    fgColor: finalFg,
                    bgColor: finalBg
                ))

                // Triangle 2: top-right, bottom-right, bottom-left
                vertices.append(CellVertex(
                    position: SIMD2<Float>(x + w, y),
                    texCoord: SIMD2<Float>(texRight, texTop),
                    fgColor: finalFg,
                    bgColor: finalBg
                ))
                vertices.append(CellVertex(
                    position: SIMD2<Float>(x + w, y + h),
                    texCoord: SIMD2<Float>(texRight, texBottom),
                    fgColor: finalFg,
                    bgColor: finalBg
                ))
                vertices.append(CellVertex(
                    position: SIMD2<Float>(x, y + h),
                    texCoord: SIMD2<Float>(texLeft, texBottom),
                    fgColor: finalFg,
                    bgColor: finalBg
                ))
            }
        }

        // Create or update vertex buffer
        let vertexDataSize = vertices.count * MemoryLayout<CellVertex>.stride
        if vertexBuffer == nil || vertexBuffer!.length < vertexDataSize {
            vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: vertexDataSize,
                options: .storageModeShared
            )
        } else {
            vertexBuffer?.contents().copyMemory(
                from: vertices,
                byteCount: vertexDataSize
            )
        }

        // Encode render commands
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)

        if let atlas = glyphAtlas {
            renderEncoder.setFragmentTexture(atlas.texture, index: 0)
        }

        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Color Helpers

    private func unpackColor(_ packed: UInt32) -> SIMD4<Float> {
        // Format: 0xAABBGGRR
        let r = Float((packed >> 0) & 0xFF) / 255.0
        let g = Float((packed >> 8) & 0xFF) / 255.0
        let b = Float((packed >> 16) & 0xFF) / 255.0
        let a = Float((packed >> 24) & 0xFF) / 255.0
        return SIMD4<Float>(r, g, b, a)
    }

    private func packColor(r: Float, g: Float, b: Float, a: Float = 1.0) -> UInt32 {
        let ri = UInt32(min(max(r * 255, 0), 255))
        let gi = UInt32(min(max(g * 255, 0), 255))
        let bi = UInt32(min(max(b * 255, 0), 255))
        let ai = UInt32(min(max(a * 255, 0), 255))
        return (ai << 24) | (bi << 16) | (gi << 8) | ri
    }

    private func hsbToRGB(h: Float, s: Float, b: Float) -> (r: Float, g: Float, b: Float) {
        let c = b * s
        let x = c * (1 - abs(fmod(h * 6, 2) - 1))
        let m = b - c

        var r: Float = 0, g: Float = 0, bl: Float = 0
        let hi = Int(h * 6) % 6

        switch hi {
        case 0: (r, g, bl) = (c, x, 0)
        case 1: (r, g, bl) = (x, c, 0)
        case 2: (r, g, bl) = (0, c, x)
        case 3: (r, g, bl) = (0, x, c)
        case 4: (r, g, bl) = (x, 0, c)
        case 5: (r, g, bl) = (c, 0, x)
        default: break
        }

        return (r + m, g + m, bl + m)
    }

    // MARK: - UIKeyInput

    var hasText: Bool {
        return true  // Always report having text to accept input
    }

    func insertText(_ text: String) {
        print("[Input] insertText: '\(text)' (\(text.count) chars)")
        if let data = text.data(using: .utf8) {
            onInput?(data)
        }
    }

    func deleteBackward() {
        // Send backspace (DEL character)
        let backspace = Data([0x7F])
        onInput?(backspace)
    }

    // MARK: - First Responder

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // Become first responder to show keyboard
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    // MARK: - Hardware Keyboard Support

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        // Arrow keys
        commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleArrowUp)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleArrowDown)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleArrowLeft)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleArrowRight)))

        // Escape key
        commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)))

        // Tab
        commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)))

        // Control + letter combinations (a-z)
        for char in "abcdefghijklmnopqrstuvwxyz" {
            commands.append(UIKeyCommand(input: String(char), modifierFlags: .control, action: #selector(handleControlKey(_:))))
        }

        return commands
    }

    @objc private func handleArrowUp() {
        sendEscapeSequence("[A")
    }

    @objc private func handleArrowDown() {
        sendEscapeSequence("[B")
    }

    @objc private func handleArrowRight() {
        sendEscapeSequence("[C")
    }

    @objc private func handleArrowLeft() {
        sendEscapeSequence("[D")
    }

    @objc private func handleEscape() {
        onInput?(Data([0x1B]))  // ESC
    }

    @objc private func handleTab() {
        onInput?(Data([0x09]))  // TAB
    }

    @objc private func handleControlKey(_ command: UIKeyCommand) {
        guard let input = command.input, let char = input.first else { return }
        // Ctrl+A = 0x01, Ctrl+B = 0x02, ..., Ctrl+Z = 0x1A
        let controlCode = UInt8(char.asciiValue! - 0x60)
        onInput?(Data([controlCode]))
    }

    private func sendEscapeSequence(_ sequence: String) {
        var data = Data([0x1B])  // ESC
        if let seqData = sequence.data(using: .utf8) {
            data.append(seqData)
        }
        onInput?(data)
    }
}
#else
// macOS stub - the full implementation is iOS-only
final class WilloTerminalView: MTKView, MTKViewDelegate {
    typealias RenderCell = WilloTerminal.RenderCell

    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    private(set) var rows: Int = 24
    private(set) var cols: Int = 80
    private var terminal: WilloTerminal?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        self.delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    convenience init(frame: CGRect = .zero) {
        self.init(frame: frame, device: MTLCreateSystemDefaultDevice())
    }

    func feed(_ data: Data) {}
    func feed(_ string: String) {}
    func updateGrid(cells: [RenderCell]) {}
    func resizeGrid(rows: Int, cols: Int) {}

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {}
}
#endif
