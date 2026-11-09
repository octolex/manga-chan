#include "check.h"

#include "core/brush.h"
#include "core/input_filter.h"
#include "core/stroke.h"
#include "core/tile.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

using namespace mc;

//
//  The input filter: StreamLine, Stabilization, Motion filtering, and the
//  app-wide pressure settings — plus the stroke-path changes that went in
//  with them on 2026-11-06 (centripetal spline, sub-pixel reach, revised-dab
//  index).
//

namespace {

StrokeSample sampleAt(float x, float y, double t, float pressure = 1.0f) {
    StrokeSample s;
    s.x = x;
    s.y = y;
    s.timestamp = t;
    s.pressure = pressure;
    return s;
}

/// A deterministic wobble: the sum of two incommensurate sines, so it has no
/// period the filters could lock onto by accident.
float wobble(int i) {
    return 3.0f * std::sin(static_cast<float>(i) * 1.7f)
         + 2.0f * std::sin(static_cast<float>(i) * 0.61f + 1.0f);
}

/// Root-mean-square distance from y = 100 over the filtered samples of a slow,
/// wobbly horizontal line.
float residualWobble(const Brush& brush, const InputSettings& settings) {
    InputFilter filter(brush, settings);
    double sum = 0.0;
    int counted = 0;
    for (int i = 0; i < 480; ++i) {   // two seconds at 240 Hz, 50 px/s
        const double t = i / 240.0;
        const StrokeSample out = filter.filter(
            sampleAt(static_cast<float>(t * 50.0), 100.0f + wobble(i), t));
        if (i >= 120) {   // after the filters have settled
            const double d = out.y - 100.0;
            sum += d * d;
            ++counted;
        }
    }
    return static_cast<float>(std::sqrt(sum / counted));
}

/// How far behind the pen the filtered position is, at the end of a fast
/// straight sweep.
float lagAtSpeed(const Brush& brush, const InputSettings& settings, float speed) {
    InputFilter filter(brush, settings);
    StrokeSample out;
    float x = 0.0f;
    for (int i = 0; i < 120; ++i) {
        const double t = i / 240.0;
        x = static_cast<float>(t * speed);
        out = filter.filter(sampleAt(x, 100.0f, t));
    }
    return x - out.x;
}

void testIdentityWhenEverythingIsOff() {
    std::printf("an inactive filter returns its input bit for bit\n");
    Brush brush;
    InputFilter filter(brush, InputSettings{});
    CHECK(filter.isIdentity());
    for (int i = 0; i < 50; ++i) {
        const StrokeSample in = sampleAt(1.1f * i + wobble(i), 3.3f * i, i / 97.0, 0.37f);
        const StrokeSample out = filter.filter(in);
        CHECK(out.x == in.x && out.y == in.y && out.pressure == in.pressure);
    }
}

void testStreamLineKeepsItsPencilMeaning() {
    std::printf("StreamLine at 240 Hz pulls by exactly the setting, as before\n");
    Brush brush;
    brush.smoothing = 0.6f;
    InputFilter filter(brush, InputSettings{});
    filter.filter(sampleAt(0.0f, 0.0f, 0.0));
    const StrokeSample out = filter.filter(sampleAt(100.0f, 0.0f, 1.0 / 240.0));
    // The old per-sample rule: lerp(sample, previous, k) = 0.4 * 100.
    CHECK(std::fabs(out.x - 40.0f) < 1e-3f);
}

void testStreamLineIsRateIndependent() {
    std::printf("StreamLine smooths a finger as hard as a Pencil\n");
    Brush brush;
    brush.smoothing = 0.8f;

    // A step to x = 100, held, sampled at 240 Hz and at 60 Hz. After the same
    // elapsed time both must have travelled the same distance.
    auto after = [&](double rate) {
        InputFilter filter(brush, InputSettings{});
        filter.filter(sampleAt(0.0f, 0.0f, 0.0));
        StrokeSample out;
        for (int i = 1; i <= static_cast<int>(rate * 0.05); ++i) {
            out = filter.filter(sampleAt(100.0f, 0.0f, i / rate));
        }
        return out.x;
    };
    const float pencil = after(240.0);
    const float finger = after(60.0);
    std::printf("    after 0.05 s: %.2f px at 240 Hz, %.2f px at 60 Hz\n", pencil, finger);
    CHECK(std::fabs(pencil - finger) < 0.5f);
    // And it still smooths: neither has arrived.
    CHECK(pencil < 97.0f);
}

void testMotionFilteringParameters() {
    std::printf("Motion filtering: Amount filters harder, Expression restores speed\n");
    const OneEuroParameters light = motionFilteringParameters(0.2f, 0.5f);
    const OneEuroParameters heavy = motionFilteringParameters(0.9f, 0.5f);
    CHECK(heavy.minCutoff < light.minCutoff);

    const OneEuroParameters flat = motionFilteringParameters(0.5f, 0.0f);
    const OneEuroParameters lively = motionFilteringParameters(0.5f, 1.0f);
    CHECK(lively.beta > flat.beta);

    // "The higher Motion filtering is set, the less effect Expression has."
    const float lowSpan = motionFilteringParameters(0.2f, 1.0f).beta
                        - motionFilteringParameters(0.2f, 0.0f).beta;
    const float highSpan = motionFilteringParameters(0.9f, 1.0f).beta
                         - motionFilteringParameters(0.9f, 0.0f).beta;
    CHECK(highSpan < lowSpan);
}

void testMotionFilteringRemovesWobble() {
    std::printf("Motion filtering removes slow wobble, and Expression keeps fast strokes close\n");
    Brush raw;
    const float before = residualWobble(raw, InputSettings{});

    Brush filtered;
    filtered.motionFiltering = 0.7f;
    const float after = residualWobble(filtered, InputSettings{});
    std::printf("    wobble %.2f px -> %.2f px\n", before, after);
    CHECK(after < before * 0.5f);

    // Expression: a fast sweep lags less with it than without.
    Brush flat = filtered;
    flat.motionFilteringExpression = 0.0f;
    Brush lively = filtered;
    lively.motionFilteringExpression = 1.0f;
    const float lagFlat = lagAtSpeed(flat, InputSettings{}, 2000.0f);
    const float lagLively = lagAtSpeed(lively, InputSettings{}, 2000.0f);
    std::printf("    lag at 2000 px/s: %.1f px flat, %.1f px with expression\n", lagFlat, lagLively);
    CHECK(lagLively < lagFlat);
}

void testStabilizationAverages() {
    std::printf("Stabilization squashes wobble toward the central line\n");
    Brush raw;
    Brush stabilized;
    stabilized.stabilization = 0.6f;
    const float before = residualWobble(raw, InputSettings{});
    const float after = residualWobble(stabilized, InputSettings{});
    std::printf("    wobble %.2f px -> %.2f px\n", before, after);
    CHECK(after < before * 0.5f);

    // The window is time, so a held step arrives once the window has passed.
    InputFilter filter(stabilized, InputSettings{});
    filter.filter(sampleAt(0.0f, 0.0f, 0.0));
    StrokeSample out;
    const double window = InputFilter::kStabilizationWindow * 0.6;
    for (int i = 1; i <= static_cast<int>((window + 0.05) * 240.0); ++i) {
        out = filter.filter(sampleAt(100.0f, 0.0f, i / 240.0));
    }
    CHECK(std::fabs(out.x - 100.0f) < 1e-3f);
}

void testGlobalSettingsAreAFloor() {
    std::printf("global Stabilization and Motion filtering apply to a brush without them\n");
    Brush brush;   // none of its own
    InputSettings global;
    global.stabilization = 0.6f;
    CHECK(residualWobble(brush, global) < residualWobble(brush, InputSettings{}) * 0.5f);

    InputSettings motion;
    motion.motionFiltering = 0.7f;
    CHECK(residualWobble(brush, motion) < residualWobble(brush, InputSettings{}) * 0.5f);
}

void testPressureCurveAndSmoothing() {
    std::printf("the person's pressure curve and pressure smoothing\n");
    Brush brush;
    InputSettings settings;
    settings.pressureCurve.count = 1;
    settings.pressureCurve.x[0] = 0.5f;
    settings.pressureCurve.y[0] = 0.2f;
    InputFilter curved(brush, settings);
    CHECK(!curved.isIdentity());
    const StrokeSample out = curved.filter(sampleAt(0.0f, 0.0f, 0.0, 0.5f));
    CHECK(std::fabs(out.pressure - 0.2f) < 1e-4f);

    // A finger's synthesised pressure is left alone.
    InputFilter fingerFilter(brush, settings);
    StrokeSample finger = sampleAt(0.0f, 0.0f, 0.0, 0.5f);
    finger.fromPressureDevice = false;
    CHECK(std::fabs(fingerFilter.filter(finger).pressure - 0.5f) < 1e-6f);

    InputSettings smooth;
    smooth.pressureSmoothing = 1.0f;
    InputFilter filter(brush, smooth);
    filter.filter(sampleAt(0.0f, 0.0f, 0.0, 0.0f));
    const StrokeSample next = filter.filter(sampleAt(1.0f, 0.0f, 1.0 / 240.0, 1.0f));
    CHECK(next.pressure > 0.0f && next.pressure < 0.1f);
    StrokeSample settled;
    for (int i = 2; i < 240; ++i) {
        settled = filter.filter(sampleAt(static_cast<float>(i), 0.0f, i / 240.0, 1.0f));
    }
    CHECK(settled.pressure > 0.99f);
}

void testInputSettingsOnlyBeforeTheFirstSample() {
    std::printf("input settings cannot change part-way through a stroke\n");
    Brush brush;
    brush.spacing = 0.1f;
    InputSettings curve;
    curve.pressureCurve.count = 1;
    curve.pressureCurve.x[0] = 0.5f;
    curve.pressureCurve.y[0] = 0.1f;

    StrokePath early(brush);
    early.setInputSettings(curve);
    early.addSample(sampleAt(0.0f, 0.0f, 0.0, 0.5f));
    CHECK(std::fabs(early.nodeSamples().front().pressure - 0.1f) < 1e-4f);

    StrokePath late(brush);
    late.addSample(sampleAt(0.0f, 0.0f, 0.0, 0.5f));
    late.setInputSettings(curve);
    late.addSample(sampleAt(10.0f, 0.0f, 0.01, 0.5f));
    CHECK(std::fabs(late.nodeSamples().back().pressure - 0.5f) < 1e-4f);
}

void testCentripetalSplineDoesNotLoop() {
    std::printf("a fast corner with uneven sample gaps does not overshoot into a loop\n");
    // Long, short, long, with the short gap at a hairpin: the uniform spline's
    // tangent at the short segment is half the long chord, which flings it far
    // past the corner. The centripetal one stays close.
    Brush brush;
    brush.size = 2.0f;
    brush.spacing = 0.05f;
    StrokePath path(brush);
    path.addSample(sampleAt(0.0f, 0.0f, 0.00));
    path.addSample(sampleAt(200.0f, 0.0f, 0.01));
    path.addSample(sampleAt(201.0f, 3.0f, 0.02));
    path.addSample(sampleAt(0.0f, 6.0f, 0.03));
    path.finish();

    float maxX = 0.0f;
    for (const Dab& d : path.dabs()) maxX = std::max(maxX, d.x);
    std::printf("    furthest point past the corner: x = %.1f (samples reach 201)\n", maxX);
    CHECK(maxX < 206.0f);
}

void testSubPixelDabsReachTheTilesTheyAreDrawnIn() {
    std::printf("a sub-pixel dab notes every tile its minimum drawn size reaches\n");
    Brush brush;
    brush.size = 0.2f;
    brush.minimumSizeFraction = 1.0f;
    StrokePath path(brush);
    path.addSample(sampleAt(static_cast<float>(kTileSize) - 0.5f, 10.0f, 0.0));
    path.finish();
    CHECK(path.dabs().size() == 1);
    CHECK(path.dabs()[0].radius < kMinimumDrawnRadius);
    // Drawn at radius 1 with a pixel of antialiasing, it reaches the next tile.
    CHECK(path.touchedTiles().count(TileCoord{1, 0}) == 1);
    CHECK(path.touchedTiles().count(TileCoord{0, 0}) == 1);
}

void testRevisedDabsAreReported() {
    std::printf("the end taper reports the dabs it revised\n");
    Brush plain;
    plain.spacing = 0.1f;
    StrokePath a(plain);
    for (int i = 0; i < 30; ++i) a.addSample(sampleAt(10.0f * i, 0.0f, i / 240.0));
    a.finish();
    CHECK(a.firstRevisedDab() == a.dabs().size());

    Brush tapered = plain;
    tapered.taper.pressure.end.length = 60.0f;
    tapered.taper.pressure.end.scale = 0.0f;
    StrokePath b(tapered);
    for (int i = 0; i < 30; ++i) b.addSample(sampleAt(10.0f * i, 0.0f, i / 240.0));
    const size_t beforeFinish = b.dabs().size();
    b.finish();
    CHECK(b.firstRevisedDab() < beforeFinish);
    CHECK(b.firstRevisedDab() > 0);
    // Everything before it is untouched; the last dab is the tip.
    CHECK(b.dabs().back().radius < b.dabs()[b.firstRevisedDab() - 1].radius);
}

void testInkPenGoesToAHairline() {
    std::printf("the default pen reaches a hairline at light pressure, at any size\n");
    // Procreate's Studio Pen: Apple Pencil -> Pressure -> Size 100%, minimum
    // size 0% (read 2026-11-08). Until then ours stopped at 25% of the size.
    Brush pen = inkPen();
    pen.size = 40.0f;
    pen.smoothing = 0.0f;
    StrokePath path(pen);
    for (int i = 0; i < 40; ++i) {
        path.addSample(sampleAt(10.0f * i, 0.0f, i / 240.0, 0.02f));
    }
    path.finish();
    float widest = 0.0f;
    for (const Dab& d : path.dabs()) widest = std::max(widest, d.radius);
    std::printf("    40 px pen at 2%% pressure: widest dab radius %.3f px\n", widest);
    CHECK(widest * 2.0f < 1.0f);
}

/// A 40 px default pen through a run of Pencil samples at 240 Hz, moving
/// 3 px a sample, with the given pressures and then `rest` at the last one.
StrokePath penStroke(const std::vector<float>& pressures, int rest, bool pencil = true) {
    Brush pen = inkPen();
    pen.size = 40.0f;
    pen.smoothing = 0.0f;
    StrokePath path(pen);
    int i = 0;
    auto add = [&](float p) {
        StrokeSample s = sampleAt(3.0f * static_cast<float>(i), 0.0f, i / 240.0, p);
        s.fromPressureDevice = pencil;
        path.addSample(s);
        ++i;
    };
    for (float p : pressures) add(p);
    for (int k = 0; k < rest; ++k) add(pressures.back());
    path.finish();
    return path;
}

void testATouchDownSpikeLeavesNoBlob() {
    std::printf("a touch-down force spike that falls away does not leave a big first dab\n");
    // Reasoned shape of the spike: hard for a few samples, then the light
    // touch the artist meant (octolex's screenshot, 2026-11-09).
    const StrokePath spike = penStroke({0.9f, 0.6f, 0.25f, 0.03f}, 40);
    const float first = spike.dabs().front().radius;
    std::printf("    first dab radius %.2f px (it was the size of a 0.9 pressure dab)\n", first);
    CHECK(first * 2.0f < 1.0f);
    for (size_t i = 0; i < 12 && i < spike.dabs().size(); ++i) {
        CHECK(spike.dabs()[i].radius * 2.0f < 1.0f);
    }
}

void testARampUpIsUntouched() {
    std::printf("a stroke that starts light and presses harder keeps its shape\n");
    const StrokePath ramp = penStroke({0.03f, 0.1f, 0.3f, 0.6f, 0.9f}, 40);
    CHECK(ramp.dabs().front().radius * 2.0f < 1.0f);
    CHECK(ramp.dabs().back().radius > 8.0f);   // full pressure still reaches full width
}

void testTheStartIsHeldOnlyBriefly() {
    std::printf("the start is held for the settle window, then released\n");
    Brush pen = inkPen();
    pen.smoothing = 0.0f;
    StrokePath path(pen);
    for (int i = 0; i < 4; ++i) {   // 12.5 ms in
        path.addSample(sampleAt(3.0f * i, 0.0f, i / 240.0, 0.5f));
    }
    CHECK(path.dabs().empty());
    for (int i = 4; i < 10; ++i) {  // past 25 ms
        path.addSample(sampleAt(3.0f * i, 0.0f, i / 240.0, 0.5f));
    }
    CHECK(!path.dabs().empty());

    // A finger has no force to settle and is never held.
    StrokePath finger(pen);
    for (int i = 0; i < 4; ++i) {
        StrokeSample s = sampleAt(3.0f * i, 0.0f, i / 240.0, 0.5f);
        s.fromPressureDevice = false;
        finger.addSample(s);
    }
    CHECK(!finger.dabs().empty());

    // A quick dot inside the window still puts ink down.
    StrokePath dot(pen);
    dot.addSample(sampleAt(0.0f, 0.0f, 0.0, 0.9f));
    dot.addSample(sampleAt(1.0f, 0.0f, 0.004, 0.4f));
    dot.finish();
    CHECK(!dot.dabs().empty());
}

void testAPenRestingWhereItLandedStillSettles() {
    std::printf("force reported before the pen moves still settles the start\n");
    Brush pen = inkPen();
    pen.size = 40.0f;
    pen.smoothing = 0.0f;
    StrokePath path(pen);
    path.addSample(sampleAt(0.0f, 0.0f, 0.0, 0.9f));
    path.addSample(sampleAt(0.0f, 0.0f, 1 / 240.0, 0.4f));   // same spot, lighter
    path.addSample(sampleAt(0.0f, 0.0f, 2 / 240.0, 0.03f));
    for (int i = 3; i < 40; ++i) path.addSample(sampleAt(3.0f * i, 0.0f, i / 240.0, 0.03f));
    path.finish();
    CHECK(path.dabs().front().radius * 2.0f < 1.0f);
}

}  // namespace

int main() {
    testIdentityWhenEverythingIsOff();
    testStreamLineKeepsItsPencilMeaning();
    testStreamLineIsRateIndependent();
    testMotionFilteringParameters();
    testMotionFilteringRemovesWobble();
    testStabilizationAverages();
    testGlobalSettingsAreAFloor();
    testPressureCurveAndSmoothing();
    testInputSettingsOnlyBeforeTheFirstSample();
    testCentripetalSplineDoesNotLoop();
    testSubPixelDabsReachTheTilesTheyAreDrawnIn();
    testRevisedDabsAreReported();
    testInkPenGoesToAHairline();
    testATouchDownSpikeLeavesNoBlob();
    testARampUpIsUntouched();
    testTheStartIsHeldOnlyBriefly();
    testAPenRestingWhereItLandedStillSettles();
    return check::report("test_input");
}
