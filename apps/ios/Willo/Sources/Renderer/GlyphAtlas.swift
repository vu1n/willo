import CoreText
import MetalKit
import UIKit

/// Glyph atlas for terminal text rendering
///
/// This class manages a texture atlas containing pre-rendered glyphs.
/// Key features:
///   - 1px transparent padding around each glyph (prevents texture bleeding)
///   - LRU cache for dynamic glyph loading
///   - Separate regions for ASCII (pre-populated) and extended characters
final class GlyphAtlas {

    // MARK: - Types

    /// Key for looking up glyphs in the cache
    struct GlyphKey: Hashable {
        let codepoint: UInt32
        let bold: Bool
        let italic: Bool
    }

    /// Location of a glyph in the atlas
    struct GlyphInfo {
        let texCoords: CGRect       // Normalized texture coordinates
        let size: CGSize            // Size in pixels
        let bearing: CGPoint        // Offset from baseline
        let advance: CGFloat        // Horizontal advance
    }

    // MARK: - Properties

    /// The Metal texture containing all glyphs
    private(set) var texture: MTLTexture?

    /// Cache mapping glyph keys to their atlas locations
    private var glyphCache: [GlyphKey: GlyphInfo] = [:]

    /// Current packing position in the atlas
    private var packX: Int = 0
    private var packY: Int = 0
    private var rowHeight: Int = 0

    /// Atlas dimensions
    private let atlasWidth: Int = 1024
    private let atlasHeight: Int = 1024

    /// Padding around each glyph (critical for preventing texture bleeding)
    private let glyphPadding: Int = 1

    /// Font settings
    private let fontSize: CGFloat
    private var regularFont: CTFont?
    private var boldFont: CTFont?
    private var italicFont: CTFont?
    private var boldItalicFont: CTFont?

    /// Cell metrics
    private(set) var cellWidth: CGFloat = 0
    private(set) var cellHeight: CGFloat = 0
    private(set) var baseline: CGFloat = 0

    /// Metal device reference
    private let device: MTLDevice

    // MARK: - Initialization

    /// Static flag to ensure fonts are only registered once
    private static var fontsRegistered = false

    init(device: MTLDevice, fontSize: CGFloat = 24.0) {
        self.device = device
        self.fontSize = fontSize

        Self.registerBundledFonts()
        setupFonts()
        createTexture()
        prepopulateASCII()
    }

    /// Register bundled fonts at runtime
    private static func registerBundledFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true

        let fontNames = [
            "JetBrainsMonoNerdFont-Regular",
            "JetBrainsMonoNerdFont-Bold",
            "JetBrainsMonoNerdFont-Italic",
            "JetBrainsMonoNerdFont-BoldItalic"
        ]

        // Try Bundle.module first (SPM resources), then Bundle.main
        let bundles = [Bundle.module, Bundle.main]

        for fontName in fontNames {
            var registered = false
            for bundle in bundles {
                // Try direct path first
                if let fontURL = bundle.url(forResource: fontName, withExtension: "ttf") {
                    registered = registerFont(at: fontURL, name: fontName)
                    if registered { break }
                }
                // Try Fonts subdirectory
                if let fontURL = bundle.url(forResource: fontName, withExtension: "ttf", subdirectory: "Fonts") {
                    registered = registerFont(at: fontURL, name: fontName)
                    if registered { break }
                }
            }
            if !registered {
                print("[GlyphAtlas] Font not found: \(fontName)")
            }
        }
    }

    private static func registerFont(at url: URL, name: String) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            print("[GlyphAtlas] Registered font: \(name) from \(url.lastPathComponent)")
            return true
        } else if let cfError = error?.takeRetainedValue() {
            // Error code 105 means font is already registered - that's OK
            let nsError = cfError as Error as NSError
            if nsError.code == 105 {
                print("[GlyphAtlas] Font already registered: \(name)")
                return true
            }
            print("[GlyphAtlas] Failed to register font \(name): \(cfError)")
        }
        return false
    }

    private func setupFonts() {
        // Use JetBrains Mono if available, fallback to Menlo
        // CTFontCreateWithName always returns a font (falls back to system font)
        let fontNames = ["JetBrainsMonoNerdFont-Regular", "JetBrainsMono-Regular", "Menlo-Regular"]

        for fontName in fontNames {
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            // Check if we got the font we asked for (not a fallback)
            if let actualName = CTFontCopyPostScriptName(font) as String? {
                print("[GlyphAtlas] Requested '\(fontName)', got '\(actualName)'")
                if actualName == fontName {
                    regularFont = font
                    print("[GlyphAtlas] Using font: \(actualName)")
                    break
                }
            }
        }

        // Fallback to system monospace
        if regularFont == nil {
            regularFont = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
            print("[GlyphAtlas] Fallback to Menlo")
        }

        guard let regular = regularFont else { return }

        // Create style variants
        boldFont = CTFontCreateCopyWithSymbolicTraits(
            regular, fontSize, nil, .boldTrait, .boldTrait
        ) ?? regular

        italicFont = CTFontCreateCopyWithSymbolicTraits(
            regular, fontSize, nil, .italicTrait, .italicTrait
        ) ?? regular

        boldItalicFont = CTFontCreateCopyWithSymbolicTraits(
            regular, fontSize, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]
        ) ?? regular

        // Calculate cell metrics
        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)

        cellHeight = ceil(ascent + descent + leading)
        baseline = ceil(descent)

        // Get advance width for 'M' (representative character)
        var glyph = CTFontGetGlyphWithName(regular, "M" as CFString)
        var advance: CGSize = .zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        cellWidth = ceil(advance.width)
    }

    private func createTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,  // Single channel for glyph alpha
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        texture = device.makeTexture(descriptor: descriptor)

        // Clear texture to transparent
        if let texture = texture {
            let zeros = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
            texture.replace(
                region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
                mipmapLevel: 0,
                withBytes: zeros,
                bytesPerRow: atlasWidth
            )
        }
    }

    private func prepopulateASCII() {
        // Pre-populate printable ASCII characters (32-126)
        for codepoint in 32...126 {
            _ = getGlyph(codepoint: UInt32(codepoint), bold: false, italic: false)
        }

        // Also pre-populate bold variants for common characters
        for char in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" {
            _ = getGlyph(codepoint: char.unicodeScalars.first!.value, bold: true, italic: false)
        }
    }

    // MARK: - Public API

    /// Get glyph info for a codepoint, rendering it if necessary
    func getGlyph(codepoint: UInt32, bold: Bool, italic: Bool) -> GlyphInfo? {
        let key = GlyphKey(codepoint: codepoint, bold: bold, italic: italic)

        // Check cache
        if let cached = glyphCache[key] {
            return cached
        }

        // Render the glyph
        return renderGlyph(key: key)
    }

    // MARK: - Glyph Rendering

    private func renderGlyph(key: GlyphKey) -> GlyphInfo? {
        guard let font = selectFont(bold: key.bold, italic: key.italic) else {
            return nil
        }

        // Get glyph for codepoint
        let scalar = Unicode.Scalar(key.codepoint)
        guard let scalar = scalar else { return nil }

        let char = Character(scalar)

        // Create attributed string with WHITE foreground color
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: UIColor.white  // CRITICAL: Set text color to white
        ]
        let attrString = NSAttributedString(string: String(char), attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)

        // Get glyph bounds
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let glyphWidth = Int(ceil(width)) + glyphPadding * 2
        let glyphHeight = Int(ceil(ascent + descent)) + glyphPadding * 2

        // Check if we need to move to next row
        if packX + glyphWidth > atlasWidth {
            packX = 0
            packY += rowHeight + glyphPadding
            rowHeight = 0
        }

        // Check if atlas is full
        if packY + glyphHeight > atlasHeight {
            // TODO: Implement LRU eviction or atlas expansion
            print("GlyphAtlas: Atlas full, cannot add glyph \(key.codepoint)")
            return nil
        }

        rowHeight = max(rowHeight, glyphHeight)

        // Create bitmap context for rendering
        let bitmapWidth = glyphWidth
        let bitmapHeight = glyphHeight
        let bytesPerRow = bitmapWidth
        var bitmapData = [UInt8](repeating: 0, count: bitmapWidth * bitmapHeight)

        // Use UIGraphicsImageRenderer which handles coordinate systems correctly
        // UIKit has Y=0 at top, which matches Metal
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: bitmapWidth, height: bitmapHeight))
        let image = renderer.image { rendererCtx in
            // Draw white text on transparent background
            UIColor.black.setFill()
            rendererCtx.fill(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]

            let str = String(char)
            str.draw(at: CGPoint(x: CGFloat(glyphPadding), y: CGFloat(glyphPadding)), withAttributes: attrs)
        }

        // Extract grayscale pixel data from the rendered image
        guard let cgImage = image.cgImage else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let extractContext = CGContext(
            data: &bitmapData,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        // Draw the image into grayscale context to extract luminance
        extractContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

        // Copy to Metal texture
        texture?.replace(
            region: MTLRegionMake2D(packX, packY, bitmapWidth, bitmapHeight),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )

        // Calculate normalized texture coordinates
        let texCoords = CGRect(
            x: CGFloat(packX + glyphPadding) / CGFloat(atlasWidth),
            y: CGFloat(packY + glyphPadding) / CGFloat(atlasHeight),
            width: CGFloat(bitmapWidth - glyphPadding * 2) / CGFloat(atlasWidth),
            height: CGFloat(bitmapHeight - glyphPadding * 2) / CGFloat(atlasHeight)
        )

        let info = GlyphInfo(
            texCoords: texCoords,
            size: CGSize(width: CGFloat(bitmapWidth - glyphPadding * 2),
                        height: CGFloat(bitmapHeight - glyphPadding * 2)),
            bearing: CGPoint(x: 0, y: descent),
            advance: CGFloat(width)
        )

        // Update packing position
        packX += glyphWidth + glyphPadding

        // Cache the glyph info
        glyphCache[key] = info

        return info
    }

    private func selectFont(bold: Bool, italic: Bool) -> CTFont? {
        switch (bold, italic) {
        case (true, true): return boldItalicFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        case (false, false): return regularFont
        }
    }
}
