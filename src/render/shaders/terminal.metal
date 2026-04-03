// agentmux Metal Shader Library
// Terminal cell rendering with glyph atlas texture sampling

#include <metal_stdlib>
using namespace metal;

// Vertex input from CPU
struct VertexIn {
    float2 position  [[attribute(0)]];
    float2 texCoord  [[attribute(1)]];
    float4 fgColor   [[attribute(2)]];
    float4 bgColor   [[attribute(3)]];
    float  isGlyph   [[attribute(4)]]; // 1.0 = glyph quad, 0.0 = background quad
};

// Vertex output / Fragment input
struct VertexOut {
    float4 position  [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
    float  isGlyph;
};

// Uniforms
struct Uniforms {
    float4x4 projectionMatrix;
    float2   viewportSize;
    float2   cellSize;
    float    time;
};

// --- Vertex Shader ---

vertex VertexOut vertex_main(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;
    out.position = uniforms.projectionMatrix * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.fgColor = in.fgColor;
    out.bgColor = in.bgColor;
    out.isGlyph = in.isGlyph;
    return out;
}

// --- Fragment Shader: Background ---

fragment float4 fragment_background(
    VertexOut in [[stage_in]]
) {
    return in.bgColor;
}

// --- Fragment Shader: Glyph ---
// Samples the glyph atlas texture and applies foreground color

fragment float4 fragment_glyph(
    VertexOut in [[stage_in]],
    texture2d<float> atlasTexture [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float alpha = atlasTexture.sample(atlasSampler, in.texCoord).r;
    if (alpha < 0.01) {
        discard_fragment();
    }
    return float4(in.fgColor.rgb, in.fgColor.a * alpha);
}

// --- Fragment Shader: Combined Cell ---
// Renders background color, then composites glyph on top

fragment float4 fragment_cell(
    VertexOut in [[stage_in]],
    texture2d<float> atlasTexture [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    if (in.isGlyph < 0.5) {
        // Background quad
        return in.bgColor;
    }

    // Glyph quad: sample atlas and composite
    float alpha = atlasTexture.sample(atlasSampler, in.texCoord).r;
    float4 glyphColor = float4(in.fgColor.rgb, in.fgColor.a * alpha);

    // Alpha blend glyph over background
    float3 blended = mix(in.bgColor.rgb, glyphColor.rgb, glyphColor.a);
    return float4(blended, 1.0);
}

// --- Fragment Shader: Cursor ---
// Block cursor with configurable color and blink

fragment float4 fragment_cursor(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    // Blink: on for 500ms, off for 500ms
    float blink = step(0.0, sin(uniforms.time * 3.14159));
    float4 cursorColor = float4(0.8, 0.8, 0.8, 0.7 * blink);
    return cursorColor;
}

// --- Fragment Shader: Selection ---
// Highlight for visual selection in copy mode

fragment float4 fragment_selection(
    VertexOut in [[stage_in]]
) {
    return float4(0.3, 0.5, 0.8, 0.4); // Semi-transparent blue
}

// --- Fragment Shader: Image ---
// Renders inline images (sixel, kitty) with RGBA texture

fragment float4 fragment_image(
    VertexOut in [[stage_in]],
    texture2d<float> imageTexture [[texture(0)]],
    sampler imageSampler [[sampler(0)]]
) {
    return imageTexture.sample(imageSampler, in.texCoord);
}

// --- Vertex Shader: Fullscreen Quad ---
// For post-processing effects or image rendering

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex FullscreenVertexOut vertex_fullscreen(
    uint vertexID [[vertex_id]]
) {
    FullscreenVertexOut out;
    // Triangle strip covering full screen
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}
