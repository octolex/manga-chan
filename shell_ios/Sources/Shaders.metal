//
//  Shaders.metal
//
//  M0 only draws flat-shaded triangles. The brush engine's real shaders —
//  dab stamping, and the framebuffer-fetch blend modes — arrive in M2/M3.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct RasterizerData {
    float4 position [[position]];
    float4 color;
};

vertex RasterizerData flat_vertex(uint vertexID [[vertex_id]],
                                  constant MSVertex *vertices [[buffer(MSBufferIndexVertices)]])
{
    RasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 flat_fragment(RasterizerData in [[stage_in]])
{
    return in.color;
}
