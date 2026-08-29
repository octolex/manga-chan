#include "core/blend_api.h"

#include "core/blend.h"

using namespace mc;

namespace {

BlendMode toMode(int32_t index) {
    // The shell owns this integer, so it cannot be trusted to be in range.
    if (index < 0 || index >= static_cast<int32_t>(BlendMode::Count)) {
        return BlendMode::Normal;
    }
    return static_cast<BlendMode>(index);
}

} // namespace

int32_t mc_blend_mode_count(void) {
    return static_cast<int32_t>(BlendMode::Count);
}

const char* mc_blend_mode_name(int32_t mode) {
    if (mode < 0 || mode >= static_cast<int32_t>(BlendMode::Count)) {
        return "Unknown";
    }
    return blendModeName(static_cast<BlendMode>(mode));
}

int32_t mc_blend_mode_is_separable(int32_t mode) {
    return blendModeIsSeparable(toMode(mode)) ? 1 : 0;
}

void mc_blend_pixel(int32_t mode,
                    const uint8_t* backdrop,
                    const uint8_t* source,
                    float opacity,
                    uint8_t* out) {
    if (backdrop == nullptr || source == nullptr || out == nullptr) {
        return;
    }

    const Rgba8 b{backdrop[0], backdrop[1], backdrop[2], backdrop[3]};
    const Rgba8 s{source[0], source[1], source[2], source[3]};
    const Rgba8 result = composite(toMode(mode), b, s, opacity);

    out[0] = result.r;
    out[1] = result.g;
    out[2] = result.b;
    out[3] = result.a;
}
