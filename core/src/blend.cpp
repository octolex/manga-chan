#include "core/blend.h"

#include <algorithm>
#include <cmath>

namespace mc {
namespace {

inline float clamp01(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

inline RgbF clamp01(RgbF c) {
    return RgbF{clamp01(c.r), clamp01(c.g), clamp01(c.b)};
}

// MARK: - Per-channel primitives

inline float multiply(float b, float s) { return b * s; }
inline float screen(float b, float s)   { return b + s - b * s; }

inline float colorDodge(float b, float s) {
    if (b <= 0.0f) return 0.0f;   // backdrop black stays black
    if (s >= 1.0f) return 1.0f;   // source white blows out
    return std::min(1.0f, b / (1.0f - s));
}

inline float colorBurn(float b, float s) {
    if (b >= 1.0f) return 1.0f;
    if (s <= 0.0f) return 0.0f;
    return 1.0f - std::min(1.0f, (1.0f - b) / s);
}

inline float hardLight(float b, float s) {
    return s <= 0.5f ? multiply(b, 2.0f * s)
                     : screen(b, 2.0f * s - 1.0f);
}

inline float softLight(float b, float s) {
    // The W3C piecewise definition. The d() term keeps the curve continuous
    // at b = 0.25, which a naive sqrt does not.
    if (s <= 0.5f) {
        return b - (1.0f - 2.0f * s) * b * (1.0f - b);
    }
    const float d = b <= 0.25f ? ((16.0f * b - 12.0f) * b + 4.0f) * b
                               : std::sqrt(b);
    return b + (2.0f * s - 1.0f) * (d - b);
}

inline float vividLight(float b, float s) {
    return s <= 0.5f ? colorBurn(b, 2.0f * s)
                     : colorDodge(b, 2.0f * s - 1.0f);
}

inline float linearLight(float b, float s) {
    return clamp01(b + 2.0f * s - 1.0f);
}

inline float pinLight(float b, float s) {
    return s <= 0.5f ? std::min(b, 2.0f * s)
                     : std::max(b, 2.0f * s - 1.0f);
}

// MARK: - Non-separable helpers (W3C compositing spec)

inline float luminosity(RgbF c) {
    return 0.30f * c.r + 0.59f * c.g + 0.11f * c.b;
}

/// Pulls a colour back into gamut while preserving its luminosity, which is
/// what stops the component modes producing clipped, hue-shifted results.
RgbF clipColor(RgbF c) {
    const float l = luminosity(c);
    const float n = std::min({c.r, c.g, c.b});
    const float x = std::max({c.r, c.g, c.b});

    if (n < 0.0f) {
        const float d = l - n;
        if (d > 0.0f) {
            c.r = l + (c.r - l) * l / d;
            c.g = l + (c.g - l) * l / d;
            c.b = l + (c.b - l) * l / d;
        }
    }
    if (x > 1.0f) {
        const float d = x - l;
        if (d > 0.0f) {
            c.r = l + (c.r - l) * (1.0f - l) / d;
            c.g = l + (c.g - l) * (1.0f - l) / d;
            c.b = l + (c.b - l) * (1.0f - l) / d;
        }
    }
    return c;
}

RgbF setLuminosity(RgbF c, float l) {
    const float d = l - luminosity(c);
    return clipColor(RgbF{c.r + d, c.g + d, c.b + d});
}

inline float saturation(RgbF c) {
    return std::max({c.r, c.g, c.b}) - std::min({c.r, c.g, c.b});
}

RgbF setSaturation(RgbF c, float s) {
    // The spec phrases this as ranking the channels and rescaling the middle
    // one, but the vector form is identical and far harder to get wrong: the
    // minimum maps to 0, the maximum to s, and the middle keeps its
    // proportion. The shader uses the same expression.
    const float mn = std::min({c.r, c.g, c.b});
    const float mx = std::max({c.r, c.g, c.b});
    if (mx <= mn) {
        return RgbF{0.0f, 0.0f, 0.0f};
    }
    const float scale = s / (mx - mn);
    return RgbF{(c.r - mn) * scale, (c.g - mn) * scale, (c.b - mn) * scale};
}

// MARK: - Pixel conversion

inline RgbF unpremultiply(Rgba8 p, float& alphaOut) {
    const float a = static_cast<float>(p.a) / 255.0f;
    alphaOut = a;
    if (a <= 0.0f) {
        return RgbF{};
    }
    const float inv = 1.0f / (a * 255.0f);
    return RgbF{static_cast<float>(p.r) * inv,
                static_cast<float>(p.g) * inv,
                static_cast<float>(p.b) * inv};
}

inline uint8_t toByte(float v) {
    // +0.5 rounds rather than truncating; truncation would lose a level on
    // every composite and darken a stack of layers measurably.
    return static_cast<uint8_t>(clamp01(v) * 255.0f + 0.5f);
}

} // namespace

const char* blendModeName(BlendMode mode) {
    switch (mode) {
    case BlendMode::Normal:       return "Normal";
    case BlendMode::Multiply:     return "Multiply";
    case BlendMode::Darken:       return "Darken";
    case BlendMode::ColorBurn:    return "Color Burn";
    case BlendMode::LinearBurn:   return "Linear Burn";
    case BlendMode::DarkerColor:  return "Darker Color";
    case BlendMode::Lighten:      return "Lighten";
    case BlendMode::Screen:       return "Screen";
    case BlendMode::ColorDodge:   return "Color Dodge";
    case BlendMode::Add:          return "Add";
    case BlendMode::LighterColor: return "Lighter Color";
    case BlendMode::Overlay:      return "Overlay";
    case BlendMode::SoftLight:    return "Soft Light";
    case BlendMode::HardLight:    return "Hard Light";
    case BlendMode::VividLight:   return "Vivid Light";
    case BlendMode::LinearLight:  return "Linear Light";
    case BlendMode::PinLight:     return "Pin Light";
    case BlendMode::HardMix:      return "Hard Mix";
    case BlendMode::Difference:   return "Difference";
    case BlendMode::Exclusion:    return "Exclusion";
    case BlendMode::Subtract:     return "Subtract";
    case BlendMode::Divide:       return "Divide";
    case BlendMode::Hue:          return "Hue";
    case BlendMode::Saturation:   return "Saturation";
    case BlendMode::Color:        return "Color";
    case BlendMode::Luminosity:   return "Luminosity";
    case BlendMode::Count:        break;
    }
    return "Unknown";
}

bool blendModeIsSeparable(BlendMode mode) {
    switch (mode) {
    case BlendMode::Hue:
    case BlendMode::Saturation:
    case BlendMode::Color:
    case BlendMode::Luminosity:
        return false;
    default:
        return true;
    }
}

RgbF blendFunction(BlendMode mode, RgbF b, RgbF s) {
    auto perChannel = [&](float (*fn)(float, float)) {
        return RgbF{fn(b.r, s.r), fn(b.g, s.g), fn(b.b, s.b)};
    };

    switch (mode) {
    case BlendMode::Normal:      return s;
    case BlendMode::Multiply:    return perChannel(multiply);
    case BlendMode::Screen:      return perChannel(screen);
    case BlendMode::ColorDodge:  return perChannel(colorDodge);
    case BlendMode::ColorBurn:   return perChannel(colorBurn);
    case BlendMode::HardLight:   return perChannel(hardLight);
    case BlendMode::SoftLight:   return perChannel(softLight);
    case BlendMode::VividLight:  return perChannel(vividLight);
    case BlendMode::LinearLight: return perChannel(linearLight);
    case BlendMode::PinLight:    return perChannel(pinLight);

    case BlendMode::Darken:
        return RgbF{std::min(b.r, s.r), std::min(b.g, s.g), std::min(b.b, s.b)};
    case BlendMode::Lighten:
        return RgbF{std::max(b.r, s.r), std::max(b.g, s.g), std::max(b.b, s.b)};

    case BlendMode::Overlay:
        // Hard Light with the operands swapped, per the spec.
        return RgbF{hardLight(s.r, b.r), hardLight(s.g, b.g), hardLight(s.b, b.b)};

    case BlendMode::LinearBurn:
        return clamp01(RgbF{b.r + s.r - 1.0f, b.g + s.g - 1.0f, b.b + s.b - 1.0f});
    case BlendMode::Add:
        return clamp01(RgbF{b.r + s.r, b.g + s.g, b.b + s.b});
    case BlendMode::Subtract:
        return clamp01(RgbF{b.r - s.r, b.g - s.g, b.b - s.b});
    case BlendMode::Divide: {
        auto divide = [](float bb, float ss) {
            return ss <= 0.0f ? 1.0f : std::min(1.0f, bb / ss);
        };
        return RgbF{divide(b.r, s.r), divide(b.g, s.g), divide(b.b, s.b)};
    }

    case BlendMode::Difference:
        return RgbF{std::fabs(b.r - s.r), std::fabs(b.g - s.g), std::fabs(b.b - s.b)};
    case BlendMode::Exclusion:
        return RgbF{b.r + s.r - 2.0f * b.r * s.r,
                    b.g + s.g - 2.0f * b.g * s.g,
                    b.b + s.b - 2.0f * b.b * s.b};

    case BlendMode::HardMix: {
        // Vivid Light pushed to a hard threshold, which is what gives it the
        // posterised look.
        const RgbF v{vividLight(b.r, s.r), vividLight(b.g, s.g), vividLight(b.b, s.b)};
        return RgbF{v.r < 0.5f ? 0.0f : 1.0f,
                    v.g < 0.5f ? 0.0f : 1.0f,
                    v.b < 0.5f ? 0.0f : 1.0f};
    }

    // Whole-colour comparisons, not per channel: the darker *colour* wins
    // outright rather than each channel being compared independently.
    case BlendMode::DarkerColor:
        return luminosity(s) < luminosity(b) ? s : b;
    case BlendMode::LighterColor:
        return luminosity(s) > luminosity(b) ? s : b;

    case BlendMode::Hue:
        return setLuminosity(setSaturation(s, saturation(b)), luminosity(b));
    case BlendMode::Saturation:
        return setLuminosity(setSaturation(b, saturation(s)), luminosity(b));
    case BlendMode::Color:
        return setLuminosity(s, luminosity(b));
    case BlendMode::Luminosity:
        return setLuminosity(b, luminosity(s));

    case BlendMode::Count:
        break;
    }
    return s;
}

Rgba8 composite(BlendMode mode, Rgba8 backdrop, Rgba8 source, float opacity) {
    float ab = 0.0f;
    float as = 0.0f;
    const RgbF cb = unpremultiply(backdrop, ab);
    const RgbF cs = unpremultiply(source, as);

    as *= clamp01(opacity);

    if (as <= 0.0f) {
        return backdrop;   // nothing to add
    }

    const RgbF blended = blendFunction(mode, cb, cs);

    // W3C source-over with a blend function. The three terms are: source over
    // bare canvas, source over backdrop (where the blend applies), and
    // backdrop showing through. The result is premultiplied, which is what
    // tiles store.
    const float ao = as + ab * (1.0f - as);
    auto channel = [&](float sourceC, float blendC, float backdropC) {
        return as * (1.0f - ab) * sourceC
             + as * ab * blendC
             + (1.0f - as) * ab * backdropC;
    };

    return Rgba8{toByte(channel(cs.r, blended.r, cb.r)),
                 toByte(channel(cs.g, blended.g, cb.g)),
                 toByte(channel(cs.b, blended.b, cb.b)),
                 toByte(ao)};
}

} // namespace mc
