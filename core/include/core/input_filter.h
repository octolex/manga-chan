#pragma once

//
//  input_filter.h — what happens to a sample between the digitiser and the
//  spline.
//
//  Procreate has **three** separate stabilisers, each one a brush setting and
//  each one also available app-wide under Preferences → Pressure and
//  Smoothing. They are three because they remove three different things:
//
//    · **StreamLine** pulls each sample toward where the line already is. It
//      trades lag for steadiness at every speed alike, and it is what an
//      inking pen is set up with.
//    · **Stabilization** averages the recent path, squashing wobbles toward
//      a central line.
//    · **Motion filtering** removes the extremities of wobble without
//      squashing the stroke, and **Expression** puts back some of the
//      character it took out.
//
//  These are Procreate's *descriptions*, from its handbook. The arithmetic
//  below is ours and is not measured against Procreate yet — it is the
//  established technique for each description:
//
//    · StreamLine is an exponential moving average, as it always was here,
//      but now in **time** rather than per sample. It used to pull by a fixed
//      fraction per sample, so the same setting smoothed about four times as
//      hard with a 240 Hz Pencil as with a 60 Hz finger.
//    · Stabilization is a trailing moving average over a time window.
//    · Motion filtering is the **1€ filter** (Casiez, Roussel and Vogel,
//      CHI 2012): a low-pass whose cutoff rises with speed, so slow movement
//      is smoothed hard and fast movement passes with little lag. That is
//      exactly "remove the wobble, keep the gesture", and Expression maps
//      onto its speed coefficient.
//
//  Pressure goes through the global pressure curve and an optional pressure
//  smoothing before any brush sees it, as in Procreate, where the pressure
//  curve is a property of the person rather than of the brush.
//

#include "core/brush.h"
#include "core/stroke_sample.h"

#include <deque>

namespace mc {

/// App-wide input settings — Procreate's Preferences → Pressure and
/// Smoothing. Applied to every stroke, whatever the brush.
struct InputSettings {
    /// The person's pressure curve, applied to raw Pencil pressure before any
    /// brush dynamic reads it. Linear by default.
    ResponseCurve pressureCurve;

    /// 0...1. Smooths pressure over time, so a hand that trembles in force as
    /// well as position does not bead the line.
    float pressureSmoothing = 0.0f;

    /// 0...1 each. Combined with the brush's own values by taking the larger,
    /// so the global setting is a floor every brush gets. **That combination
    /// rule is our guess, not a measurement** — Procreate does not document how
    /// the two levels interact.
    float stabilization = 0.0f;
    float motionFiltering = 0.0f;
    float motionFilteringExpression = 0.0f;
};

/// Runs one stroke's samples through the stabilisers, in a fixed order:
/// pressure curve and pressure smoothing, then Motion filtering, then
/// Stabilization, then StreamLine.
///
/// The order is deliberate. Motion filtering wants the rawest signal it can
/// get, because its cutoff is driven by the speed it measures, and a signal
/// already averaged reads as slower than the hand really is. StreamLine goes
/// last because it is the one an artist tunes by feel, and it should act on
/// the line they see rather than be undone by something downstream.
class InputFilter {
public:
    InputFilter(const Brush& brush, const InputSettings& settings);

    /// The filtered sample. Timestamps pass through unchanged.
    StrokeSample filter(const StrokeSample& raw);

    /// True when every stabiliser is off and the curve is linear, in which
    /// case `filter` returns its input bit for bit. Shapes that QuickShape
    /// generates are already exact, and must go through untouched.
    bool isIdentity() const noexcept { return identity_; }

    /// The reference rate StreamLine's amount was tuned at: the Pencil's.
    /// A setting means exactly what it used to mean for a Pencil, and the
    /// same thing in time for any other device.
    static constexpr double kReferenceRate = 240.0;

    /// Seconds of history Stabilization averages at 100%.
    static constexpr double kStabilizationWindow = 0.25;

private:
    struct Point {
        double t;
        float x;
        float y;
    };

    float streamLine_;
    float stabilization_;
    float motionFiltering_;
    float expression_;
    float pressureSmoothing_;
    ResponseCurve pressureCurve_;
    bool identity_ = true;

    bool started_ = false;
    double lastT_ = 0.0;

    // Pressure smoothing state.
    float pressure_ = 0.0f;

    // 1€ filter state.
    float oeX_ = 0.0f, oeY_ = 0.0f;
    float oeDX_ = 0.0f, oeDY_ = 0.0f;

    // Stabilization window.
    std::deque<Point> window_;
    double windowSumX_ = 0.0, windowSumY_ = 0.0;

    // StreamLine state.
    float slX_ = 0.0f, slY_ = 0.0f;
};

/// The 1€ filter's two parameters, as Motion filtering's Amount and
/// Expression map onto them. Exposed so the mapping is tested rather than
/// buried: `minCutoff` in Hz, `beta` in Hz per (pixel per second).
struct OneEuroParameters {
    float minCutoff;
    float beta;
};
OneEuroParameters motionFilteringParameters(float amount, float expression) noexcept;

}  // namespace mc
