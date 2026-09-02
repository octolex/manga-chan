//
//  Shaders.metal
//
//  Stroke rendering is split into coverage and colour:
//
//    dab_coverage_fragment  writes coverage into a single-channel scratch
//                           texture, accumulated per the brush setting
//    composite_fragment     tints that coverage with the ink colour and
//                           composites it in one pass
//
//  The split is what makes overlapping dabs affordable. A stroke at tight
//  spacing overlaps itself constantly, and compositing each dab against the
//  layer would darken every overlap into a bead. Accumulating coverage
//  separately and tinting once means a pixel covered ten times can look
//  exactly like a pixel covered once — which is also what stops a
//  semi-transparent stroke darkening where it crosses itself.
//
//  Whether it *does* look the same is the brush's Accumulation setting, and it
//  lives entirely in the blend state of this pass: max for ink, alpha-over for
//  an airbrush that is supposed to build up.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Brush dabs

//  A dab is drawn as one instanced quad. Six vertices per instance and no
//  index buffer: at these counts the quad is entirely fill-bound, and an index
//  buffer would add a second upload per frame to save eight bytes per dab.
//
//  The shape is procedural rather than a texture. A textured dab is the next
//  step and slots in here without touching anything else, but a procedural
//  disc has no sampling error at any size, which makes it the right thing to
//  pin the engine against while the geometry is still being proven.

struct DabRasterData {
    float4 position [[position]];
    float2 local;      // -1...1 across the dab, before rotation and squash
    float2 grainUV;    // map space, 1.0 being one full repeat
    float  flow;
    float  hardness;
};

//  Grain modulates coverage, and *where* its coordinate comes from is the whole
//  design. Canvas grain takes it from the pixel, so every dab covering a given
//  canvas pixel samples the same value there — which under max accumulation
//  makes the grain exactly invariant to overlap, because
//  max(g*c1, g*c2) = g*max(c1, c2). That identity is why canvas grain reads as
//  paper the stroke is drawn on rather than as a pattern printed onto it.
//
//  Rolling grain takes it from the dab's own frame, offset by how far along the
//  stroke the dab sits, so the texture scrolls with the brush. It deliberately
//  loses that invariance: two dabs at one pixel are at different arc lengths and
//  sample different grain, so overlaps show. Correct for dry media, wrong for
//  paper, which is exactly why this is a mode and not a slider.
inline float grain_modulation(texture2d<float> grain, float2 uv, float depth)
{
    // Uniform across the draw, so this branch costs nothing beyond the compare
    // and it skips the texture fetch entirely on every brush that has no grain
    // — which is all of them by default.
    if (depth <= 0.0) { return 1.0; }

    // Repeat and linear, matching mc::sampleAlpha in the engine. Those two
    // choices are what let the CPU reference and this sampler be compared at
    // all; a mismatch in either is invisible on screen.
    constexpr sampler grainSampler(filter::linear, address::repeat);
    return mix(1.0, grain.sample(grainSampler, uv).r, saturate(depth));
}

vertex DabRasterData dab_vertex(uint vertexID [[vertex_id]],
                                uint instanceID [[instance_id]],
                                constant MSDab *dabs [[buffer(MSBufferIndexVertices)]],
                                constant MSDabUniforms &uniforms [[buffer(MSBufferIndexUniforms)]])
{
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2( 1, -1), float2(1,  1), float2(-1, 1)
    };

    MSDab dab = dabs[instanceID];
    float2 corner = corners[vertexID];

    // Grow the quad by a pixel so the analytic edge has somewhere to fade.
    // Without this the antialiased rim would be clipped by the quad itself and
    // every dab would show a faint polygonal edge.
    float margin = dab.radius > 0.0 ? (dab.radius + 1.0) / dab.radius : 1.0;
    float2 local = corner * margin;

    float2 scaled = float2(local.x, local.y * dab.roundness) * dab.radius;
    float s = sin(dab.angle);
    float c = cos(dab.angle);
    float2 rotated = float2(scaled.x * c - scaled.y * s,
                            scaled.x * s + scaled.y * c);
    float2 pixel = float2(dab.x, dab.y) + rotated;

    // Canvas grain is anchored to the pixel; rolling grain to the dab's own
    // unrotated frame, scrolled along by the arc length the engine recorded.
    // `scaled` rather than `rotated` for the rolling case, so a nib that turns
    // through a curve carries its grain around with it instead of dragging it
    // across the texture.
    float invGrainScale = uniforms.grainScale > 0.0 ? 1.0 / uniforms.grainScale : 0.0;
    float2 grainPixel = uniforms.grainMovement == MSGrainRolling
        ? scaled + float2(dab.grainOffset, 0.0)
        : pixel;

    DabRasterData out;
    out.position = float4(pixel.x / uniforms.viewportSize.x * 2.0 - 1.0,
                          1.0 - pixel.y / uniforms.viewportSize.y * 2.0,
                          0.0, 1.0);
    out.local = local;
    out.grainUV = grainPixel * invGrainScale;
    out.flow = dab.flow;
    out.hardness = dab.hardness;
    return out;
}

fragment float4 dab_coverage_fragment(DabRasterData in [[stage_in]],
                                      texture2d<float> grain [[texture(0)]],
                                      constant MSDabUniforms &uniforms [[buffer(MSBufferIndexUniforms)]])
{
    float d = length(in.local);
    float w = max(fwidth(d), 1e-4);

    // Hardness is where the falloff begins, as a fraction of the radius. It is
    // capped a pixel short of the rim so that even a fully hard brush keeps an
    // antialiased edge — and so that smoothstep never gets a zero-width range,
    // which is undefined rather than merely ugly.
    float inner = min(in.hardness, 1.0 - w);
    float coverage = 1.0 - smoothstep(inner, 1.0, d);

    coverage *= in.flow;
    coverage *= grain_modulation(grain, in.grainUV, uniforms.grainDepth);
    return float4(coverage, 0.0, 0.0, 0.0);
}

/// Predicted dabs, painted straight onto the finished frame in ink colour.
///
/// A prediction must not survive into the next frame — coverage is accumulated
/// now, so a guess stamped there would be baked into the stroke and committed.
/// Painting over the composited frame instead means it disappears on its own.
fragment float4 dab_ink_fragment(DabRasterData in [[stage_in]],
                                 constant float4 &inkColor [[buffer(0)]],
                                 texture2d<float> grain [[texture(0)]],
                                 constant MSDabUniforms &uniforms [[buffer(MSBufferIndexUniforms)]])
{
    float d = length(in.local);
    float w = max(fwidth(d), 1e-4);
    float inner = min(in.hardness, 1.0 - w);
    float coverage = (1.0 - smoothstep(inner, 1.0, d)) * in.flow;

    // The prediction has to be grained too. It is drawn a frame ahead of the
    // committed stroke and replaced by it, so an ungrained lookahead would show
    // as a smooth tip that turns textured as the real dabs catch up.
    coverage *= grain_modulation(grain, in.grainUV, uniforms.grainDepth);

    float alpha = inkColor.a * coverage;
    return float4(inkColor.rgb * alpha, alpha); // premultiplied
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
