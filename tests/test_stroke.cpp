#include "check.h"

#include "core/brush.h"
#include "core/stroke.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <vector>

using namespace mc;

namespace {

/// Feeds a straight horizontal line as `count` evenly spaced samples.
///
/// The sample count is the variable that matters most in this file: the whole
/// point of resampling is that the result should depend on the *path*, not on
/// how densely the hardware happened to report it.
StrokePath straightLine(const Brush& brush, float fromX, float toX, int count,
                        float pressure = 1.0f, double duration = 1.0) {
    StrokePath path(brush);
    for (int i = 0; i < count; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(count - 1);
        StrokeSample s;
        s.x = fromX + (toX - fromX) * t;
        s.y = 100.0f;
        s.pressure = pressure;
        s.timestamp = duration * t;
        path.addSample(s);
    }
    path.finish();
    return path;
}

float dabGap(const std::vector<Dab>& dabs, size_t i) {
    const float dx = dabs[i + 1].x - dabs[i].x;
    const float dy = dabs[i + 1].y - dabs[i].y;
    return std::sqrt(dx * dx + dy * dy);
}

void testSpacingIsAFractionOfDiameter() {
    std::printf("dab spacing follows the dab diameter\n");

    Brush brush;
    brush.size = 20.0f;
    brush.spacing = 0.25f;   // expect a dab every 5 px
    brush.smoothing = 0.0f;

    StrokePath path = straightLine(brush, 100.0f, 600.0f, 40);
    const auto& dabs = path.dabs();

    CHECK(dabs.size() > 90);
    CHECK(dabs.size() < 110);

    // Every gap should be the spacing, not merely the average of them. An
    // average would hide the failure mode that actually matters: a run of
    // clumped dabs followed by a visible gap.
    for (size_t i = 0; i + 1 < dabs.size(); ++i) {
        CHECK(std::fabs(dabGap(dabs, i) - 5.0f) < 0.6f);
    }
}

void testHalvingTheSizeHalvesTheSpacing() {
    std::printf("a smaller brush lays down proportionally tighter dabs\n");

    Brush brush;
    brush.spacing = 0.25f;
    brush.smoothing = 0.0f;

    brush.size = 20.0f;
    const size_t coarse = straightLine(brush, 0.0f, 500.0f, 20).dabs().size();
    brush.size = 10.0f;
    const size_t fine = straightLine(brush, 0.0f, 500.0f, 20).dabs().size();

    // Spacing expressed in pixels rather than in diameters is the classic
    // mistake here: it turns a smooth small brush into a dotted line when the
    // artist scales it up.
    CHECK(fine > coarse * 3 / 2);
}

void testDabsDoNotDependOnSampleDensity() {
    std::printf("the same path resamples the same however densely it is sampled\n");

    Brush brush;
    brush.size = 16.0f;
    brush.spacing = 0.1f;
    brush.smoothing = 0.0f;

    // This is the faceting bug from M0, now a CI test rather than something
    // only visible by eye on the device: a fast stroke reports few samples, and
    // stamping per sample is exactly what makes curves look like polygons.
    const auto sparse = straightLine(brush, 0.0f, 400.0f, 4).dabs();
    const auto dense = straightLine(brush, 0.0f, 400.0f, 60).dabs();

    CHECK(sparse.size() > 200);
    const long long difference =
        static_cast<long long>(sparse.size()) - static_cast<long long>(dense.size());
    CHECK(std::llabs(difference) <= 4);

    // And they should trace the same line, not merely produce the same count.
    const size_t shared = std::min(sparse.size(), dense.size());
    for (size_t i = 0; i < shared; ++i) {
        CHECK(std::fabs(sparse[i].x - dense[i].x) < 1.0f);
        CHECK(std::fabs(sparse[i].y - dense[i].y) < 1.0f);
    }
}

void testCurvesStaySmooth() {
    std::printf("a sparsely sampled arc produces no faceting\n");

    Brush brush;
    brush.size = 12.0f;
    brush.spacing = 0.1f;
    brush.smoothing = 0.0f;

    // A quarter circle described by only nine samples — roughly what a fast
    // flick delivers.
    StrokePath path(brush);
    for (int i = 0; i < 9; ++i) {
        const float a = static_cast<float>(i) / 8.0f * 1.5707963f;
        StrokeSample s;
        s.x = 300.0f + std::cos(a) * 200.0f;
        s.y = 300.0f + std::sin(a) * 200.0f;
        s.timestamp = i * 0.016;
        path.addSample(s);
    }
    path.finish();

    const auto& dabs = path.dabs();
    CHECK(dabs.size() > 100);

    // Faceting shows up as the turn angle between consecutive dabs spiking at
    // the original sample positions and sitting near zero between them. On a
    // true arc every turn is the same small angle.
    float worst = 0.0f;
    for (size_t i = 1; i + 1 < dabs.size(); ++i) {
        const float ax = dabs[i].x - dabs[i - 1].x;
        const float ay = dabs[i].y - dabs[i - 1].y;
        const float bx = dabs[i + 1].x - dabs[i].x;
        const float by = dabs[i + 1].y - dabs[i].y;
        const float turn = std::fabs(std::atan2(ay, ax) - std::atan2(by, bx));
        worst = std::max(worst, turn);
    }
    // A 200 px radius arc walked in ~1.2 px steps turns about 0.006 rad per
    // step. Anything approaching the 0.2 rad kink of a 9-segment polygon is
    // the bug this test exists to catch.
    CHECK(worst < 0.05f);

    // Every dab should sit on the circle, not chord across it.
    for (const Dab& d : dabs) {
        const float dx = d.x - 300.0f;
        const float dy = d.y - 300.0f;
        CHECK(std::fabs(std::sqrt(dx * dx + dy * dy) - 200.0f) < 2.0f);
    }
}

void testPressureDrivesWidth() {
    std::printf("pressure drives dab radius through the response curve\n");

    Brush brush = inkPen();
    brush.smoothing = 0.0f;

    const auto light = straightLine(brush, 0.0f, 300.0f, 20, 0.05f).dabs();
    const auto heavy = straightLine(brush, 0.0f, 300.0f, 20, 1.0f).dabs();

    CHECK(!light.empty());
    CHECK(!heavy.empty());
    CHECK(light.front().radius < heavy.front().radius * 0.5f);

    // A light touch must still leave a mark. Tapering to nothing would break
    // the stroke into disconnected pieces wherever pressure dipped.
    CHECK(light.front().radius > 0.0f);
}

void testMinimumSizeFractionIsAFloor() {
    std::printf("zero pressure tapers rather than vanishing\n");

    Brush brush;
    brush.size = 20.0f;
    brush.minimumSizeFraction = 0.1f;
    brush.sizeDynamics.byPressure.enabled = true;
    brush.sizeDynamics.byPressure.minimum = 0.0f;
    brush.sizeDynamics.byPressure.maximum = 1.0f;
    brush.smoothing = 0.0f;

    const auto dabs = straightLine(brush, 0.0f, 200.0f, 20, 0.0f).dabs();
    CHECK(!dabs.empty());
    for (const Dab& d : dabs) {
        CHECK(std::fabs(d.radius - 1.0f) < 0.01f);   // 20 * 0.1 / 2
    }
}

void testTouchedTilesAreExactNotBounding() {
    std::printf("tile capture follows the stroke, not its bounding box\n");

    Brush brush;
    brush.size = 8.0f;
    brush.spacing = 0.1f;
    brush.smoothing = 0.0f;

    // A diagonal across four tiles of canvas. The bounding box is 16 tiles;
    // the stroke only touches the diagonal run of them.
    StrokePath path(brush);
    for (int i = 0; i <= 20; ++i) {
        const float t = static_cast<float>(i) / 20.0f;
        StrokeSample s;
        s.x = t * 1000.0f;
        s.y = t * 1000.0f;
        s.timestamp = i * 0.01;
        path.addSample(s);
    }
    path.finish();

    const auto& tiles = path.touchedTiles();
    CHECK(!tiles.empty());
    CHECK(tiles.size() < 16);

    // Every dab must fall inside a captured tile, or its ink would be painted
    // and then never read back.
    for (const Dab& d : path.dabs()) {
        const TileCoord c = tileForPixel(static_cast<int32_t>(d.x),
                                         static_cast<int32_t>(d.y));
        CHECK(tiles.count(c) == 1);
    }
}

void testNegativeCoordinatesUseFloorDivision() {
    std::printf("a stroke left of the origin captures negative tiles\n");

    Brush brush;
    brush.size = 6.0f;
    brush.smoothing = 0.0f;

    StrokePath path(brush);
    for (int i = 0; i <= 10; ++i) {
        StrokeSample s;
        s.x = -500.0f + i * 20.0f;
        s.y = -300.0f;
        s.timestamp = i * 0.01;
        path.addSample(s);
    }
    path.finish();

    bool sawNegative = false;
    for (const TileCoord& c : path.touchedTiles()) {
        if (c.x < 0 && c.y < 0) sawNegative = true;
    }
    // Truncating division would fold everything left of the origin onto tile 0
    // and silently overwrite the wrong pixels.
    CHECK(sawNegative);
}

void testSmoothingPullsThePathIn() {
    std::printf("smoothing shortens a jagged path\n");

    auto zigzag = [](float smoothing) {
        Brush brush;
        brush.size = 10.0f;
        brush.smoothing = smoothing;

        StrokePath path(brush);
        for (int i = 0; i <= 40; ++i) {
            StrokeSample s;
            s.x = i * 10.0f;
            s.y = (i % 2 == 0) ? 100.0f : 140.0f;
            s.timestamp = i * 0.01;
            path.addSample(s);
        }
        path.finish();
        return path.length();
    };

    // Smoothing trades latency for steadiness, so the measurable effect is
    // that the walked path gets shorter: the wobble is being cut off.
    CHECK(zigzag(0.7f) < zigzag(0.0f) * 0.9f);
}

void testTaperThinsBothEnds() {
    std::printf("taper thins the start and the end\n");

    Brush brush;
    brush.size = 20.0f;
    brush.spacing = 0.2f;
    brush.smoothing = 0.0f;
    brush.taperLength = 60.0f;
    brush.taperStartScale = 0.0f;
    brush.taperEndScale = 0.0f;

    const auto dabs = straightLine(brush, 0.0f, 600.0f, 30).dabs();
    CHECK(dabs.size() > 20);

    const float middle = dabs[dabs.size() / 2].radius;
    CHECK(dabs.front().radius < middle * 0.5f);
    CHECK(dabs.back().radius < middle * 0.5f);
    CHECK(std::fabs(middle - 10.0f) < 0.01f);
}

void testGrainOffsetTracksArcLength() {
    std::printf("each dab records how far along the stroke it sits\n");

    Brush brush;
    brush.size = 20.0f;
    brush.spacing = 0.25f;   // a dab every 5 px
    brush.smoothing = 0.0f;

    StrokePath path = straightLine(brush, 100.0f, 600.0f, 40);
    const auto& dabs = path.dabs();
    CHECK(dabs.size() > 90);

    // Rolling grain scrolls the texture by this number, so it has to be arc
    // length and not dab index — otherwise the grain would advance at a rate
    // that changed with brush size, and a pencil would scroll its own texture
    // faster simply for being thinner.
    CHECK(dabs.front().grainOffset == 0.0f);
    for (size_t i = 0; i + 1 < dabs.size(); ++i) {
        CHECK(dabs[i + 1].grainOffset > dabs[i].grainOffset);
        CHECK(std::fabs((dabs[i + 1].grainOffset - dabs[i].grainOffset) - 5.0f) < 0.6f);
    }

    // The last dab's offset is the distance walked to reach it, so it sits just
    // short of the stroke's total length rather than at it.
    CHECK(dabs.back().grainOffset <= path.length() + 0.001f);
    CHECK(dabs.back().grainOffset > path.length() - 6.0f);
}

void testScatterDoesNotDisturbTheGrainOffset() {
    std::printf("scatter shakes where a dab lands, not how far along it is\n");

    Brush brush;
    brush.size = 20.0f;
    brush.spacing = 0.25f;
    brush.smoothing = 0.0f;

    StrokePath plain = straightLine(brush, 100.0f, 400.0f, 20);

    brush.scatter = 0.8f;
    StrokePath scattered = straightLine(brush, 100.0f, 400.0f, 20);

    // Scatter is a lateral shake of the landing point; it is not travel along
    // the path. If it fed back into the offset, a scattered brush would scroll
    // its rolling grain at a different rate than the same brush without
    // scatter, which is not something either control claims to do.
    CHECK_EQ(static_cast<long long>(plain.dabs().size()),
             static_cast<long long>(scattered.dabs().size()));
    for (size_t i = 0; i < plain.dabs().size(); ++i) {
        CHECK(plain.dabs()[i].grainOffset == scattered.dabs()[i].grainOffset);
    }
}

void testJitterIsDeterministic() {
    std::printf("the same seed lays down the same jittered stroke\n");

    Brush brush;
    brush.size = 18.0f;
    brush.spacing = 0.2f;
    brush.sizeJitter = 0.6f;
    brush.scatter = 0.4f;
    brush.angleJitter = 1.0f;
    brush.smoothing = 0.0f;

    auto run = [&brush]() {
        StrokePath path(brush, 12345);
        for (int i = 0; i <= 20; ++i) {
            StrokeSample s;
            s.x = i * 20.0f;
            s.y = 50.0f;
            s.timestamp = i * 0.01;
            path.addSample(s);
        }
        path.finish();
        return path.dabs();
    };

    const auto a = run();
    const auto b = run();
    CHECK_EQ(static_cast<long long>(a.size()), static_cast<long long>(b.size()));
    // Undo re-runs a stroke. If jitter drifted between runs, undo would not
    // restore the pixels it removed.
    for (size_t i = 0; i < a.size(); ++i) {
        CHECK(a[i].x == b[i].x);
        CHECK(a[i].y == b[i].y);
        CHECK(a[i].radius == b[i].radius);
        CHECK(a[i].angle == b[i].angle);
    }

    // And it must actually be varying something.
    bool varies = false;
    for (size_t i = 1; i < a.size(); ++i) {
        if (a[i].radius != a[0].radius) varies = true;
    }
    CHECK(varies);
}

void testAngleFollowsDirection() {
    std::printf("a directional dab rotates through a corner\n");

    Brush brush;
    brush.size = 14.0f;
    brush.spacing = 0.2f;
    brush.roundness = 0.2f;
    brush.angleFollowsDirection = true;
    brush.smoothing = 0.0f;

    StrokePath path(brush);
    for (int i = 0; i <= 10; ++i) {
        StrokeSample s;
        s.x = i * 30.0f;
        s.y = 100.0f;
        s.timestamp = i * 0.01;
        path.addSample(s);
    }
    for (int i = 1; i <= 10; ++i) {
        StrokeSample s;
        s.x = 300.0f;
        s.y = 100.0f + i * 30.0f;
        s.timestamp = 0.1 + i * 0.01;
        path.addSample(s);
    }
    path.finish();

    const auto& dabs = path.dabs();
    CHECK(dabs.size() > 40);
    // Horizontal at the start, vertical at the end. A flat nib that did not
    // rotate would draw the same width through both, which is the whole
    // reason the setting exists.
    CHECK(std::fabs(dabs.front().angle) < 0.2f);
    CHECK(std::fabs(dabs.back().angle - 1.5707963f) < 0.3f);
}

void testATapStillLeavesAMark() {
    std::printf("a single sample still puts ink down\n");

    Brush brush = inkPen();
    StrokePath path(brush);
    StrokeSample s;
    s.x = 42.0f;
    s.y = 99.0f;
    path.addSample(s);
    path.finish();

    // A segment needs two samples, but a tap is one - and dotting an i has to
    // work. The lone sample becomes a single dab at finish.
    CHECK_EQ(path.dabs().size(), 1);
    CHECK(path.dabs().front().x == 42.0f);
    CHECK(path.dabs().front().radius > 0.0f);
    CHECK(!path.touchedTiles().empty());
}

void testVelocityDynamicsThinAFastStroke() {
    std::printf("velocity response thins a fast stroke\n");

    Brush brush;
    brush.size = 20.0f;
    brush.spacing = 0.2f;
    brush.smoothing = 0.0f;
    brush.velocityReference = 1000.0f;
    brush.sizeDynamics.byVelocity.enabled = true;
    brush.sizeDynamics.byVelocity.minimum = 1.0f;
    brush.sizeDynamics.byVelocity.maximum = 0.25f;

    // Same path, one traversed ten times faster.
    const auto slow = straightLine(brush, 0.0f, 500.0f, 30, 1.0f, 5.0).dabs();
    const auto fast = straightLine(brush, 0.0f, 500.0f, 30, 1.0f, 0.5).dabs();

    CHECK(!slow.empty());
    CHECK(!fast.empty());
    CHECK(fast.back().radius < slow.back().radius * 0.6f);
}

void testIncrementalEmissionMatchesOneShot() {
    std::printf("dabs are emitted once and never revised\n");

    Brush brush = inkPen();
    brush.taperLength = 0.0f;

    StrokePath path(brush);
    std::vector<Dab> snapshot;
    for (int i = 0; i <= 30; ++i) {
        StrokeSample s;
        s.x = i * 15.0f;
        s.y = 200.0f + std::sin(i * 0.3f) * 40.0f;
        s.timestamp = i * 0.016;
        path.addSample(s);

        // Whatever was already emitted must still be there, unchanged. The
        // renderer uploads dabs incrementally, so a revised dab would be one
        // the GPU never sees corrected.
        const auto& dabs = path.dabs();
        for (size_t k = 0; k < snapshot.size(); ++k) {
            CHECK(dabs[k].x == snapshot[k].x);
            CHECK(dabs[k].radius == snapshot[k].radius);
        }
        snapshot.assign(dabs.begin(), dabs.end());
    }
    path.finish();
}

void testConsumeReportsOnlyNewDabs() {
    std::printf("consumeNewDabs walks forward without repeating\n");

    Brush brush = inkPen();
    StrokePath path(brush);

    CHECK_EQ(static_cast<long long>(path.consumeNewDabs()), 0);

    for (int i = 0; i <= 10; ++i) {
        StrokeSample s;
        s.x = i * 25.0f;
        s.y = 60.0f;
        s.timestamp = i * 0.016;
        path.addSample(s);
    }

    const size_t first = path.consumeNewDabs();
    const size_t total = path.dabs().size();
    CHECK(total > first);
    // A second call with nothing added must report an empty range rather than
    // re-uploading the whole stroke every frame.
    CHECK_EQ(static_cast<long long>(path.consumeNewDabs()),
                static_cast<long long>(total));
}


/// What a stroke is worth where it overlaps itself, at a point the brush has
/// walked straight over. Alpha-over, exactly as the coverage target blends it.
float accumulatedFlowAt(const std::vector<Dab>& dabs, float px, float py) {
    float acc = 0.0f;
    for (const Dab& d : dabs) {
        const float dx = d.x - px;
        const float dy = d.y - py;
        if (std::sqrt(dx * dx + dy * dy) > d.radius) { continue; }
        acc += d.flow * (1.0f - acc);
    }
    return acc;
}

/// Flow says what the finished stroke is worth, not what one dab deposits.
///
/// This is the rule the device round broke: at 6% spacing about seventeen dabs
/// cover every pixel, so an uncompensated per-dab alpha of 0.5 accumulated to
/// 0.99999 and the stroke came out solid. Only around 10% was visibly
/// translucent, which made the slider a switch with a very short throw.
void testFlowIsWhatTheStrokeIsWorth() {
    for (float wanted : {0.1f, 0.25f, 0.5f, 0.75f}) {
        Brush brush = inkPen();
        brush.flow = wanted;
        brush.hardness = 1.0f;
        const StrokePath path = straightLine(brush, 20.0f, 300.0f, 32);
        const float got = accumulatedFlowAt(path.dabs(), 160.0f, 100.0f);
        std::printf("  flow %.2f requested, stroke worth %.3f\n",
                    static_cast<double>(wanted), static_cast<double>(got));
        CHECK(std::fabs(got - wanted) < 0.06f);
    }
}

/// And says it independently of Spacing.
///
/// The uncompensated version made the same brush twice as dark at half the
/// spacing, so every spacing change silently rewrote every flow on the brush.
/// That coupling is the part that could not be left in: it makes two settings
/// that look independent secretly multiply.
void testFlowDoesNotMoveWithSpacing() {
    float darkest = 0.0f;
    float lightest = 1.0f;
    for (float spacing : {0.03f, 0.06f, 0.12f, 0.25f}) {
        Brush brush = inkPen();
        brush.flow = 0.5f;
        brush.hardness = 1.0f;
        brush.spacing = spacing;
        const StrokePath path = straightLine(brush, 20.0f, 300.0f, 32);
        const float got = accumulatedFlowAt(path.dabs(), 160.0f, 100.0f);
        std::printf("  spacing %.2f -> stroke worth %.3f\n",
                    static_cast<double>(spacing), static_cast<double>(got));
        darkest = std::max(darkest, got);
        lightest = std::min(lightest, got);
    }
    // Spread across a 8x range of spacings, not merely "each one is near 0.5":
    // a compensation that drifted with spacing could still pass the per-case
    // check while making the brush visibly different at the two ends.
    std::printf("  spread across spacings: %.3f\n",
                static_cast<double>(darkest - lightest));
    CHECK(darkest - lightest < 0.08f);
}

/// Flow 100% is untouched. The default inking brush must not have moved.
void testFullFlowStillSaturatesInOnePass() {
    Brush brush = inkPen();
    brush.flow = 1.0f;
    const StrokePath path = straightLine(brush, 20.0f, 300.0f, 32);
    for (const Dab& d : path.dabs()) {
        CHECK(d.flow > 0.999f);
    }
}

/// Crossing the stroke over itself still darkens.
///
/// This is the behaviour the device round explicitly asked us to keep — at 10%
/// flow the intersection reading darker than either line is the thing that
/// showed flow was doing anything at all. Compensation must not flatten it into
/// a stroke that cannot build.
void testCrossingTheStrokeStillDarkens() {
    Brush brush = inkPen();
    brush.flow = 0.4f;
    brush.hardness = 1.0f;
    const StrokePath path = straightLine(brush, 20.0f, 300.0f, 32);
    const float once = accumulatedFlowAt(path.dabs(), 160.0f, 100.0f);

    // A second pass over ground already at `once`, as a crossing stroke is.
    const float twice = once + accumulatedFlowAt(path.dabs(), 160.0f, 100.0f) * (1.0f - once);
    std::printf("  one pass %.3f, crossed %.3f\n",
                static_cast<double>(once), static_cast<double>(twice));
    CHECK(twice > once + 0.15f);
    CHECK(twice < 1.0f);
}

}  // namespace

int main() {
    testSpacingIsAFractionOfDiameter();
    testHalvingTheSizeHalvesTheSpacing();
    testDabsDoNotDependOnSampleDensity();
    testCurvesStaySmooth();
    testPressureDrivesWidth();
    testMinimumSizeFractionIsAFloor();
    testTouchedTilesAreExactNotBounding();
    testNegativeCoordinatesUseFloorDivision();
    testSmoothingPullsThePathIn();
    testTaperThinsBothEnds();
    testGrainOffsetTracksArcLength();
    testScatterDoesNotDisturbTheGrainOffset();
    testJitterIsDeterministic();
    testAngleFollowsDirection();
    testATapStillLeavesAMark();
    testVelocityDynamicsThinAFastStroke();
    testIncrementalEmissionMatchesOneShot();
    testConsumeReportsOnlyNewDabs();
    testFlowIsWhatTheStrokeIsWorth();
    testFlowDoesNotMoveWithSpacing();
    testFullFlowStillSaturatesInOnePass();
    testCrossingTheStrokeStillDarkens();
    return check::report("stroke");
}
