#include "core/texture.h"

#include <algorithm>
#include <cmath>

namespace mc {
namespace {

/// Floored modulo. `%` truncates toward zero in C++, so a negative coordinate
/// would mirror the texture rather than tile it — and canvas coordinates go
/// negative, because the canvas is unbounded in all directions.
int32_t floorMod(int32_t value, int32_t modulus) noexcept {
    const int32_t r = value % modulus;
    return r < 0 ? r + modulus : r;
}

/// Value at one lattice point, in 0...1. Deterministic from the seed.
float latticeValue(int32_t x, int32_t y, uint64_t seed) noexcept {
    uint64_t h = seed;
    h ^= static_cast<uint64_t>(static_cast<uint32_t>(x)) * 0xA0761D6478BD642FULL;
    h ^= static_cast<uint64_t>(static_cast<uint32_t>(y)) * 0xE7037ED1A0B428DBULL;
    h ^= h >> 32;
    h *= 0xBF58476D1CE4E5B9ULL;
    h ^= h >> 29;
    h *= 0x94D049BB133111EBULL;
    h ^= h >> 32;
    return static_cast<float>((h >> 40) & 0xFFFFFF) / 16777215.0f;
}

/// Hermite ease. Linear interpolation between lattice points would leave a
/// visible crease along every cell boundary, which tiles into a grid — the
/// same artefact the wrapping is there to avoid, arriving by another route.
float ease(float t) noexcept {
    return t * t * (3.0f - 2.0f * t);
}

float lerp(float a, float b, float t) noexcept {
    return a + (b - a) * t;
}

/// One octave of value noise on a lattice that wraps at `period`, which is
/// what makes the result tile.
float valueNoise(float x, float y, int32_t period, uint64_t seed) noexcept {
    const int32_t x0 = static_cast<int32_t>(std::floor(x));
    const int32_t y0 = static_cast<int32_t>(std::floor(y));
    const float fx = ease(x - static_cast<float>(x0));
    const float fy = ease(y - static_cast<float>(y0));

    const int32_t xa = floorMod(x0, period);
    const int32_t xb = floorMod(x0 + 1, period);
    const int32_t ya = floorMod(y0, period);
    const int32_t yb = floorMod(y0 + 1, period);

    const float top = lerp(latticeValue(xa, ya, seed), latticeValue(xb, ya, seed), fx);
    const float bottom = lerp(latticeValue(xa, yb, seed), latticeValue(xb, yb, seed), fx);
    return lerp(top, bottom, fy);
}

}  // namespace

AlphaTexture::AlphaTexture(int32_t width, int32_t height)
    : width_(std::max(0, width)), height_(std::max(0, height)) {
    if (width_ > 0 && height_ > 0) {
        pixels_.assign(static_cast<size_t>(width_) * static_cast<size_t>(height_), 0);
    } else {
        width_ = 0;
        height_ = 0;
    }
}

namespace {

uint8_t texelAt(const uint8_t* pixels, int32_t width, int32_t height,
                int32_t x, int32_t y, Wrap wrap) noexcept {
    if (wrap == Wrap::Repeat) {
        x = floorMod(x, width);
        y = floorMod(y, height);
    } else {
        x = std::clamp(x, 0, width - 1);
        y = std::clamp(y, 0, height - 1);
    }
    return pixels[static_cast<size_t>(y) * static_cast<size_t>(width) + static_cast<size_t>(x)];
}

}  // namespace

uint8_t AlphaTexture::texel(int32_t x, int32_t y, Wrap wrap) const noexcept {
    if (pixels_.empty()) return 255;
    return texelAt(pixels_.data(), width_, height_, x, y, wrap);
}

void AlphaTexture::setTexel(int32_t x, int32_t y, uint8_t value) noexcept {
    if (pixels_.empty()) return;
    if (x < 0 || y < 0 || x >= width_ || y >= height_) return;
    pixels_[static_cast<size_t>(y) * static_cast<size_t>(width_) + static_cast<size_t>(x)] = value;
}

float sampleAlpha(const uint8_t* pixels, int32_t width, int32_t height,
                  float u, float v, Wrap wrap) noexcept {
    // An absent map must read as "not modulated". Returning 0 here would make
    // a brush with no grain draw nothing at all, which is a spectacular way to
    // fail for a feature whose whole job is to be subtle.
    if (pixels == nullptr || width <= 0 || height <= 0) return 1.0f;

    // Texel centres sit at (i + 0.5) / n, matching Metal's linear filter. The
    // half-texel is the entire content of these two lines and the reason the
    // CPU and GPU results can be compared at all.
    const float x = u * static_cast<float>(width) - 0.5f;
    const float y = v * static_cast<float>(height) - 0.5f;

    const int32_t x0 = static_cast<int32_t>(std::floor(x));
    const int32_t y0 = static_cast<int32_t>(std::floor(y));
    const float fx = x - static_cast<float>(x0);
    const float fy = y - static_cast<float>(y0);

    const float c00 = static_cast<float>(texelAt(pixels, width, height, x0, y0, wrap));
    const float c10 = static_cast<float>(texelAt(pixels, width, height, x0 + 1, y0, wrap));
    const float c01 = static_cast<float>(texelAt(pixels, width, height, x0, y0 + 1, wrap));
    const float c11 = static_cast<float>(texelAt(pixels, width, height, x0 + 1, y0 + 1, wrap));

    const float top = lerp(c00, c10, fx);
    const float bottom = lerp(c01, c11, fx);
    return lerp(top, bottom, fy) / 255.0f;
}

float AlphaTexture::sample(float u, float v, Wrap wrap) const noexcept {
    if (pixels_.empty()) return 1.0f;
    return sampleAlpha(pixels_.data(), width_, height_, u, v, wrap);
}

AlphaTexture makeGrain(int32_t size, uint64_t seed, int32_t lattice, int32_t octaves) {
    if (size <= 0) return {};
    lattice = std::max(1, lattice);
    octaves = std::max(1, octaves);

    AlphaTexture texture(size, size);
    std::vector<float> field(static_cast<size_t>(size) * static_cast<size_t>(size), 0.0f);

    float lowest = 1e30f;
    float highest = -1e30f;

    for (int32_t y = 0; y < size; ++y) {
        for (int32_t x = 0; x < size; ++x) {
            // Sampled at texel centres in the unit square, so the field is a
            // function of position rather than of resolution: the same grain
            // at 128 and at 512 differs in detail, not in character.
            const float u = (static_cast<float>(x) + 0.5f) / static_cast<float>(size);
            const float v = (static_cast<float>(y) + 0.5f) / static_cast<float>(size);

            float total = 0.0f;
            float weight = 0.0f;
            float amplitude = 1.0f;

            for (int32_t octave = 0; octave < octaves; ++octave) {
                const int32_t period = lattice << octave;
                // A lattice finer than the texture is sampled below its own
                // Nyquist rate: it adds noise that changes with resolution
                // instead of detail that does not.
                if (period > size) break;

                total += amplitude * valueNoise(u * static_cast<float>(period),
                                                v * static_cast<float>(period),
                                                period, seed + static_cast<uint64_t>(octave) * 0x9E3779B9ULL);
                weight += amplitude;
                amplitude *= 0.5f;
            }

            const float value = weight > 0.0f ? total / weight : 1.0f;
            field[static_cast<size_t>(y) * static_cast<size_t>(size) + static_cast<size_t>(x)] = value;
            lowest = std::min(lowest, value);
            highest = std::max(highest, value);
        }
    }

    // Stretch to the full range. A fractal sum clusters hard around its mean —
    // left alone it produces a grain that is technically present and visually
    // absent, which is worse than no grain because it costs a texture fetch to
    // achieve nothing.
    const float span = highest - lowest;
    for (int32_t y = 0; y < size; ++y) {
        for (int32_t x = 0; x < size; ++x) {
            const float value = field[static_cast<size_t>(y) * static_cast<size_t>(size) + static_cast<size_t>(x)];
            // A degenerate field normalises to opaque rather than to
            // transparent: an unexpectedly flat grain should read as no grain,
            // not as a brush that has stopped drawing.
            const float scaled = span > 1e-6f ? (value - lowest) / span : 1.0f;
            texture.setTexel(x, y, static_cast<uint8_t>(std::lround(scaled * 255.0f)));
        }
    }

    return texture;
}

}  // namespace mc
