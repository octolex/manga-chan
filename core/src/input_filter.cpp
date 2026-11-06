#include "core/input_filter.h"

#include <algorithm>
#include <cmath>

namespace mc {

namespace {

constexpr double kTwoPi = 6.283185307179586;

float clamp01(float v) noexcept {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

/// Smoothing factor of a first-order low-pass at `cutoff` Hz over `dt`
/// seconds: the weight the *new* value gets.
float lowPassAlpha(double cutoff, double dt) noexcept {
    const double tau = 1.0 / (kTwoPi * cutoff);
    return static_cast<float>(1.0 / (1.0 + tau / dt));
}

/// An exponential moving average expressed per reference sample, converted
/// to the weight the *old* value keeps after `dt` seconds.
float retainedOver(float perReferenceSample, double dt) noexcept {
    if (perReferenceSample <= 0.0f) return 0.0f;
    const double steps = dt * InputFilter::kReferenceRate;
    return static_cast<float>(std::pow(static_cast<double>(perReferenceSample), steps));
}

}  // namespace

OneEuroParameters motionFilteringParameters(float amount, float expression) noexcept {
    const float a = clamp01(amount);
    const float e = clamp01(expression);
    // Amount lowers the resting cutoff from 10 Hz, which barely touches a
    // hand, to 0.4 Hz, which irons out anything slower than a deliberate
    // sweep. Squared so the first half of the slider stays gentle.
    const float inverse = 1.0f - a;
    const float minCutoff = 0.4f + 9.6f * inverse * inverse;
    // Expression raises the speed coefficient, so faster movement opens the
    // filter more and keeps more of the gesture. Procreate says the higher
    // Motion filtering is set, the less Expression can do, and the
    // (1 - 0.85a) factor is that sentence written down.
    const float beta = 0.0005f + 0.02f * e * (1.0f - 0.85f * a);
    return OneEuroParameters{minCutoff, beta};
}

InputFilter::InputFilter(const Brush& brush, const InputSettings& settings)
    : streamLine_(clamp01(brush.smoothing)),
      stabilization_(std::max(clamp01(brush.stabilization), clamp01(settings.stabilization))),
      motionFiltering_(std::max(clamp01(brush.motionFiltering),
                                clamp01(settings.motionFiltering))),
      // Expression goes with whichever Motion filtering won, so a brush's
      // expression is not silently replaced by the global one.
      expression_(clamp01(brush.motionFiltering) >= clamp01(settings.motionFiltering)
                      ? clamp01(brush.motionFilteringExpression)
                      : clamp01(settings.motionFilteringExpression)),
      pressureSmoothing_(clamp01(settings.pressureSmoothing)),
      pressureCurve_(settings.pressureCurve) {
    identity_ = streamLine_ <= 0.0f && stabilization_ <= 0.0f && motionFiltering_ <= 0.0f &&
                pressureSmoothing_ <= 0.0f && pressureCurve_.count == 0;
}

StrokeSample InputFilter::filter(const StrokeSample& raw) {
    if (identity_) return raw;

    StrokeSample out = raw;

    // Pressure first. The curve belongs to the person; it is applied to what
    // the Pencil reports, before any brush reads pressure. Not to a finger:
    // its pressure is a constant the shell makes up, and bending a constant
    // would only move every finger stroke's width when the curve is edited.
    float pressure = raw.fromPressureDevice ? pressureCurve_.evaluate(clamp01(raw.pressure))
                                            : clamp01(raw.pressure);

    double dt = started_ ? raw.timestamp - lastT_ : 0.0;
    // Coalesced samples can share a timestamp, and a clock can step. Neither
    // is a reason to stall the filters or divide by zero: treat it as one
    // reference sample, which is what it almost certainly was.
    if (!(dt > 1e-6)) dt = 1.0 / kReferenceRate;

    if (!started_) {
        started_ = true;
        lastT_ = raw.timestamp;
        pressure_ = pressure;
        oeX_ = raw.x;
        oeY_ = raw.y;
        oeDX_ = oeDY_ = 0.0f;
        slX_ = raw.x;
        slY_ = raw.y;
        window_.push_back(Point{raw.timestamp, raw.x, raw.y});
        windowSumX_ = raw.x;
        windowSumY_ = raw.y;
        out.pressure = pressure;
        return out;
    }
    lastT_ = raw.timestamp;

    if (pressureSmoothing_ > 0.0f) {
        // At 100% the pressure takes about a tenth of a second to follow the
        // hand: enough to remove a force tremor, not enough to blunt a taper
        // drawn on purpose.
        const double tau = 0.1 * pressureSmoothing_;
        const float keep = static_cast<float>(std::exp(-dt / tau));
        pressure_ = pressure_ * keep + pressure * (1.0f - keep);
        pressure = pressure_;
    }
    out.pressure = pressure;

    float x = raw.x;
    float y = raw.y;

    if (motionFiltering_ > 0.0f) {
        const OneEuroParameters p = motionFilteringParameters(motionFiltering_, expression_);
        const float rawDX = static_cast<float>((x - oeX_) / dt);
        const float rawDY = static_cast<float>((y - oeY_) / dt);
        const float d = lowPassAlpha(1.0, dt);   // 1 Hz on the derivative, as the paper uses
        oeDX_ += d * (rawDX - oeDX_);
        oeDY_ += d * (rawDY - oeDY_);
        const float speed = std::sqrt(oeDX_ * oeDX_ + oeDY_ * oeDY_);
        const float a = lowPassAlpha(p.minCutoff + p.beta * speed, dt);
        oeX_ += a * (x - oeX_);
        oeY_ += a * (y - oeY_);
        x = oeX_;
        y = oeY_;
    }

    if (stabilization_ > 0.0f) {
        window_.push_back(Point{raw.timestamp, x, y});
        windowSumX_ += x;
        windowSumY_ += y;
        const double span = kStabilizationWindow * stabilization_;
        while (window_.size() > 1 && raw.timestamp - window_.front().t > span) {
            windowSumX_ -= window_.front().x;
            windowSumY_ -= window_.front().y;
            window_.pop_front();
        }
        const double n = static_cast<double>(window_.size());
        x = static_cast<float>(windowSumX_ / n);
        y = static_cast<float>(windowSumY_ / n);
    }

    if (streamLine_ > 0.0f) {
        const float keep = retainedOver(streamLine_, dt);
        slX_ = slX_ * keep + x * (1.0f - keep);
        slY_ = slY_ * keep + y * (1.0f - keep);
        x = slX_;
        y = slY_;
    }

    out.x = x;
    out.y = y;
    return out;
}

}  // namespace mc
