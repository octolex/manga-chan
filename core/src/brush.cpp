#include "core/brush.h"

#include <algorithm>
#include <cmath>

namespace mc {
namespace {

float clamp01(float v) noexcept {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

/// Piecewise-linear value over an ascending knot list that includes both
/// endpoints. Only used while fitting a curve, never per dab.
float interpolateKnots(const float* xs, const float* ys, int32_t count, float t) {
    for (int32_t i = 1; i < count; ++i) {
        if (t <= xs[i]) {
            const float span = xs[i] - xs[i - 1];
            if (span <= 0.0f) return ys[i];
            return ys[i - 1] + (ys[i] - ys[i - 1]) * ((t - xs[i - 1]) / span);
        }
    }
    return ys[count - 1];
}

}  // namespace

float ResponseCurve::evaluate(float t) const {
    t = clamp01(t);
    if (count <= 0) return t;

    // Walk the points, carrying the previous one. The curve starts at (0,0)
    // and ends at (1,1), so those are the bounds of the walk rather than
    // entries in the array.
    //
    // A point that does not advance in x is skipped rather than treated as an
    // error. Two points at the same x is a vertical step, which is either a
    // finger mid-drag in the editor or a file from an older build; neither is
    // worth refusing to draw over, and skipping keeps the function total.
    float previousX = 0.0f;
    float previousY = 0.0f;
    const int32_t n = count < kMaxPoints ? count : kMaxPoints;

    for (int32_t i = 0; i < n; ++i) {
        const float px = clamp01(x[i]);
        const float py = clamp01(y[i]);
        if (px <= previousX) continue;

        if (t <= px) {
            const float span = px - previousX;
            return previousY + (py - previousY) * ((t - previousX) / span);
        }
        previousX = px;
        previousY = py;
    }

    // Past the last usable point, run to (1,1).
    const float span = 1.0f - previousX;
    if (span <= 0.0f) return previousY;
    return previousY + (1.0f - previousY) * ((t - previousX) / span);
}

ResponseCurve ResponseCurve::exponent(float e) {
    ResponseCurve c;
    if (e == 1.0f) return c;  // linear needs no points at all

    // Greedy refinement: repeatedly put the next point wherever the current
    // approximation is furthest from the real curve.
    //
    // Two cheaper heuristics were tried and measured first, and both are wrong
    // in opposite directions. Evenly spaced in x fits t^2.2 to 0.007 and t^0.6
    // only to 0.058, because t^0.6 is near-vertical at the origin and every
    // sample misses it. Evenly spaced in y fixes that one to 0.022 and breaks
    // the other to 0.040, because for t^2.2 it places nothing below x = 0.42
    // and leaves the whole flat region to a single chord.
    //
    // There is no spacing rule that is right for both, because "where the
    // curve needs points" is a property of the curve. So measure it. This runs
    // once when a brush is built, never per dab.
    //
    // Worst error over exponents 0.6, 1.4 and 2.2:
    //
    //     even in x   0.058    even in y   0.040    greedy   0.016
    //
    // Greedy is not uniformly better — even-x beats it at 2.2, 0.007 against
    // 0.016 — it is better in the *worst* case, which is the only one a
    // guarantee can be written about. Roughly a fifth of a level out of 255,
    // and a brush stores a curve once.
    float knotX[kMaxPoints + 2];
    float knotY[kMaxPoints + 2];
    knotX[0] = 0.0f; knotY[0] = 0.0f;
    knotX[1] = 1.0f; knotY[1] = 1.0f;
    int32_t knots = 2;

    while (knots < kMaxPoints + 2) {
        float worstError = 0.0f;
        float worstT = -1.0f;
        // 199 interior probes: fine enough to find the peak of a smooth error
        // curve, coarse enough to stay trivial.
        for (int32_t i = 1; i < 200; ++i) {
            const float t = static_cast<float>(i) / 200.0f;
            const float error = std::fabs(std::pow(t, e) - interpolateKnots(knotX, knotY, knots, t));
            if (error > worstError) {
                worstError = error;
                worstT = t;
            }
        }
        // Already closer than anyone could feel in a pen; spending the
        // remaining points would only add noise to the stored curve.
        if (worstT < 0.0f || worstError < 1e-4f) break;

        int32_t at = knots;
        while (at > 0 && knotX[at - 1] > worstT) {
            knotX[at] = knotX[at - 1];
            knotY[at] = knotY[at - 1];
            --at;
        }
        knotX[at] = worstT;
        knotY[at] = std::pow(worstT, e);
        ++knots;
    }

    // The endpoints are implicit in a ResponseCurve, so only the interior
    // knots are stored.
    c.count = knots - 2;
    for (int32_t i = 0; i < c.count; ++i) {
        c.x[i] = knotX[i + 1];
        c.y[i] = knotY[i + 1];
    }
    return c;
}

float Response::evaluate(float input) const {
    // Disabled responses return the multiplicative identity rather than being
    // skipped by the caller, so that adding a response never changes the
    // arithmetic of the ones already there.
    if (!enabled) return 1.0f;

    const float t = curve.evaluate(clamp01(input));
    return minimum + (maximum - minimum) * t;
}

float Modulation::evaluate(float pressure, float tilt, float velocity) const {
    return byPressure.evaluate(pressure)
         * byTilt.evaluate(tilt)
         * byVelocity.evaluate(velocity);
}

Brush inkPen() {
    Brush b;
    b.size = 14.0f;
    // Tight enough that consecutive dabs overlap heavily and the stroke reads
    // as a continuous line rather than a chain of discs.
    b.spacing = 0.06f;
    b.hardness = 0.95f;
    b.flow = 1.0f;
    b.opacity = 1.0f;
    // Blending, like Procreate's stock brushes. At full opacity the two
    // families are indistinguishable — 1.0 on the dab and 1.0 at composite
    // are the same nothing — so this default costs the ink pen nothing and
    // only shows once the artist reaches for the Opacity slider, which is
    // exactly when it has to be right.
    b.renderingStyle = RenderingStyle::Blending;

    // Full flow, so one pass saturates at once and the line cannot darken
    // where it crosses itself. That is what makes this an inking pen rather
    // than a pencil, and it is a value now rather than a mode.
    //
    // Pressure drives width and nothing else. Flow staying flat is what makes
    // the line read as ink rather than as a wash: a light pass is *thinner*,
    // not greyer.
    b.sizeDynamics.byPressure.enabled = true;
    b.sizeDynamics.byPressure.minimum = 0.25f;
    b.sizeDynamics.byPressure.maximum = 1.0f;
    // Slightly above linear, so the middle of the pressure range is where
    // most of the control lives rather than the very top. Expressed as the
    // sampled exponent it used to be, so the pen feels identical across the
    // change from an exponent to a curve.
    b.sizeDynamics.byPressure.curve = ResponseCurve::exponent(1.4f);

    b.smoothing = 0.35f;
    b.minimumSizeFraction = 0.08f;
    return b;
}

}  // namespace mc
