//
//  TerminalShaders.metal
//  Willo
//
//  Metal shaders for terminal grid rendering
//
//  Rendering strategy:
//    1. Background pass: Draw bg color for each cell
//    2. Glyph pass: Sample from glyph atlas texture
//    3. Cursor pass: Overlay cursor block
//    4. (Future) Underline/strikethrough pass
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

struct CellVertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 fgColor [[attribute(2)]];
    float4 bgColor [[attribute(3)]];
};

struct Uniforms {
    float2 viewportSize;
    float2 cellSize;
    uint2 gridSize;
    float time;
    float padding;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
};

// MARK: - Vertex Shader

vertex VertexOut terminalVertex(
    CellVertex in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;

    // Convert from pixel coordinates to normalized device coordinates
    // Metal NDC: (-1, -1) is bottom-left, (1, 1) is top-right
    float2 pixelPos = in.position;
    float2 normalizedPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;

    // Flip Y axis (Metal's Y is up, we want Y down for terminal)
    normalizedPos.y = -normalizedPos.y;

    out.position = float4(normalizedPos, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.fgColor = in.fgColor;
    out.bgColor = in.bgColor;

    return out;
}

// MARK: - Fragment Shader

fragment float4 terminalFragment(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float> glyphAtlas [[texture(0)]]
) {
    // Sample the glyph atlas (r8 texture - alpha mask)
    // Use nearest filtering for pixel-perfect terminal glyph rendering
    constexpr sampler nearestSampler(
        mag_filter::nearest,
        min_filter::nearest,
        address::clamp_to_edge
    );

    float glyphAlpha = glyphAtlas.sample(nearestSampler, in.texCoord).r;

    // Blend foreground color with background based on glyph alpha
    // When glyphAlpha = 0: show background
    // When glyphAlpha = 1: show foreground (text)
    float4 color = mix(in.bgColor, in.fgColor, glyphAlpha);

    return color;
}

// MARK: - Cursor Fragment Shader (for dedicated cursor pass)

fragment float4 cursorFragment(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    // Blinking cursor effect
    float blink = sin(uniforms.time * 3.0) * 0.5 + 0.5;

    // Cursor color with blink
    float4 cursorColor = float4(0.8, 0.8, 0.8, blink);

    return cursorColor;
}

// MARK: - Background-only Fragment Shader (optimization)

fragment float4 backgroundFragment(
    VertexOut in [[stage_in]]
) {
    return in.bgColor;
}

// MARK: - Selection Highlight Fragment Shader

fragment float4 selectionFragment(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float> glyphAtlas [[texture(0)]]
) {
    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float glyphAlpha = glyphAtlas.sample(linearSampler, in.texCoord).r;

    // Selection highlight (invert colors or use selection color)
    float4 selectionBg = float4(0.2, 0.4, 0.8, 0.5);  // Blue selection
    float4 selectionFg = float4(1.0, 1.0, 1.0, 1.0);  // White text

    float4 color = mix(selectionBg, selectionFg, glyphAlpha);

    return color;
}
