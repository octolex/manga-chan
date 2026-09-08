//
//  Shaders.metal
//
//  Stroke rendering is split into coverage and colour:
//
//    dab_coverage_fragment  writes coverage into a scratch texture
//    composite_fragment     tints that coverage with the ink colour and
//                           composites it in one pass
//
//  The split is what makes overlapping dabs affordable. A stroke at tight
//  spacing overlaps itself constantly, and compositing each dab against the
//  layer would darken every overlap into a bead.
//
//  Coverage is two numbers, not one, and keeping them apart is the whole
//  design:
//
//    .r  ink density — how much pigment has landed. Accumulates with
//        alpha-over, so a low-flow brush builds up across passes and a
//        self-crossing goes darker.
//    .a  geometry — what shape the stroke is. Takes the maximum, so it stays
//        the true antialiased silhouette however many dabs pass over it.
//
//  Conflating them is the trap. Accumulating alone is Photoshop's model and
//  makes flow meaningful, but it destroys the antialiasing: a pixel just
//  outside the edge picks up partial coverage from every passing dab, and at
//  tight spacing that saturates to 1, so the stroke bloats by a pixel and its
//  rim goes hard. Taking the maximum alone keeps a perfect edge but makes flow
//  and opacity redundant, since both then scale the same final alpha.
//
//  Doing both and compositing min(density, geometry) gets each property from
//  the channel that can express it. Metal allows a different blend operation
//  for RGB and for alpha on one attachment, so this costs one pass and one
//  texture, exactly as the single-channel version did.
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

//  Grain is a ceiling on how much of a pixel the ink is allowed to reach — the
//  paper's high points — not a filter over the stroke and not a threshold
//  against how much ink has landed.
//
//  Three attempts got this wrong before it was measured rather than reasoned
//  about. Procreate, on device, 2026-09-05:
//
//    * Canvas-anchored grain NEVER fills in. Scrubbed twenty times over one
//      patch, the texture is exactly as present as after one pass.
//    * Rolling grain fills to solid under the same scrubbing.
//    * Depth changes only how darkly the gaps are masked. The pattern itself
//      does not move, change scale, or change shape.
//    * Lower opacity does NOT show more texture.
//
//  The last of those kills thresholding against accumulated coverage, which
//  would make grain strengthen dramatically as opacity falls. The first two are
//  the interesting part, because one mechanism gives both and neither mode
//  needs a special case: multiply the dab's coverage by the tooth and let the
//  maximum blend that builds the silhouette do the rest.
//
//    * Canvas: the tooth is the same for every dab over a given pixel, so
//      max(tooth * shape) is tooth * silhouette however many passes cross it.
//      The pits never receive ink. Permanent, which is what paper does.
//    * Rolling: the tooth is offset by arc length, so each pass puts its pits
//      somewhere new and the running maximum climbs to 1. Fills to solid.
//
//  So the answer really was the multiply this started with. It was abandoned in
//  1f89bd7 on the objection that it "veiled the whole stroke uniformly", and
//  that objection is now falsified: a canvas-anchored grain veils the whole
//  inked area, permanently, on purpose. What likely looked wrong was the map —
//  our fractal noise clusters near mid-grey and reads as a wash rather than as
//  tooth, which is what Procreate's grain Brightness and Contrast exist to fix.
inline float grain_tooth(texture2d<float> grain, float2 uv, float depth)
{
    // Uniform across the draw, so this branch costs nothing beyond the compare
    // and it skips the texture fetch entirely on every brush that has no grain
    // — which is all of them by default.
    if (depth <= 0.0) { return 1.0; }

    // Repeat and linear, matching mc::sampleAlpha in the engine. Those two
    // choices are what let the CPU reference and this sampler be compared at
    // all; a mismatch in either is invisible on screen.
    constexpr sampler grainSampler(filter::linear, address::repeat);
    float g = grain.sample(grainSampler, uv).r;

    // Depth interpolates between no mask at all and the full map. Measured
    // behaviour: it changes how dark the gaps go and nothing else, so it
    // belongs here as a lerp and not anywhere near the sampling coordinate.
    return mix(1.0, g, saturate(depth));
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

    // The dab's silhouette, before the paper gets a say.
    float shape = 1.0 - smoothstep(inner, 1.0, d);

    // The geometry channel: where the stroke is allowed to reach. The maximum
    // blend keeps it the true antialiased edge however many dabs cross this
    // pixel, and multiplying the tooth in here — rather than into the density
    // below — is what makes canvas grain permanent and rolling grain fill in.
    float geometry = shape * grain_tooth(grain, in.grainUV, uniforms.grainDepth);

    // The ink this dab lays down, which the alpha-over blend accumulates.
    // Deliberately ungrained: density is how much pigment arrived, and the
    // paper limits where it can sit, not how much of it there is. Graining
    // both channels would make the tooth deepen with every pass, which is the
    // one behaviour the device round ruled out.
    float density = shape * in.flow;

    return float4(density, 0.0, 0.0, geometry);
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
    float shape = 1.0 - smoothstep(inner, 1.0, d);

    // The prediction has to be grained too. It is drawn a frame ahead of the
    // committed stroke and replaced by it, so an ungrained lookahead would show
    // as a smooth tip that turns textured as the real dabs catch up.
    //
    // One pass, so the two channels the committed path keeps apart collapse to
    // their minimum here: ink laid down, capped by what the paper allows.
    float tooth = grain_tooth(grain, in.grainUV, uniforms.grainDepth);
    float coverage = shape * min(in.flow, tooth);

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
    float4 coverage = scratch.sample(s, in.texCoord);

    // Ink density, capped by the stroke's own silhouette. The cap is what
    // preserves the antialiased edge: density saturates to 1 a pixel outside
    // the true edge because every passing dab contributes there, and geometry
    // is the only channel that still remembers the edge was soft.
    float alpha = inkColor.a * min(coverage.r, coverage.a);
    return float4(inkColor.rgb * alpha, alpha); // premultiplied
}
