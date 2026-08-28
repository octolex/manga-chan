//
//  Shaders.metal
//
//  Stroke rendering is split into coverage and colour:
//
//    stroke_coverage_fragment  writes coverage into a single-channel scratch
//                              texture, blended with MAX rather than alpha-over
//    composite_fragment        tints that coverage with the ink colour and
//                              composites it in one pass
//
//  The split is what makes overlapping geometry free. A dense ribbon overlaps
//  itself constantly, and alpha-over would darken every overlap into a visible
//  bead along the stroke. Taking the maximum coverage instead means a pixel
//  covered ten times looks exactly like a pixel covered once — which is also
//  what stops a semi-transparent stroke from darkening where it crosses itself.
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

fragment float4 stroke_coverage_fragment(StrokeRasterData in [[stage_in]])
{
    // `edge` runs -1..+1 across the ribbon. Fading the last pixel of that
    // range gives a cheap analytic antialiased edge without MSAA, which would
    // cost bandwidth better spent on the brush engine later.
    float d = abs(in.edge);
    float w = clamp(fwidth(in.edge), 0.0001, 1.0);
    float coverage = (1.0 - smoothstep(1.0 - w, 1.0, d)) * in.color.a;
    return float4(coverage, 0.0, 0.0, 0.0);
}

// MARK: - Fullscreen passes

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

fragment float4 composite_fragment(BlitRasterData in [[stage_in]],
                                   texture2d<float> scratch [[texture(0)]],
                                   constant float4 &inkColor [[buffer(0)]])
{
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float coverage = scratch.sample(s, in.texCoord).r;
    float alpha = inkColor.a * coverage;
    return float4(inkColor.rgb * alpha, alpha); // premultiplied
}
