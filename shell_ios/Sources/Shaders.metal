//
//  Shaders.metal
//
//  M0 draws strokes as antialiased ribbons straight into a persistent canvas
//  texture. This is deliberately NOT the real brush engine — M3 replaces it
//  with dab stamping and scratch-buffer accumulation. What matters here is the
//  structure: committed geometry goes into the canvas, predicted geometry only
//  ever goes to the drawable.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Stroke ribbons

struct StrokeRasterData {
    float4 position [[position]];
    float4 color;
    float  edge;
};

vertex StrokeRasterData stroke_vertex(uint vertexID [[vertex_id]],
                                      constant MSStrokeVertex *vertices [[buffer(MSBufferIndexVertices)]])
{
    StrokeRasterData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    out.edge = vertices[vertexID].edge;
    return out;
}

fragment float4 stroke_fragment(StrokeRasterData in [[stage_in]])
{
    // `edge` runs -1..+1 across the ribbon. Fading the last pixel of that
    // range gives a cheap analytic antialiased edge without MSAA, which would
    // cost us bandwidth we would rather spend on the brush engine later.
    float d = abs(in.edge);
    float w = clamp(fwidth(in.edge), 0.0001, 1.0);
    float coverage = 1.0 - smoothstep(1.0 - w, 1.0, d);

    float alpha = in.color.a * coverage;
    return float4(in.color.rgb * alpha, alpha); // premultiplied
}

// MARK: - Canvas presentation

struct BlitRasterData {
    float4 position [[position]];
    float2 texCoord;
};

vertex BlitRasterData fullscreen_vertex(uint vertexID [[vertex_id]])
{
    // One oversized triangle covering the viewport — cheaper than a quad and
    // avoids the diagonal seam two triangles can produce.
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);

    BlitRasterData out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    out.texCoord = float2(uv.x, 1.0 - uv.y);
    return out;
}

fragment float4 blit_fragment(BlitRasterData in [[stage_in]],
                              texture2d<float> canvas [[texture(0)]])
{
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return canvas.sample(s, in.texCoord);
}
