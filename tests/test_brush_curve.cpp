//
//  test_brush_curve.cpp — the response curve.
//
//  The curve replaced an exponent on 2026-09-09 because Procreate's pressure
//  response is a graph, and a graph can be flat-then-steep-then-flat where an
//  exponent cannot. That makes it the first structural taxonomy gap closed, and
//  the shape of the data is what these tests defend rather than any one value.
//
//  The property that matters most is the one an exponent gave for free and a
//  curve does not: **the output can never leave 0...1.** A response drives a
//  dab radius, so an overshoot is not a cosmetic wobble, it is a brush that
//  draws at a size the UI never showed. Piecewise linear was chosen over a
//  smooth spline for exactly that reason, and the choice is only worth anything
//  if it is asserted.
//

#include "check.h"

#include "core/brush.h"

#include <cmath>
#include <algorithm>
#include <cstdio>
#include <initializer_list>

using namespace mc;

namespace {

/// No interior points is the default, and must be exactly the identity — not
/// approximately. Every brush that has never opened a curve editor rides this
/// path, so a rounding error here is an error in every brush at once.
void testAnEmptyCurveIsExactlyLinear() {
    ResponseCurve c;
    CHECK_EQ(static_cast<long long>(c.count), 0LL);
    for (int i = 0; i <= 20; ++i) {
        const float t = static_cast<float>(i) / 20.0f;
        CHECK(std::fabs(c.evaluate(t) - t) < 1e-6f);
    }
}

/// The endpoints are fixed, not stored. A curve that did not pass through
/// (0,0) and (1,1) would make `minimum` and `maximum` mean something other
/// than what the panel says they mean.
void testTheCurveAlwaysRunsCornerToCorner() {
    ResponseCurve c = ResponseCurve::exponent(2.2f);
    CHECK(std::fabs(c.evaluate(0.0f) - 0.0f) < 1e-6f);
    CHECK(std::fabs(c.evaluate(1.0f) - 1.0f) < 1e-6f);
}

/// The safety property. Points are clamped and interpolation is linear, so no
/// input can produce an output outside the range the editor drew.
void testOutputNeverLeavesTheUnitRange() {
    ResponseCurve c;
    c.count = 3;
    // Deliberately abusive: out of range, and not ascending.
    c.x[0] = 0.8f;  c.y[0] = 5.0f;
    c.x[1] = 0.2f;  c.y[1] = -3.0f;
    c.x[2] = 0.9f;  c.y[2] = 0.5f;

    for (int i = -5; i <= 25; ++i) {
        const float t = static_cast<float>(i) / 20.0f;
        const float v = c.evaluate(t);
        CHECK(v >= 0.0f);
        CHECK(v <= 1.0f);
    }
}

/// A point that does not advance in x is skipped rather than dividing by zero.
/// This is a finger mid-drag in the editor, not a corrupt file, so it has to
/// draw something rather than refuse.
void testDuplicateXDoesNotDivideByZero() {
    ResponseCurve c;
    c.count = 2;
    c.x[0] = 0.5f; c.y[0] = 0.2f;
    c.x[1] = 0.5f; c.y[1] = 0.9f;
    for (int i = 0; i <= 20; ++i) {
        const float v = c.evaluate(static_cast<float>(i) / 20.0f);
        CHECK(v == v);            // not NaN
        CHECK(v >= 0.0f && v <= 1.0f);
    }
}

/// The migration is only trustworthy if it can be checked against what it
/// replaced. Six evenly spaced samples of t^1.4 should track the exponent
/// closely enough that the pen feels the same.
void testTheExponentHelperTracksThePowerItReplaces() {
    for (float e : {0.6f, 1.4f, 2.2f}) {
        const ResponseCurve c = ResponseCurve::exponent(e);
        float worst = 0.0f;
        for (int i = 0; i <= 50; ++i) {
            const float t = static_cast<float>(i) / 50.0f;
            worst = std::max(worst, std::fabs(c.evaluate(t) - std::pow(t, e)));
        }
        std::printf("  exponent %.1f: worst error %.4f\n",
                    static_cast<double>(e), static_cast<double>(worst));
        // Chords under a smooth curve: the error is the sagitta, and at six
        // points it is small enough that no one could feel it in a pen.
        CHECK(worst < 0.02f);
    }
}

/// The shape an exponent cannot reach, and the reason for the change: flat,
/// then steep, then flat. Asserted as a shape rather than as values — the
/// middle must climb several times faster than either end.
void testAnSCurveIsExpressible() {
    ResponseCurve c;
    c.count = 2;
    c.x[0] = 0.35f; c.y[0] = 0.08f;
    c.x[1] = 0.65f; c.y[1] = 0.92f;

    const float lowSlope    = (c.evaluate(0.30f) - c.evaluate(0.10f)) / 0.20f;
    const float middleSlope = (c.evaluate(0.60f) - c.evaluate(0.40f)) / 0.20f;
    const float highSlope   = (c.evaluate(0.90f) - c.evaluate(0.70f)) / 0.20f;
    std::printf("  s-curve slopes: %.2f / %.2f / %.2f\n",
                static_cast<double>(lowSlope), static_cast<double>(middleSlope),
                static_cast<double>(highSlope));
    CHECK(middleSlope > lowSlope * 3.0f);
    CHECK(middleSlope > highSlope * 3.0f);
}

/// A disabled response still costs nothing and still returns the identity,
/// which is what lets a brush add a response without disturbing the others.
void testADisabledResponseIsStillNeutral() {
    Response r;
    r.minimum = 0.1f;
    r.maximum = 0.9f;
    r.curve = ResponseCurve::exponent(2.0f);
    r.enabled = false;
    CHECK(r.evaluate(0.5f) == 1.0f);
}

/// And an enabled one maps the curve through minimum...maximum.
void testAnEnabledResponseSpansItsRange() {
    Response r;
    r.minimum = 0.25f;
    r.maximum = 1.0f;
    r.enabled = true;
    CHECK(std::fabs(r.evaluate(0.0f) - 0.25f) < 1e-6f);
    CHECK(std::fabs(r.evaluate(1.0f) - 1.0f) < 1e-6f);
}

}  // namespace

int main() {
    testAnEmptyCurveIsExactlyLinear();
    testTheCurveAlwaysRunsCornerToCorner();
    testOutputNeverLeavesTheUnitRange();
    testDuplicateXDoesNotDivideByZero();
    testTheExponentHelperTracksThePowerItReplaces();
    testAnSCurveIsExpressible();
    testADisabledResponseIsStillNeutral();
    testAnEnabledResponseSpansItsRange();
    return check::report("brush_curve");
}
