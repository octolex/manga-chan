//
//  BlendShaders.metal
//
//  The GPU half of layer blending. Mirrors core/blend.cpp exactly, and the
//  simulator test suite renders every mode here and compares it pixel by pixel
//  against that CPU implementation.
//
//  That comparison is not ceremony. A shader that blends subtly wrong compiles,
//  runs at full speed, and produces output that looks approximately right on a
//  device we cannot attach a frame debugger to — the hardest kind of wrong to
//  notice, and the reason the CPU version was written first.
//
//  Programmable blending: `[[color(0)]]` declared as a fragment *input* reads
//  the current value of that attachment straight out of tile memory. No second
//  texture, no ping-pong. Verified as unconditionally available on iPadOS —
//  Metal Shading Language Specification, Table 5.5, p146. See
//  docs/metal-verified.md.
//
//  Mode indices must match mc::BlendMode in core/blend.h. Nothing enforces
//  that but the test.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

namespace blendmode {
constant int Normal       = 0;
constant int Multiply     = 1;
constant int Darken       = 2;
constant int ColorBurn    = 3;
constant int LinearBurn   = 4;
constant int DarkerColor  = 5;
constant int Lighten      = 6;
constant int Screen       = 7;
constant int ColorDodge   = 8;
constant int Add          = 9;
constant int LighterColor = 10;
constant int Overlay      = 11;
constant int SoftLight    = 12;
constant int HardLight    = 13;
constant int VividLight   = 14;
constant int LinearLight  = 15;
constant int PinLight     = 16;
constant int HardMix      = 17;
constant int Difference   = 18;
constant int Exclusion    = 19;
constant int Subtract     = 20;
constant int Divide       = 21;
constant int Hue          = 22;
constant int Saturation   = 23;
constant int Color        = 24;
constant int Luminosity   = 25;
}

// MARK: - Per-channel primitives

static inline float3 bMultiply(float3 b, float3 s) { return b * s; }
static inline float3 bScreen(float3 b, float3 s)   { return b + s - b * s; }

static inline float chColorDodge(float b, float s) {
    if (b <= 0.0f) return 0.0f;   // backdrop black stays black
    if (s >= 1.0f) return 1.0f;   // source white blows out
    return min(1.0f, b / (1.0f - s));
}

static inline float chColorBurn(float b, float s) {
    if (b >= 1.0f) return 1.0f;
    if (s <= 0.0f) return 0.0f;
    return 1.0f - min(1.0f, (1.0f - b) / s);
}

static inline float chHardLight(float b, float s) {
    return s <= 0.5f ? (b * (2.0f * s))
                     : (b + (2.0f * s - 1.0f) - b * (2.0f * s - 1.0f));
}

static inline float chSoftLight(float b, float s) {
    // The W3C piecewise definition. The d() term keeps the curve continuous
    // at b = 0.25, which a naive sqrt does not.
    if (s <= 0.5f) {
        return b - (1.0f - 2.0f * s) * b * (1.0f - b);
    }
    float d = b <= 0.25f ? (((16.0f * b - 12.0f) * b + 4.0f) * b) : sqrt(b);
    return b + (2.0f * s - 1.0f) * (d - b);
}

static inline float chVividLight(float b, float s) {
    return s <= 0.5f ? chColorBurn(b, 2.0f * s)
                     : chColorDodge(b, 2.0f * s - 1.0f);
}

static inline float chPinLight(float b, float s) {
    return s <= 0.5f ? min(b, 2.0f * s) : max(b, 2.0f * s - 1.0f);
}

static inline float3 perChannelColorDodge(float3 b, float3 s) {
    return float3(chColorDodge(b.r, s.r), chColorDodge(b.g, s.g), chColorDodge(b.b, s.b));
}
static inline float3 perChannelColorBurn(float3 b, float3 s) {
    return float3(chColorBurn(b.r, s.r), chColorBurn(b.g, s.g), chColorBurn(b.b, s.b));
}
static inline float3 perChannelHardLight(float3 b, float3 s) {
    return float3(chHardLight(b.r, s.r), chHardLight(b.g, s.g), chHardLight(b.b, s.b));
}
static inline float3 perChannelSoftLight(float3 b, float3 s) {
    return float3(chSoftLight(b.r, s.r), chSoftLight(b.g, s.g), chSoftLight(b.b, s.b));
}
static inline float3 perChannelVividLight(float3 b, float3 s) {
    return float3(chVividLight(b.r, s.r), chVividLight(b.g, s.g), chVividLight(b.b, s.b));
}
static inline float3 perChannelPinLight(float3 b, float3 s) {
    return float3(chPinLight(b.r, s.r), chPinLight(b.g, s.g), chPinLight(b.b, s.b));
}

// MARK: - Non-separable helpers (W3C compositing spec)

static inline float lum(float3 c) {
    return 0.30f * c.r + 0.59f * c.g + 0.11f * c.b;
}

/// Pulls a colour back into gamut while preserving luminosity, which is what
/// stops the component modes producing clipped, hue-shifted results.
static float3 clipColor(float3 c) {
    float l = lum(c);
    float n = min(c.r, min(c.g, c.b));
    float x = max(c.r, max(c.g, c.b));

    if (n < 0.0f) {
        float d = l - n;
        if (d > 0.0f) c = l + (c - l) * l / d;
    }
    if (x > 1.0f) {
        float d = x - l;
        if (d > 0.0f) c = l + (c - l) * (1.0f - l) / d;
    }
    return c;
}

static inline float3 setLum(float3 c, float l) {
    return clipColor(c + (l - lum(c)));
}

static inline float sat(float3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

/// Rescales so the channel spread becomes `s`, keeping the relative ordering.
/// The vector form is exactly the spec's min/mid/max rule: the minimum maps to
/// 0, the maximum to s, and the middle keeps its proportion.
static inline float3 setSat(float3 c, float s) {
    float mn = min(c.r, min(c.g, c.b));
    float mx = max(c.r, max(c.g, c.b));
    return (mx > mn) ? ((c - mn) * (s / (mx - mn))) : float3(0.0f);
}

// MARK: - Blend function

static float3 blendFunction(int mode, float3 b, float3 s) {
    switch (mode) {
    case blendmode::Multiply:     return bMultiply(b, s);
    case blendmode::Screen:       return bScreen(b, s);
    case blendmode::Darken:       return min(b, s);
    case blendmode::Lighten:      return max(b, s);
    case blendmode::ColorDodge:   return perChannelColorDodge(b, s);
    case blendmode::ColorBurn:    return perChannelColorBurn(b, s);
    case blendmode::HardLight:    return perChannelHardLight(b, s);
    case blendmode::SoftLight:    return perChannelSoftLight(b, s);
    case blendmode::VividLight:   return perChannelVividLight(b, s);
    case blendmode::PinLight:     return perChannelPinLight(b, s);

    // Hard Light with the operands swapped, per the spec.
    case blendmode::Overlay:
        return float3(chHardLight(s.r, b.r), chHardLight(s.g, b.g), chHardLight(s.b, b.b));

    case blendmode::LinearBurn:   return saturate(b + s - 1.0f);
    case blendmode::LinearLight:  return saturate(b + 2.0f * s - 1.0f);
    case blendmode::Add:          return saturate(b + s);
    case blendmode::Subtract:     return saturate(b - s);

    case blendmode::Divide:
        return float3(s.r <= 0.0f ? 1.0f : min(1.0f, b.r / s.r),
                      s.g <= 0.0f ? 1.0f : min(1.0f, b.g / s.g),
                      s.b <= 0.0f ? 1.0f : min(1.0f, b.b / s.b));

    case blendmode::Difference:   return abs(b - s);
    case blendmode::Exclusion:    return b + s - 2.0f * b * s;

    case blendmode::HardMix: {
        // Vivid Light pushed to a hard threshold, which is what gives it the
        // posterised look.
        float3 v = perChannelVividLight(b, s);
        return float3(v.r < 0.5f ? 0.0f : 1.0f,
                      v.g < 0.5f ? 0.0f : 1.0f,
                      v.b < 0.5f ? 0.0f : 1.0f);
    }

    // Whole-colour comparisons, not per channel.
    case blendmode::DarkerColor:  return lum(s) < lum(b) ? s : b;
    case blendmode::LighterColor: return lum(s) > lum(b) ? s : b;

    case blendmode::Hue:          return setLum(setSat(s, sat(b)), lum(b));
    case blendmode::Saturation:   return setLum(setSat(b, sat(s)), lum(b));
    case blendmode::Color:        return setLum(s, lum(b));
    case blendmode::Luminosity:   return setLum(b, lum(s));

    case blendmode::Normal:
    default:                      return s;
    }
}

// MARK: - Entry point

struct BlendRasterData {
    float4 position [[position]];
    float2 texCoord;
};

vertex BlendRasterData blend_vertex(uint vertexID [[vertex_id]])
{
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    BlendRasterData out;
    out.position = float4(uv * 2.0f - 1.0f, 0.0f, 1.0f);
    out.texCoord = float2(uv.x, 1.0f - uv.y);
    return out;
}

/// The composite itself, shared by both entry points below so that what the
/// test verifies and what the device runs cannot diverge.
static float4 compositePremultiplied(int mode, float4 dst, float4 src, float opacity)
{
    // Attachments and textures both hold premultiplied colour; the blend
    // functions are defined on straight colour.
    float ab = dst.a;
    float as = src.a * saturate(opacity);
    float3 cb = ab > 0.0f ? dst.rgb / ab : float3(0.0f);
    float3 cs = src.a > 0.0f ? src.rgb / src.a : float3(0.0f);

    if (as <= 0.0f) {
        return dst;   // nothing to add
    }

    float3 blended = blendFunction(mode, cb, cs);

    // W3C source-over with a blend function: source over bare canvas, source
    // over backdrop where the blend applies, and backdrop showing through.
    float ao = as + ab * (1.0f - as);
    float3 co = as * (1.0f - ab) * cs
              + as * ab * blended
              + (1.0f - as) * ab * cb;

    return float4(co, ao);   // already premultiplied
}

/// The shipping path. `dst` is the current contents of colour attachment 0,
/// read straight from tile memory — programmable blending. Its type must match
/// the return type: MSL Specification, p153.
///
/// This entry point CANNOT be used on the iOS Simulator, which rejects it at
/// pipeline creation with "reading from a rendertarget is not supported".
/// See docs/metal-verified.md.
fragment float4 blend_fragment(BlendRasterData in [[stage_in]],
                               float4 dst [[color(0)]],
                               texture2d<float> sourceTexture [[texture(0)]],
                               constant MSBlendUniforms& uniforms [[buffer(0)]])
{
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    float4 src = sourceTexture.sample(nearest, in.texCoord);
    return compositePremultiplied(uniforms.mode, dst, src, uniforms.opacity);
}

/// Identical maths, but the backdrop arrives as an ordinary texture instead of
/// being read back from the attachment.
///
/// This exists so the 26 blend formulas — several hundred lines of arithmetic
/// with singularities at the extremes — can be verified in CI on the
/// simulator. The shipping path differs from it in exactly one respect: where
/// `dst` comes from. That difference is one attribute, documented in the MSL
/// specification, and is the part device testing has to cover.
fragment float4 blend_fragment_reference(BlendRasterData in [[stage_in]],
                                         texture2d<float> sourceTexture [[texture(0)]],
                                         texture2d<float> backdropTexture [[texture(1)]],
                                         constant MSBlendUniforms& uniforms [[buffer(0)]])
{
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    float4 src = sourceTexture.sample(nearest, in.texCoord);
    float4 dst = backdropTexture.sample(nearest, in.texCoord);
    return compositePremultiplied(uniforms.mode, dst, src, uniforms.opacity);
}
