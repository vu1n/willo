import CoreText
import MetalKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
    /// Start at (2,2) to reserve (0,0) corner as guaranteed transparent
    /// for empty cells that sample at texCoord (0,0)
    private var packX: Int = 2
    private var packY: Int = 2
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

        print("[GlyphAtlas] Searching for fonts in bundles:")
        print("[GlyphAtlas]   Bundle.module: \(Bundle.module.bundlePath)")
        print("[GlyphAtlas]   Bundle.main: \(Bundle.main.bundlePath)")

        for fontName in fontNames {
            var registered = false
            for bundle in bundles {
                // Try direct path first
                if let fontURL = bundle.url(forResource: fontName, withExtension: "ttf") {
                    print("[GlyphAtlas] Found \(fontName) at: \(fontURL.path)")
                    registered = registerFont(at: fontURL, name: fontName)
                    if registered { break }
                }
                // Try Fonts subdirectory
                if let fontURL = bundle.url(forResource: fontName, withExtension: "ttf", subdirectory: "Fonts") {
                    print("[GlyphAtlas] Found \(fontName) in Fonts/ at: \(fontURL.path)")
                    registered = registerFont(at: fontURL, name: fontName)
                    if registered { break }
                }
            }
            if !registered {
                print("[GlyphAtlas] ❌ Font not found: \(fontName)")
            }
        }
    }

    /// Maps font file names to their actual PostScript names (discovered at registration)
    private static var fontPostScriptNames: [String: String] = [:]

    private static func registerFont(at url: URL, name: String) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Get the actual PostScript name from the registered font
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let descriptor = descriptors.first,
               let psName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                fontPostScriptNames[name] = psName
                print("[GlyphAtlas] Registered font: \(name) → PostScript name: '\(psName)'")
            } else {
                print("[GlyphAtlas] Registered font: \(name) (couldn't get PostScript name)")
            }
            return true
        } else if let cfError = error?.takeRetainedValue() {
            // Error code 105 means font is already registered - that's OK
            let nsError = cfError as Error as NSError
            if nsError.code == 105 {
                // Still try to get the PostScript name
                if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                   let descriptor = descriptors.first,
                   let psName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                    fontPostScriptNames[name] = psName
                    print("[GlyphAtlas] Font already registered: \(name) → PostScript name: '\(psName)'")
                } else {
                    print("[GlyphAtlas] Font already registered: \(name)")
                }
                return true
            }
            print("[GlyphAtlas] Failed to register font \(name): \(cfError)")
        }
        return false
    }

    private func setupFonts() {
        // Use JetBrains Mono if available, fallback to Menlo
        // First try the discovered PostScript names from registration, then fallbacks
        var fontNamesToTry: [String] = []

        // Add discovered PostScript name for Nerd Font if we have it
        if let nerdFontPS = Self.fontPostScriptNames["JetBrainsMonoNerdFont-Regular"] {
            fontNamesToTry.append(nerdFontPS)
        }
        // Add original names as fallback
        fontNamesToTry.append(contentsOf: ["JetBrainsMonoNerdFont-Regular", "JetBrainsMono-Regular", "Menlo-Regular"])

        print("[GlyphAtlas] Looking for fonts: \(fontNamesToTry)")

        for fontName in fontNamesToTry {
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            // Check if we got the font we asked for (not a fallback)
            if let actualName = CTFontCopyPostScriptName(font) as String? {
                print("[GlyphAtlas] Requested '\(fontName)', got '\(actualName)'")
                if actualName == fontName {
                    regularFont = font
                    print("[GlyphAtlas] ✅ Using font: \(actualName)")

                    // Test if font has box drawing characters
                    let testCodepoint: UInt32 = 0x2502 // │ BOX DRAWINGS LIGHT VERTICAL
                    var glyph: CGGlyph = 0
                    var codepoints = [UniChar](repeating: 0, count: 2)
                    let scalar = Unicode.Scalar(testCodepoint)!
                    let str = String(Character(scalar))
                    (str as NSString).getCharacters(&codepoints)
                    let hasBoxDrawing = CTFontGetGlyphsForCharacters(font, codepoints, &glyph, 1)
                    print("[GlyphAtlas] Font has box drawing (U+2502): \(hasBoxDrawing), glyph: \(glyph)")

                    break
                }
            }
        }

        // Fallback to system monospace
        if regularFont == nil {
            regularFont = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
            print("[GlyphAtlas] ⚠️ Fallback to Menlo")
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

        print("[GlyphAtlas] Font metrics for \(fontSize)pt: ascent=\(ascent), descent=\(descent), leading=\(leading)")
        print("[GlyphAtlas] Cell metrics: width=\(cellWidth), height=\(cellHeight), advance.width=\(advance.width)")
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
        #if os(iOS)
        let textColor = UIColor.white
        #else
        let textColor = NSColor.white
        #endif
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: textColor  // CRITICAL: Set text color to white
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

        // Render glyph to bitmap using cross-platform approach
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: bitmapWidth, height: bitmapHeight))
        let image = renderer.image { rendererCtx in
            UIColor.black.setFill()
            rendererCtx.fill(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let str = String(char)
            str.draw(at: CGPoint(x: CGFloat(glyphPadding), y: CGFloat(glyphPadding)), withAttributes: attrs)
        }
        guard let cgImage = image.cgImage else { return nil }
        #else
        // macOS: Use Core Graphics directly
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bitmapWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

        // Flip coordinate system for text
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: CGFloat(bitmapHeight))
        ctx.scaleBy(x: 1, y: -1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: String(char), attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(str)
        let path = CGPath(rect: CGRect(x: glyphPadding, y: glyphPadding, width: bitmapWidth, height: bitmapHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, str.length), path, nil)
        CTFrameDraw(frame, ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        #endif

        let grayColorSpace = CGColorSpaceCreateDeviceGray()
        guard let extractContext = CGContext(
            data: &bitmapData,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: grayColorSpace,
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
