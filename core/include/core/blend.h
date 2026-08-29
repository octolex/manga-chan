#pragma once

//
//  blend.h — layer blending mathematics.
//
//  Implemented on the CPU first, deliberately. These functions are the golden
//  reference the Metal shaders are checked against: without a GPU frame
//  debugger, a shader that blends subtly wrong is nearly impossible to
//  diagnose on device, whereas a CPU implementation can be unit-tested against
//  known values in CI in milliseconds.
//
//  Formulas follow the W3C Compositing and Blending Level 1 spec, extended
//  with the Photoshop modes that spec omits (Linear Burn, Vivid Light, Hard
//  Mix and friends). Matching an established set matters more than inventing
//  one: artists arrive with expectations about what Multiply does, and files
//  have to round-trip through PSD.
//
//  Colour convention: tiles store premultiplied RGBA8, but blend functions are
//  defined on *non*-premultiplied colour. composite() handles the conversion
//  in both directions, so callers never have to think about it.
//

#include "core/tile.h"

#include <cstdint>

namespace mc {

enum class BlendMode : uint8_t {
    Normal = 0,

    // Darken group
    Multiply,
    Darken,
    ColorBurn,
    LinearBurn,
    DarkerColor,

    // Lighten group
    Lighten,
    Screen,
    ColorDodge,
    Add,
    LighterColor,

    // Contrast group
    Overlay,
    SoftLight,
    HardLight,
    VividLight,
    LinearLight,
    PinLight,
    HardMix,

    // Inversion group
    Difference,
    Exclusion,
    Subtract,
    Divide,

    // Component group — these need all three channels at once rather than
    // operating per channel, which is why the shader for them cannot be a
    // simple per-component expression either.
    Hue,
    Saturation,
    Color,
    Luminosity,

    Count
};

const char* blendModeName(BlendMode mode);

/// True for modes that mix channels, which the GPU path has to handle with a
/// separate shader from the per-channel ones.
bool blendModeIsSeparable(BlendMode mode);

struct RgbF {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;

    friend bool operator==(const RgbF&, const RgbF&) = default;
};

/// The blend function B(Cb, Cs) on non-premultiplied colour in 0...1.
/// Alpha plays no part here; composite() applies it.
RgbF blendFunction(BlendMode mode, RgbF backdrop, RgbF source);

/// Full source-over composite of a single pixel, premultiplied in and out.
///
/// `opacity` is the layer's opacity, folded into the source alpha, so a layer
/// at 50% behaves identically to one painted at half alpha.
Rgba8 composite(BlendMode mode, Rgba8 backdrop, Rgba8 source, float opacity = 1.0f);

} // namespace mc
