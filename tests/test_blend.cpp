#include "check.h"

#include "core/blend.h"

#include <cmath>
#include <cstring>
#include <string>

using namespace mc;

namespace {

const Rgba8 kWhite{255, 255, 255, 255};
const Rgba8 kBlack{0, 0, 0, 255};
const Rgba8 kMidGrey{128, 128, 128, 255};
const Rgba8 kRed{255, 0, 0, 255};
const Rgba8 kTransparent{0, 0, 0, 0};

bool nearly(Rgba8 a, Rgba8 b, int tolerance = 1) {
    auto close = [tolerance](uint8_t x, uint8_t y) {
        return std::abs(static_cast<int>(x) - static_cast<int>(y)) <= tolerance;
    };
    return close(a.r, b.r) && close(a.g, b.g) && close(a.b, b.b) && close(a.a, b.a);
}

void testNormalReplacesBackdrop() {
    std::printf("normal replaces the backdrop\n");

    CHECK(nearly(composite(BlendMode::Normal, kBlack, kRed), kRed));
    CHECK(nearly(composite(BlendMode::Normal, kWhite, kRed), kRed));
}

void testTransparentSourceIsANoOp() {
    std::printf("transparent source is a no-op\n");

    // Every mode must leave the backdrop untouched when there is nothing to
    // blend, or an empty layer would tint everything under it.
    for (uint8_t m = 0; m < static_cast<uint8_t>(BlendMode::Count); ++m) {
        const auto mode = static_cast<BlendMode>(m);
        CHECK(composite(mode, kRed, kTransparent) == kRed);
        CHECK(composite(mode, kRed, kWhite, 0.0f) == kRed);
    }
}

void testMultiply() {
    std::printf("multiply\n");

    // Multiplying by white is identity; by black is black. These are the two
    // properties artists actually rely on when shading.
    CHECK(nearly(composite(BlendMode::Multiply, kWhite, kRed), kRed));
    CHECK(nearly(composite(BlendMode::Multiply, kBlack, kRed), kBlack));
    CHECK(nearly(composite(BlendMode::Multiply, kMidGrey, kMidGrey),
                 Rgba8{64, 64, 64, 255}));
}

void testScreen() {
    std::printf("screen\n");

    // The mirror of multiply: black is identity, white saturates.
    CHECK(nearly(composite(BlendMode::Screen, kBlack, kRed), kRed));
    CHECK(nearly(composite(BlendMode::Screen, kWhite, kRed), kWhite));
}

void testDarkenAndLighten() {
    std::printf("darken and lighten\n");

    const Rgba8 mixed{200, 50, 128, 255};
    CHECK(nearly(composite(BlendMode::Darken, kMidGrey, mixed),
                 Rgba8{128, 50, 128, 255}));
    CHECK(nearly(composite(BlendMode::Lighten, kMidGrey, mixed),
                 Rgba8{200, 128, 128, 255}));
}

void testDifferenceOfIdenticalIsBlack() {
    std::printf("difference of identical colours is black\n");

    // The standard way an artist checks two layers are identical.
    CHECK(nearly(composite(BlendMode::Difference, kRed, kRed), kBlack));
    CHECK(nearly(composite(BlendMode::Difference, kMidGrey, kMidGrey), kBlack));
}

void testOverlayIsHardLightSwapped() {
    std::printf("overlay is hard light with operands swapped\n");

    // Not a coincidence to be rediscovered later — it is the definition, and
    // the shader should share the same helper.
    const RgbF backdrop{0.3f, 0.6f, 0.9f};
    const RgbF source{0.7f, 0.2f, 0.5f};

    const RgbF overlay = blendFunction(BlendMode::Overlay, backdrop, source);
    const RgbF hardLight = blendFunction(BlendMode::HardLight, source, backdrop);

    CHECK(std::fabs(overlay.r - hardLight.r) < 1e-6f);
    CHECK(std::fabs(overlay.g - hardLight.g) < 1e-6f);
    CHECK(std::fabs(overlay.b - hardLight.b) < 1e-6f);
}

void testOpacityScalesContribution() {
    std::printf("opacity scales contribution\n");

    // White over black at half opacity lands at mid grey.
    const Rgba8 half = composite(BlendMode::Normal, kBlack, kWhite, 0.5f);
    CHECK(nearly(half, Rgba8{128, 128, 128, 255}, 2));

    CHECK(nearly(composite(BlendMode::Normal, kBlack, kWhite, 1.0f), kWhite));
    CHECK(composite(BlendMode::Normal, kBlack, kWhite, 0.0f) == kBlack);
}

void testCompositingOverTransparentBackdrop() {
    std::printf("compositing over a transparent backdrop\n");

    // Painting onto an empty layer must produce the source unchanged, not a
    // colour darkened toward the transparent black underneath it.
    for (uint8_t m = 0; m < static_cast<uint8_t>(BlendMode::Count); ++m) {
        const auto mode = static_cast<BlendMode>(m);
        CHECK(nearly(composite(mode, kTransparent, kRed), kRed));
    }
}

void testAlphaAccumulates() {
    std::printf("alpha accumulates\n");

    const Rgba8 halfRed{128, 0, 0, 128};   // premultiplied
    const Rgba8 result = composite(BlendMode::Normal, halfRed, halfRed);
    // 0.5 + 0.5 * (1 - 0.5) = 0.75
    CHECK(nearly(Rgba8{0, 0, 0, result.a}, Rgba8{0, 0, 0, 191}, 2));
}

void testEveryModeStaysInRange() {
    std::printf("every mode stays in range\n");

    // The test that catches NaN, division by zero and overflow across the
    // whole set. Component modes and the light modes all have singularities
    // that only show up at the extremes.
    const uint8_t levels[] = {0, 1, 64, 128, 200, 254, 255};
    const uint8_t alphas[] = {0, 1, 128, 255};

    size_t combinations = 0;
    bool allFinite = true;

    for (uint8_t m = 0; m < static_cast<uint8_t>(BlendMode::Count); ++m) {
        const auto mode = static_cast<BlendMode>(m);
        for (uint8_t bl : levels) {
            for (uint8_t sl : levels) {
                for (uint8_t ba : alphas) {
                    for (uint8_t sa : alphas) {
                        // Keep the inputs premultiplied-legal: a channel can
                        // never exceed its own alpha.
                        const Rgba8 backdrop{
                            static_cast<uint8_t>(std::min<int>(bl, ba)),
                            static_cast<uint8_t>(std::min<int>(bl, ba)),
                            static_cast<uint8_t>(std::min<int>(bl, ba)), ba};
                        const Rgba8 source{
                            static_cast<uint8_t>(std::min<int>(sl, sa)),
                            static_cast<uint8_t>(std::min<int>(sl, sa)),
                            static_cast<uint8_t>(std::min<int>(sl, sa)), sa};

                        const Rgba8 out = composite(mode, backdrop, source, 0.75f);
                        // uint8_t cannot represent out-of-range, so a NaN or
                        // overflow shows up as the premultiplied invariant
                        // breaking instead.
                        if (out.r > out.a || out.g > out.a || out.b > out.a) {
                            allFinite = false;
                        }
                        ++combinations;
                    }
                }
            }
        }
    }

    CHECK(allFinite);
    std::printf("  %zu combinations across %d modes, all premultiplied-legal\n",
                combinations, static_cast<int>(BlendMode::Count));
}

void testSeparabilityClassification() {
    std::printf("separability classification\n");

    // The GPU path needs a different shader for the non-separable modes, so
    // this classification has to be right.
    CHECK(blendModeIsSeparable(BlendMode::Multiply));
    CHECK(blendModeIsSeparable(BlendMode::HardMix));
    CHECK(!blendModeIsSeparable(BlendMode::Hue));
    CHECK(!blendModeIsSeparable(BlendMode::Saturation));
    CHECK(!blendModeIsSeparable(BlendMode::Color));
    CHECK(!blendModeIsSeparable(BlendMode::Luminosity));
}

void testLuminosityPreservesSourceBrightness() {
    std::printf("luminosity takes brightness from the source\n");

    // Luminosity keeps the backdrop's hue and saturation but adopts the
    // source's brightness, which is how tones get applied over flats.
    const RgbF backdrop{0.8f, 0.2f, 0.2f};   // saturated red
    const RgbF source{0.5f, 0.5f, 0.5f};     // neutral grey

    const RgbF result = blendFunction(BlendMode::Luminosity, backdrop, source);
    const float resultLum = 0.30f * result.r + 0.59f * result.g + 0.11f * result.b;
    CHECK(std::fabs(resultLum - 0.5f) < 0.01f);

    // Still recognisably red rather than grey.
    CHECK(result.r > result.g);
    CHECK(result.r > result.b);
}

void testColorTakesHueFromSource() {
    std::printf("color takes hue from the source\n");

    const RgbF backdrop{0.5f, 0.5f, 0.5f};   // neutral
    const RgbF source{0.9f, 0.1f, 0.1f};     // red

    const RgbF result = blendFunction(BlendMode::Color, backdrop, source);
    const float resultLum = 0.30f * result.r + 0.59f * result.g + 0.11f * result.b;

    // Backdrop brightness is preserved; the hue comes from the source.
    CHECK(std::fabs(resultLum - 0.5f) < 0.01f);
    CHECK(result.r > result.g);
}

void testEveryModeHasAName() {
    std::printf("every mode has a name\n");

    for (uint8_t m = 0; m < static_cast<uint8_t>(BlendMode::Count); ++m) {
        const std::string name = blendModeName(static_cast<BlendMode>(m));
        CHECK(!name.empty());
        CHECK(name != "Unknown");
    }
    std::printf("  %d modes implemented\n", static_cast<int>(BlendMode::Count));
}

} // namespace

int main() {
    testNormalReplacesBackdrop();
    testTransparentSourceIsANoOp();
    testMultiply();
    testScreen();
    testDarkenAndLighten();
    testDifferenceOfIdenticalIsBlack();
    testOverlayIsHardLightSwapped();
    testOpacityScalesContribution();
    testCompositingOverTransparentBackdrop();
    testAlphaAccumulates();
    testEveryModeStaysInRange();
    testSeparabilityClassification();
    testLuminosityPreservesSourceBrightness();
    testColorTakesHueFromSource();
    testEveryModeHasAName();
    return check::report("blend");
}
