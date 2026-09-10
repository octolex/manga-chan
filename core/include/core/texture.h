#pragma once

//
//  texture.h — single-channel alpha maps, and the procedural grain generator.
//
//  A brush samples two kinds of map: the *shape* it stamps, and the *grain* it
//  stamps through. Both are alpha, both are sampled the same way, so both live
//  here.
//
//  The sampler in this file is not a convenience — it is the reference the
//  Metal shader is pinned against in CI. A half-texel offset or a flipped V
//  between CPU and GPU is invisible in a screenshot and obvious in a test, and
//  this is exactly the class of bug that has no chance of being caught without
//  a frame debugger. `sample()` therefore reproduces Metal's filtering
//  convention deliberately: texel centres at (i + 0.5) / n, bilinear between
//  them, 8-bit values scaled by 1/255.
//
//  The grain is *generated* rather than loaded. That defers the asset-format
//  question to the brush editor, where it belongs, and it buys something a file
//  could not: the texture is a pure function of its seed, so bit-identical
//  grain exists in the C++ suite, in the simulator harness, and on the device
//  without an asset crossing between them.
//

#include <cstdint>
#include <vector>

namespace mc {

/// How coordinates outside 0...1 resolve.
enum class Wrap : int32_t {
    /// Tiles. Grain uses this: it repeats across an unbounded canvas.
    Repeat = 0,

    /// Holds the edge value. Shape maps use this, so a dab fades out at its
    /// rim rather than smearing the border pixel across the quad.
    Clamp = 1,
};

/// A single-channel 8-bit alpha map, row-major from the top left.
///
/// 8 bits rather than float: this is the format that reaches the GPU
/// (`r8Unorm`), and holding it at higher precision on the CPU would mean the
/// reference and the shader disagree in the last bit for no gain.
class AlphaTexture {
public:
    AlphaTexture() = default;
    AlphaTexture(int32_t width, int32_t height);

    int32_t width() const noexcept { return width_; }
    int32_t height() const noexcept { return height_; }
    bool empty() const noexcept { return pixels_.empty(); }

    /// Row-major, `width * height` bytes. Handed straight to a Metal texture.
    const uint8_t* pixels() const noexcept { return pixels_.data(); }
    size_t byteCount() const noexcept { return pixels_.size(); }

    uint8_t texel(int32_t x, int32_t y, Wrap wrap) const noexcept;
    void setTexel(int32_t x, int32_t y, uint8_t value) noexcept;

    /// Bilinear, `u` and `v` normalised. Matches Metal's `filter::linear`.
    /// An empty texture samples as 1, so a brush with no map behaves as a
    /// brush that is not modulated rather than as one that draws nothing.
    float sample(float u, float v, Wrap wrap) const noexcept;

private:
    int32_t width_ = 0;
    int32_t height_ = 0;
    std::vector<uint8_t> pixels_;
};

/// Bilinear sample of a borrowed, row-major 8-bit map.
///
/// `AlphaTexture::sample` is a thin call onto this, so the two cannot drift.
/// It exists because the reference sampler's most important caller is the
/// simulator harness, which reads back the very bytes it uploaded to Metal and
/// would otherwise have to copy a texture per sample to ask about them.
float sampleAlpha(const uint8_t* pixels, int32_t width, int32_t height,
                  float u, float v, Wrap wrap) noexcept;

/// Procreate's grain **Brightness** and **Contrast**, applied to one sampled
/// value of the map.
///
/// Both are signed, -1 to +1, with 0 neutral — the way Procreate presents them,
/// as a slider that starts in the middle. `grainLevels(g, 0, 0) == g` exactly,
/// so a brush that never touches either control samples the raw map.
///
/// **Why this is needed at all, given `makeGrain` already normalises.** That
/// normalisation fixes the *range* — it stretches the darkest sample to 0 and
/// the lightest to 255 — and does nothing about the *distribution*. A fractal
/// sum is a sum of independent octaves, so its values pile up near the mean
/// however far the extremes are stretched: most of the map sits close to
/// mid-grey with a thin tail at each end. Multiplied into coverage that reads
/// as an even wash rather than as tooth, which is exactly the complaint that
/// killed the first grain attempt in 1f89bd7 and was later shown to be a
/// complaint about the map rather than about the mechanism.
///
/// Contrast pivots at 0.5 and is a **multiplicative gain**, `2^(3c)`, so the
/// range runs from an eighth to eight times and the two halves of the slider
/// are mirror images of one another. A linear `1 + c` was the obvious choice
/// and tops out at 2x, which is not enough to turn a mid-grey pile into pits:
/// the whole point of the control is reaching a near-threshold at the end of
/// its travel.
///
/// Contrast is applied before brightness, so brightness shifts the curve
/// without changing its slope. The other order makes the two controls fight —
/// every brightness change would rescale itself by the contrast.
float grainLevels(float sample, float brightness, float contrast) noexcept;

/// Generates a seamlessly tiling grain map.
///
/// Seamless is the whole difficulty. Grain repeats across the canvas, so a
/// generator that does not wrap draws a visible rectangular grid over every
/// stroke — the failure is not subtle, but it also does not show up until the
/// texture is tiled at scale on a real canvas. Here it is seamless by
/// construction: every octave's lattice is indexed modulo its own period, and
/// the periods divide the texture exactly.
///
/// `size` must be positive; `lattice` is the cell count of the coarsest
/// octave. The result is normalised to the full 0...255 range, because a raw
/// fractal sum clusters around its mean and reads as no texture at all.
AlphaTexture makeGrain(int32_t size, uint64_t seed,
                       int32_t lattice = 8, int32_t octaves = 4);

}  // namespace mc
