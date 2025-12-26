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

    /// Frame coalescing - track last render time to prevent CPU thrashing
    private var lastRenderTime: CFTimeInterval = 0
    private var hasPendingRender: Bool = false

    /// Force render flag - ensures render happens after data feed
    /// This bypasses the native dirty check which can miss updates
    private var needsRender: Bool = true

    /// Input callback - called when user types
    var onInput: ((Data) -> Void)?

    /// Resize callback - called when terminal grid dimensions change
    var onResize: ((Int, Int) -> Void)?  // (cols, rows)

    /// Tracks whether a hardware keyboard is connected
    private var hasHardwareKeyboard: Bool = false

    /// Whether we should auto-show the software keyboard
    private var shouldAutoShowKeyboard: Bool = true

    /// Scroll accumulator for mouse wheel emulation
    private var scrollAccumulator: CGFloat = 0

    /// Threshold for triggering a scroll event (in points)
    private let scrollThreshold: CGFloat = 20.0

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
        self.framebufferOnly = false  // Allow texture reads for thumbnail capture
        self.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)

        // Enable 120Hz on capable devices (iPad Pro)
        if let window = self.window {
            self.preferredFramesPerSecond = window.screen.maximumFramesPerSecond
        } else {
            self.preferredFramesPerSecond = 120  // Default to max, will be capped by hardware
        }

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

        // Setup scroll gesture for TUI mouse wheel support
        setupScrollGesture()

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

    private func setupScrollGesture() {
        // Two-finger pan gesture for scroll wheel emulation
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        addGestureRecognizer(panGesture)
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let terminal = terminal else { return }

        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            scrollAccumulator = 0

        case .changed:
            // Accumulate vertical scroll
            scrollAccumulator += translation.y
            gesture.setTranslation(.zero, in: self)

            // Check if we've crossed the threshold
            while abs(scrollAccumulator) >= scrollThreshold {
                let modes = terminal.getModes()
                let isScrollUp = scrollAccumulator < 0

                if modes.altScreen && modes.mouseAlternateScroll {
                    // In alternate screen with alternate scroll enabled:
                    // Send arrow keys instead of scroll events
                    if isScrollUp {
                        sendEscapeSequence("[A") // Up arrow
                    } else {
                        sendEscapeSequence("[B") // Down arrow
                    }
                } else if modes.mouseEventNormal || modes.mouseEventButton || modes.mouseEventAny {
                    // Mouse tracking enabled: send SGR mouse wheel events
                    // Button 64 = wheel up, 65 = wheel down
                    let button = isScrollUp ? 64 : 65
                    let col = max(1, cols / 2)  // Center of terminal
                    let row = max(1, rows / 2)

                    if modes.mouseFormatSGR {
                        // SGR format: CSI < button ; col ; row M
                        let sequence = "\u{1B}[<\(button);\(col);\(row)M"
                        if let data = sequence.data(using: .utf8) {
                            onInput?(data)
                        }
                    } else {
                        // Legacy format (less common now)
                        let sequence = "\u{1B}[M\(Character(UnicodeScalar(32 + button)!))\(Character(UnicodeScalar(32 + col)!))\(Character(UnicodeScalar(32 + row)!))"
                        if let data = sequence.data(using: .utf8) {
                            onInput?(data)
                        }
                    }
                }
                // Note: If no mouse mode and not in alt screen, we could implement
                // scrollback here, but that's a separate feature

                // Consume the threshold amount
                if isScrollUp {
                    scrollAccumulator += scrollThreshold
                } else {
                    scrollAccumulator -= scrollThreshold
                }
            }

        case .ended, .cancelled:
            scrollAccumulator = 0

        default:
            break
        }
    }

    /// Called when the view is added to a window - good time to auto-show keyboard
    override func didMoveToWindow() {
        super.didMoveToWindow()

        // Update preferred frame rate based on screen capabilities
        if let window = self.window {
            self.preferredFramesPerSecond = window.screen.maximumFramesPerSecond
            print("[Terminal] Updated frame rate to \(window.screen.maximumFramesPerSecond)Hz")
        }

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
        print("[TerminalView] feed() called with \(data.count) bytes, metalAvailable=\(metalAvailable), pipelineState=\(pipelineState != nil)")
        terminal?.feed(data)
        updateCellsFromTerminal()
        print("[TerminalView] After feed: cells.count=\(cells.count), grid=\(cols)x\(rows)")
        needsRender = true
        setNeedsDisplay()
    }

    /// Feed a string to the terminal
    func feed(_ string: String) {
        terminal?.feed(string)
        updateCellsFromTerminal()
        needsRender = true
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
        needsRender = true
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

    // MARK: - Frame Coalescing

    /// Helper to trigger actual display update
    private func triggerDisplay() {
        super.setNeedsDisplay()
    }

    /// Override setNeedsDisplay to implement frame coalescing
    /// Prevents CPU thrashing when data arrives faster than frame rate
    override func setNeedsDisplay() {
        let now = CACurrentMediaTime()
        let minFrameInterval = 1.0 / 120.0  // Max 120 FPS

        // If we already have a pending render scheduled, don't schedule another
        guard !hasPendingRender else {
            return
        }

        // If enough time has passed since last render, render immediately
        if now - lastRenderTime >= minFrameInterval {
            triggerDisplay()
            lastRenderTime = now
        } else {
            // Schedule a deferred render after the minimum frame interval
            hasPendingRender = true
            let delay = minFrameInterval - (now - lastRenderTime)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.hasPendingRender = false
                self.lastRenderTime = CACurrentMediaTime()
                self.triggerDisplay()
            }
        }
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
        // Don't render if view bounds are invalid (prevents drawable allocation failures)
        guard bounds.width > 0 && bounds.height > 0 else {
            return
        }

        // If Metal rendering isn't available, just clear the view
        guard metalAvailable else {
            print("[TerminalView] draw() - Metal not available!")
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
              let pipelineState = pipelineState else {
            return
        }

        // Check drawable availability separately to provide better diagnostics
        guard let drawable = currentDrawable else {
            print("[TerminalView] draw() - No drawable available, bounds=\(bounds.size)")
            return
        }

        guard let renderPassDescriptor = currentRenderPassDescriptor else {
            return
        }

        // Skip render if terminal hasn't changed
        // Use both native dirty flag and Swift needsRender flag for reliability
        guard let terminal = terminal else {
            // No terminal - present empty drawable
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let nativeDirty = terminal.checkDirty()
        guard nativeDirty || needsRender else {
            // Nothing to render - present empty drawable to maintain frame timing
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        needsRender = false  // Clear our flag

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

        // Clear dirty flag after successful render
        terminal.clearDirty()
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

    /// Handle paste with bracketed paste mode support
    override func paste(_ sender: Any?) {
        guard let string = UIPasteboard.general.string else { return }
        pasteString(string)
    }

    /// Paste a string, wrapping with bracketed paste sequences if mode is enabled
    func pasteString(_ string: String) {
        guard let terminal = terminal else {
            // No terminal, just send raw
            if let data = string.data(using: .utf8) {
                onInput?(data)
            }
            return
        }

        let modes = terminal.getModes()

        if modes.bracketedPaste {
            // Wrap paste with bracketed paste sequences
            // CSI 200 ~ ... CSI 201 ~
            let startBracket = "\u{1B}[200~"
            let endBracket = "\u{1B}[201~"
            let wrapped = startBracket + string + endBracket
            if let data = wrapped.data(using: .utf8) {
                onInput?(data)
            }
        } else {
            // Regular paste
            if let data = string.data(using: .utf8) {
                onInput?(data)
            }
        }
    }

    // MARK: - First Responder

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        // Send mouse press event to terminal
        if let touch = touches.first {
            let location = touch.location(in: self)
            sendMouseEvent(location: location, isPress: true)
        }

        // Become first responder to show keyboard
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)

        // Send mouse release event to terminal
        if let touch = touches.first {
            let location = touch.location(in: self)
            sendMouseEvent(location: location, isPress: false)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        // Send mouse drag event to terminal (button 0 + 32 for drag)
        if let touch = touches.first {
            let location = touch.location(in: self)
            sendMouseEvent(location: location, isPress: true, isDrag: true)
        }
    }

    /// Convert tap location to terminal cell coordinates and send mouse event
    private func sendMouseEvent(location: CGPoint, isPress: Bool, isDrag: Bool = false) {
        // Convert point coordinates to cell coordinates
        let col = Int(location.x / cellWidth) + 1  // 1-based
        let row = Int(location.y / cellHeight) + 1  // 1-based

        // Clamp to valid grid bounds
        let clampedCol = max(1, min(col, cols))
        let clampedRow = max(1, min(row, rows))

        // SGR mouse encoding: CSI < button ; x ; y M/m
        // M for press, m for release
        // button: 0 = left click, 32 = drag
        let button = isDrag ? 32 : 0
        let suffix = isPress ? "M" : "m"
        let sequence = "\u{1B}[<\(button);\(clampedCol);\(clampedRow)\(suffix)"

        print("[Mouse] \(isDrag ? "Drag" : (isPress ? "Press" : "Release")) at (\(location.x), \(location.y)) -> cell (\(clampedCol), \(clampedRow)) -> \(sequence.debugDescription)")

        if let data = sequence.data(using: .utf8) {
            onInput?(data)
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

        // Shift + Arrow keys (for selection)
        commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .shift, action: #selector(handleShiftArrowUp)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .shift, action: #selector(handleShiftArrowDown)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .shift, action: #selector(handleShiftArrowLeft)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .shift, action: #selector(handleShiftArrowRight)))

        // Escape key
        commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)))

        // Tab
        commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)))

        // Control + letter combinations (a-z)
        for char in "abcdefghijklmnopqrstuvwxyz" {
            commands.append(UIKeyCommand(input: String(char), modifierFlags: .control, action: #selector(handleControlKey(_:))))
        }

        // Command + V for paste (with bracketed paste support)
        commands.append(UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(handlePaste)))

        // Command + C for copy (if selection exists, otherwise send Ctrl+C)
        commands.append(UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(handleCopy)))

        // Alt/Option + letter combinations (a-z)
        // Standard terminal behavior: Alt+key sends ESC followed by the key
        for char in "abcdefghijklmnopqrstuvwxyz" {
            commands.append(UIKeyCommand(input: String(char), modifierFlags: .alternate, action: #selector(handleAltKey(_:))))
        }

        // Function keys F1-F12
        commands.append(UIKeyCommand(input: UIKeyCommand.f1, modifierFlags: [], action: #selector(handleF1)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f2, modifierFlags: [], action: #selector(handleF2)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f3, modifierFlags: [], action: #selector(handleF3)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f4, modifierFlags: [], action: #selector(handleF4)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f5, modifierFlags: [], action: #selector(handleF5)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f6, modifierFlags: [], action: #selector(handleF6)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f7, modifierFlags: [], action: #selector(handleF7)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f8, modifierFlags: [], action: #selector(handleF8)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f9, modifierFlags: [], action: #selector(handleF9)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f10, modifierFlags: [], action: #selector(handleF10)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f11, modifierFlags: [], action: #selector(handleF11)))
        commands.append(UIKeyCommand(input: UIKeyCommand.f12, modifierFlags: [], action: #selector(handleF12)))

        // Special navigation keys
        if #available(iOS 13.4, *) {
            commands.append(UIKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: [], action: #selector(handleHome)))
            commands.append(UIKeyCommand(input: UIKeyCommand.inputEnd, modifierFlags: [], action: #selector(handleEnd)))
            commands.append(UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(handlePageUp)))
            commands.append(UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(handlePageDown)))
        }

        // Delete key (forward delete, not backspace)
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(handleDelete)))

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

    @objc private func handlePaste() {
        paste(nil)
    }

    @objc private func handleCopy() {
        // TODO: If text selection is implemented, copy selection here
        // For now, send Ctrl+C (interrupt) to the terminal
        onInput?(Data([0x03]))  // Ctrl+C
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

    /// Handle Alt/Option + key combinations
    /// Standard terminal behavior: sends ESC followed by the character
    @objc private func handleAltKey(_ command: UIKeyCommand) {
        guard let input = command.input, let char = input.first else { return }
        // Alt+key sends ESC (0x1B) followed by the character
        var data = Data([0x1B])  // ESC
        if let charData = String(char).data(using: .utf8) {
            data.append(charData)
        }
        onInput?(data)
    }

    // Shift + Arrow keys (for selection in terminal)
    @objc private func handleShiftArrowUp() {
        sendEscapeSequence("[1;2A")
    }

    @objc private func handleShiftArrowDown() {
        sendEscapeSequence("[1;2B")
    }

    @objc private func handleShiftArrowRight() {
        sendEscapeSequence("[1;2C")
    }

    @objc private func handleShiftArrowLeft() {
        sendEscapeSequence("[1;2D")
    }

    // Function keys F1-F12 (ANSI sequences)
    @objc private func handleF1() {
        sendEscapeSequence("[11~")
    }

    @objc private func handleF2() {
        sendEscapeSequence("[12~")
    }

    @objc private func handleF3() {
        sendEscapeSequence("[13~")
    }

    @objc private func handleF4() {
        sendEscapeSequence("[14~")
    }

    @objc private func handleF5() {
        sendEscapeSequence("[15~")
    }

    @objc private func handleF6() {
        sendEscapeSequence("[17~")
    }

    @objc private func handleF7() {
        sendEscapeSequence("[18~")
    }

    @objc private func handleF8() {
        sendEscapeSequence("[19~")
    }

    @objc private func handleF9() {
        sendEscapeSequence("[20~")
    }

    @objc private func handleF10() {
        sendEscapeSequence("[21~")
    }

    @objc private func handleF11() {
        sendEscapeSequence("[23~")
    }

    @objc private func handleF12() {
        sendEscapeSequence("[24~")
    }

    // Special navigation keys
    @objc private func handleHome() {
        sendEscapeSequence("[H")
    }

    @objc private func handleEnd() {
        sendEscapeSequence("[F")
    }

    @objc private func handlePageUp() {
        sendEscapeSequence("[5~")
    }

    @objc private func handlePageDown() {
        sendEscapeSequence("[6~")
    }

    @objc private func handleDelete() {
        sendEscapeSequence("[3~")
    }

    // TODO: IME Support for CJK Input
    // Full UITextInput protocol conformance is needed for proper CJK (Chinese, Japanese, Korean) input.
    // This requires implementing:
    // - UITextInput protocol methods (textIn/textRange/marked text handling)
    // - UITextInputDelegate for composition events
    // - Proper handling of multi-stage character composition
    // - Integration with iOS Input Method Editors (IME)
    // Reference: https://developer.apple.com/documentation/uikit/uitextinput

    // MARK: - Thumbnail Capture

    /// Capture the current Metal framebuffer as a UIImage
    /// Returns a scaled-down thumbnail (1/4 size) for memory efficiency
    func captureSnapshot() -> UIImage? {
        guard let drawable = currentDrawable else {
            print("[WilloTerminalView] captureSnapshot: No drawable available")
            return nil
        }
        let texture = drawable.texture

        // Get texture dimensions
        let textureWidth = texture.width
        let textureHeight = texture.height

        // Scale down to 1/4 size for thumbnails
        let thumbnailWidth = textureWidth / 4
        let thumbnailHeight = textureHeight / 4

        // Create a temporary texture descriptor for reading
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: textureWidth,
            height: textureHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared

        // Read pixel data from the drawable texture
        let bytesPerPixel = 4  // BGRA8Unorm
        let bytesPerRow = bytesPerPixel * textureWidth
        let dataSize = bytesPerRow * textureHeight
        var pixelData = [UInt8](repeating: 0, count: dataSize)

        // Get the texture data
        let region = MTLRegionMake2D(0, 0, textureWidth, textureHeight)
        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: region,
            mipmapLevel: 0
        )

        // Create a CGImage from the pixel data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)

        guard let dataProvider = CGDataProvider(
            data: Data(pixelData) as CFData
        ) else {
            print("[WilloTerminalView] captureSnapshot: Failed to create data provider")
            return nil
        }

        guard let cgImage = CGImage(
            width: textureWidth,
            height: textureHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            print("[WilloTerminalView] captureSnapshot: Failed to create CGImage")
            return nil
        }

        // Scale down to thumbnail size using UIGraphicsImageRenderer
        let thumbnailSize = CGSize(width: thumbnailWidth, height: thumbnailHeight)
        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        let thumbnail = renderer.image { context in
            // Flip the image (Metal textures are upside down)
            context.cgContext.translateBy(x: 0, y: thumbnailSize.height)
            context.cgContext.scaleBy(x: 1, y: -1)

            // Draw the scaled image
            context.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: thumbnailSize))
        }

        return thumbnail
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
