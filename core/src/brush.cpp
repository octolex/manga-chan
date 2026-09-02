#include "core/brush.h"

#include <algorithm>
#include <cmath>

namespace mc {
namespace {

float clamp01(float v) noexcept {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

}  // namespace

float Response::evaluate(float input) const {
    // Disabled responses return the multiplicative identity rather than being
    // skipped by the caller, so that adding a response never changes the
    // arithmetic of the ones already there.
    if (!enabled) return 1.0f;

    float t = clamp01(input);
    if (curve != 1.0f) {
        t = std::pow(t, curve);
    }
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
    // most of the control lives rather than the very top.
    b.sizeDynamics.byPressure.curve = 1.4f;

    b.smoothing = 0.35f;
    b.minimumSizeFraction = 0.08f;
    return b;
}

}  // namespace mc
