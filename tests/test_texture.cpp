#include "check.h"

#include "core/brush_api.h"
#include "core/texture.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <cstdio>
#include <vector>

using namespace mc;

namespace {

constexpr int kGrainSize = 256;

/// A tiny hand-built map, so the sampler is checked against arithmetic that can
/// be done on paper rather than against whatever the generator happened to
/// produce.
AlphaTexture checkerboard(int32_t size) {
    AlphaTexture t(size, size);
    for (int32_t y = 0; y < size; ++y) {
        for (int32_t x = 0; x < size; ++x) {
            t.setTexel(x, y, ((x + y) % 2 == 0) ? 255 : 0);
        }
    }
    return t;
}

/// Coordinate of the centre of texel `i` in a map `n` across.
float texelCentre(int32_t i, int32_t n) {
    return (static_cast<float>(i) + 0.5f) / static_cast<float>(n);
}

int32_t step(const AlphaTexture& a, int32_t ax, int32_t ay,
             const AlphaTexture& b, int32_t bx, int32_t by) {
    return std::abs(static_cast<int32_t>(a.texel(ax, ay, Wrap::Repeat))
                  - static_cast<int32_t>(b.texel(bx, by, Wrap::Repeat)));
}

/// Mean absolute difference between horizontally adjacent texels, away from
/// the edges. This is what "normal" looks like inside the map.
double meanNeighbourStep(const AlphaTexture& t) {
    double total = 0.0;
    long long count = 0;
    for (int32_t y = 0; y < t.height(); ++y) {
        for (int32_t x = 1; x < t.width(); ++x) {
            total += step(t, x, y, t, x - 1, y);
            ++count;
        }
    }
    return count > 0 ? total / static_cast<double>(count) : 0.0;
}

/// Mean absolute difference across the join where `left`'s last column meets
/// `right`'s first — the step a viewer sees at every tile boundary. Passing the
/// same map twice measures its own seam.
double meanSeamStep(const AlphaTexture& left, const AlphaTexture& right) {
    double total = 0.0;
    long long count = 0;
    for (int32_t y = 0; y < left.height(); ++y) {
        total += step(left, left.width() - 1, y, right, 0, y);
        ++count;
    }
    return count > 0 ? total / static_cast<double>(count) : 0.0;
}

void testSamplingHitsTexelCentresExactly() {
    std::printf("a sample at a texel centre returns that texel, not a blend\n");

    AlphaTexture t = checkerboard(4);

    // This is the half-texel convention, and it is the single most likely thing
    // to be wrong between the CPU reference and the Metal sampler. If the
    // offset were missing, every one of these would come back as 0.5.
    for (int32_t y = 0; y < 4; ++y) {
        for (int32_t x = 0; x < 4; ++x) {
            const float expected = ((x + y) % 2 == 0) ? 1.0f : 0.0f;
            const float got = t.sample(texelCentre(x, 4), texelCentre(y, 4), Wrap::Clamp);
            CHECK(std::fabs(got - expected) < 0.001f);
        }
    }
}

void testSamplingBlendsBetweenTexelCentres() {
    std::printf("halfway between two texel centres is their average\n");

    AlphaTexture t = checkerboard(4);

    // Midway between texel 0 (255) and texel 1 (0) along x, on row 0.
    const float u = 0.5f * (texelCentre(0, 4) + texelCentre(1, 4));
    const float got = t.sample(u, texelCentre(0, 4), Wrap::Clamp);
    CHECK(std::fabs(got - 0.5f) < 0.01f);
}

void testRepeatTilesAndClampHolds() {
    std::printf("repeat tiles the map; clamp holds its edge\n");

    AlphaTexture t = checkerboard(4);
    const float u = texelCentre(1, 4);
    const float v = texelCentre(2, 4);

    // Repeat: a whole number of tiles away is the same place. This is what
    // makes grain across an unbounded canvas mean anything.
    CHECK(std::fabs(t.sample(u, v, Wrap::Repeat) - t.sample(u + 1.0f, v, Wrap::Repeat)) < 0.001f);
    CHECK(std::fabs(t.sample(u, v, Wrap::Repeat) - t.sample(u - 3.0f, v + 5.0f, Wrap::Repeat)) < 0.001f);

    // Negative coordinates are the case a truncating `%` gets wrong: it would
    // mirror the map rather than tile it, and the canvas genuinely does have
    // negative coordinates.
    CHECK(std::fabs(t.sample(u - 1.0f, v, Wrap::Repeat) - t.sample(u, v, Wrap::Repeat)) < 0.001f);

    // Clamp: far outside is the border texel, held.
    const float held = t.sample(texelCentre(0, 4), texelCentre(0, 4), Wrap::Clamp);
    CHECK(std::fabs(t.sample(-5.0f, -5.0f, Wrap::Clamp) - held) < 0.001f);
}

void testAnEmptyMapReadsAsUnmodulated() {
    std::printf("a brush with no map draws normally rather than not at all\n");

    AlphaTexture none;
    CHECK(none.empty());
    // 1, not 0. The failure this guards against is a brush that stops drawing
    // entirely the moment grain is switched on with nothing loaded.
    CHECK(std::fabs(none.sample(0.3f, 0.7f, Wrap::Repeat) - 1.0f) < 0.001f);
}

void testGrainIsSeamlessAcrossTheTile() {
    std::printf("grain tiles without a seam\n");

    const AlphaTexture grain = makeGrain(kGrainSize, 12345);
    CHECK_EQ(grain.width(), kGrainSize);
    CHECK_EQ(grain.height(), kGrainSize);

    // A generator that does not wrap draws a visible rectangular grid over
    // every stroke — and only once the map is tiled at canvas scale, which is
    // exactly the kind of bug that is cheap to catch here and expensive to find
    // on the device.
    //
    // The measurement is the step across the seam against the steps found in
    // the interior, and it has to be a mean rather than a maximum: a maximum
    // over 65,000 interior steps is a large number that a bad seam could reach
    // by accident, while the means differ by an order of magnitude.
    const double interiorStep = meanNeighbourStep(grain);
    const double seamStep = meanSeamStep(grain, grain);
    CHECK(interiorStep > 0.5);   // guards against comparing two zeroes
    CHECK(seamStep <= interiorStep * 2.0);

    // And the measurement needs teeth, or the check above passes for the wrong
    // reason. Butting a *different* grain against this one is precisely what a
    // non-wrapping generator produces at every tile boundary, so the same
    // measurement must reject that decisively.
    const double mismatched = meanSeamStep(grain, makeGrain(kGrainSize, 6789));
    CHECK(mismatched > interiorStep * 5.0);
}

void testGrainUsesItsWholeRange() {
    std::printf("grain is actually visible rather than technically present\n");

    const AlphaTexture grain = makeGrain(kGrainSize, 99);

    int32_t lowest = 255;
    int32_t highest = 0;
    double total = 0.0;
    for (size_t i = 0; i < grain.byteCount(); ++i) {
        const int32_t v = grain.pixels()[i];
        lowest = std::min(lowest, v);
        highest = std::max(highest, v);
        total += v;
    }

    // A fractal sum clusters around its mean. Un-normalised it would span
    // perhaps a third of the range, which costs a texture fetch per fragment to
    // produce a grain nobody can see.
    CHECK_EQ(lowest, 0);
    CHECK_EQ(highest, 255);

    const double mean = total / static_cast<double>(grain.byteCount());
    CHECK(mean > 90.0 && mean < 165.0);

    // And it must not be structureless. A map that is half black and half white
    // with nothing between would pass the range check above and look like torn
    // paper rather than tooth.
    size_t midtones = 0;
    for (size_t i = 0; i < grain.byteCount(); ++i) {
        const int32_t v = grain.pixels()[i];
        if (v > 60 && v < 195) ++midtones;
    }
    CHECK(midtones > grain.byteCount() / 4);
}

/// Both controls are exactly the identity in the middle.
///
/// Not approximately. A brush that never opens the grain section must sample
/// the raw map, so this is what makes the whole feature free for every brush
/// that does not use it.
void testGrainLevelsAreNeutralAtZero() {
    std::printf("brightness and contrast are the identity at 0\n");
    for (int32_t i = 0; i <= 255; ++i) {
        const float v = static_cast<float>(i) / 255.0f;
        CHECK(grainLevels(v, 0.0f, 0.0f) == v);
    }
}

/// Contrast pivots at the middle, which is where the map piles up.
void testContrastPivotsAtTheMiddle() {
    std::printf("0.5 is the fixed point of contrast\n");
    for (float c : {-1.0f, -0.5f, 0.0f, 0.37f, 1.0f}) {
        CHECK(std::fabs(grainLevels(0.5f, 0.0f, c) - 0.5f) < 1e-6f);
    }
}

/// Nothing leaves 0...1, whatever is fed in — including a NaN.
///
/// The tooth multiplies a dab's coverage, so a NaN here is not a wrong-looking
/// stroke, it is a stroke that silently does not appear. The clamps are written
/// as negated comparisons for exactly that reason and this is what says so.
void testLevelsNeverLeaveTheUnitRange() {
    std::printf("output stays in range under abusive input\n");
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    for (float s : {0.0f, 0.5f, 1.0f, -3.0f, 4.0f}) {
        for (float b : {-1.0f, 0.0f, 1.0f, -9.0f, 9.0f, nan}) {
            for (float c : {-1.0f, 0.0f, 1.0f, -40.0f, 40.0f, inf, nan}) {
                const float got = grainLevels(s, b, c);
                CHECK(got >= 0.0f && got <= 1.0f);
                CHECK(got == got);  // not NaN
            }
        }
    }
}

/// More contrast means more separation, and it never inverts.
void testContrastSeparatesWithoutInverting() {
    std::printf("contrast opens the map out and keeps its order\n");
    float previous = 0.0f;
    for (float c : {0.0f, 0.25f, 0.5f, 0.75f, 1.0f}) {
        const float spread = grainLevels(0.75f, 0.0f, c) - grainLevels(0.25f, 0.0f, c);
        CHECK(spread >= previous);
        previous = spread;

        // Monotonic in the sample at every setting: a darker place in the map
        // must stay the darker place, or the tooth would be a different pattern
        // rather than the same one harder.
        float last = -1.0f;
        for (int32_t i = 0; i <= 255; ++i) {
            const float v = grainLevels(static_cast<float>(i) / 255.0f, 0.0f, c);
            CHECK(v >= last - 1e-6f);
            last = v;
        }
    }
}

/// Brightness shifts without changing the slope, which is why it is applied
/// after contrast rather than before.
void testBrightnessShiftsWithoutRescaling() {
    std::printf("brightness moves the curve rather than tilting it\n");
    for (float c : {-0.5f, 0.0f, 0.8f}) {
        // Away from the clamps at both ends, so what is being measured is the
        // arithmetic rather than the saturation.
        const float lowAt0 = grainLevels(0.45f, 0.0f, c);
        const float highAt0 = grainLevels(0.55f, 0.0f, c);
        const float lowShifted = grainLevels(0.45f, 0.1f, c);
        const float highShifted = grainLevels(0.55f, 0.1f, c);

        CHECK(std::fabs((lowShifted - lowAt0) - 0.1f) < 1e-5f);
        CHECK(std::fabs((highShifted - highAt0) - 0.1f) < 1e-5f);
        CHECK(std::fabs((highShifted - lowShifted) - (highAt0 - lowAt0)) < 1e-5f);
    }
}

/// **The measurement this control exists for.**
///
/// Our grain map is a fractal sum, and `makeGrain` normalises its *range* —
/// darkest to 0, lightest to 255. That does nothing about its *distribution*:
/// measured here, **90.1% of the map sits between 0.2 and 0.8**, a band wide
/// enough that multiplying coverage by it reads as an even wash rather than as
/// tooth. Full contrast takes that to 14.3%.
///
/// This is the number that retires an argument. Grain attempt one was a plain
/// multiply, rejected in 1f89bd7 for "veiling the whole stroke uniformly", and
/// the device later showed the mechanism was right all along. It was never the
/// multiply. It was that nine tenths of the mask was one shade of grey, and
/// nothing in the brush could change that until now.
void testContrastIsWhatMakesTheMapReadAsTooth() {
    std::printf("how much of the map is mid-grey, and what contrast does to it\n");

    const AlphaTexture grain = makeGrain(kGrainSize, 99);
    const auto midtoneFraction = [&](float contrast) {
        size_t mid = 0;
        for (size_t i = 0; i < grain.byteCount(); ++i) {
            const float v = grainLevels(static_cast<float>(grain.pixels()[i]) / 255.0f,
                                        0.0f, contrast);
            if (v >= 0.2f && v <= 0.8f) ++mid;
        }
        return static_cast<double>(mid) / static_cast<double>(grain.byteCount());
    };

    const double flat = midtoneFraction(0.0f);
    const double crisp = midtoneFraction(1.0f);
    std::printf("  midtones: %.1f%% raw -> %.1f%% at full contrast\n",
                flat * 100.0, crisp * 100.0);

    // Bounds rather than the exact figures, so a change to the generator moves
    // the numbers without failing the test for the wrong reason — but wide
    // enough apart that the claim still means something.
    CHECK(flat > 0.80);
    CHECK(crisp < 0.30);
    CHECK(flat - crisp > 0.5);
}

void testGrainIsDeterministicAndSeedDependent() {
    std::printf("grain is a pure function of its seed\n");

    const AlphaTexture a = makeGrain(64, 7);
    const AlphaTexture b = makeGrain(64, 7);
    const AlphaTexture c = makeGrain(64, 8);

    // Determinism is not a nicety here. The device, the C++ suite and the
    // simulator harness each generate the map themselves rather than sharing a
    // file, so "same seed, same bytes" is what makes them comparable at all.
    bool identical = true;
    bool differs = false;
    for (size_t i = 0; i < a.byteCount(); ++i) {
        if (a.pixels()[i] != b.pixels()[i]) identical = false;
        if (a.pixels()[i] != c.pixels()[i]) differs = true;
    }
    CHECK(identical);
    CHECK(differs);
}

void testGrainSurvivesAwkwardSizes() {
    std::printf("degenerate grain requests fail safe\n");

    // Zero is the size a mis-wired UI slider sends. It must produce an empty
    // map, which samples as 1 — no grain — rather than a map of zeroes, which
    // would silently stop the brush drawing.
    const AlphaTexture zero = makeGrain(0, 1);
    CHECK(zero.empty());
    CHECK(std::fabs(zero.sample(0.5f, 0.5f, Wrap::Repeat) - 1.0f) < 0.001f);

    // A map smaller than its own coarsest lattice: every octave is refused for
    // being finer than the texture, so the field is flat. Flat must mean
    // opaque, again so that the brush keeps drawing.
    const AlphaTexture tiny = makeGrain(4, 1, 8, 4);
    CHECK(!tiny.empty());
    for (size_t i = 0; i < tiny.byteCount(); ++i) {
        CHECK_EQ(tiny.pixels()[i], 255);
    }
}

void testTheAbiRoundTripsTheGrain() {
    std::printf("the grain the shell uploads is the grain the reference reads\n");

    std::vector<uint8_t> map(static_cast<size_t>(kGrainSize) * kGrainSize, 0);
    const size_t written = mc_grain_generate(kGrainSize, 4242, map.data(), map.size());
    CHECK_EQ(static_cast<long long>(written), static_cast<long long>(map.size()));

    // A short buffer must be refused rather than partly filled: the shell sizes
    // its Metal texture from the same number, and a half-written map would
    // upload as a grain with a black band across it.
    CHECK_EQ(static_cast<long long>(mc_grain_generate(kGrainSize, 4242, map.data(), 16)), 0);

    const AlphaTexture direct = makeGrain(kGrainSize, 4242);
    bool same = true;
    for (size_t i = 0; i < map.size(); ++i) {
        if (map[i] != direct.pixels()[i]) same = false;
    }
    CHECK(same);

    // The ABI sampler is what the simulator harness compares Metal against, so
    // it has to agree with the in-process one everywhere, wrapping included.
    const float coordinates[] = { 0.0f, 0.137f, 0.5f, 0.999f, 1.25f, -0.4f };
    for (float u : coordinates) {
        for (float v : coordinates) {
            const float viaAbi = mc_grain_sample(map.data(), kGrainSize, u, v);
            const float viaCore = direct.sample(u, v, Wrap::Repeat);
            CHECK(std::fabs(viaAbi - viaCore) < 0.0005f);
        }
    }

    // A null map is the state before the first upload. It must read as no
    // grain, not as no ink.
    CHECK(std::fabs(mc_grain_sample(nullptr, kGrainSize, 0.5f, 0.5f) - 1.0f) < 0.001f);
}

}  // namespace

int main() {
    testSamplingHitsTexelCentresExactly();
    testSamplingBlendsBetweenTexelCentres();
    testRepeatTilesAndClampHolds();
    testAnEmptyMapReadsAsUnmodulated();
    testGrainIsSeamlessAcrossTheTile();
    testGrainUsesItsWholeRange();
    testGrainLevelsAreNeutralAtZero();
    testContrastPivotsAtTheMiddle();
    testLevelsNeverLeaveTheUnitRange();
    testContrastSeparatesWithoutInverting();
    testBrightnessShiftsWithoutRescaling();
    testContrastIsWhatMakesTheMapReadAsTooth();
    testGrainIsDeterministicAndSeedDependent();
    testGrainSurvivesAwkwardSizes();
    testTheAbiRoundTripsTheGrain();
    return check::report("texture");
}
