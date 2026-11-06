#pragma once

//
//  stroke_sample.h — one input sample, shared by the stroke path and the
//  input filter that runs ahead of it.
//

#include <cstdint>

namespace mc {

/// One input sample, in canvas pixels.
///
/// Every channel the hardware can report is carried, whether or not the
/// current brush consumes it. Widening this later would mean touching every
/// stage at once, and a few unused floats per sample cost nothing next to the
/// dabs they produce.
struct StrokeSample {
    float x = 0.0f;
    float y = 0.0f;

    /// 0...1. Devices without pressure report a constant, not zero.
    float pressure = 1.0f;

    /// Altitude from the screen plane in radians. π/2 is upright, 0 is flat.
    float tilt = 1.5707963f;

    /// Direction the barrel points, in radians.
    float azimuth = 0.0f;

    /// Barrel roll in radians, or negative when the hardware cannot report it.
    /// A brush keyed to roll needs to tell "flat" from "not available".
    float roll = -1.0f;

    /// Seconds. Only differences matter, so any monotonic clock will do.
    double timestamp = 0.0;

    /// True when a pressure-capable device drew this — a Pencil rather than a
    /// finger. It selects which of the brush's two tapers applies.
    ///
    /// Carried per sample rather than per stroke because that is where every
    /// other device fact already lives, and because the shell reads it from
    /// the same UITouch it reads pressure and tilt from. In practice it is
    /// constant across a stroke: one stroke is one touch.
    ///
    /// It cannot be inferred. A finger reports a synthesised pressure and an
    /// upright tilt, and so does a Pencil held perpendicular.
    bool fromPressureDevice = true;
};

}  // namespace mc
