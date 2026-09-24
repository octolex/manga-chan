#include "core/stroke.h"

#include <algorithm>
#include <cmath>

namespace mc {
namespace {

constexpr float kHalfPi = 1.5707963267948966f;

/// Substeps per spline segment. The walk only needs to be fine enough that a
/// straight-line hop between substeps is indistinguishable from the curve; dab
/// spacing is resolved by interpolation *within* a substep, so this number
/// controls curve fidelity rather than dab density.
constexpr int kSubsteps = 24;

/// Below this, a dab is smaller than the antialiased edge that would draw it.
constexpr float kMinimumRadius = 0.05f;

/// Dabs never land closer than half a pixel apart, however small the brush or
/// tight the spacing. Named because the flow compensation divides by it: a
/// floor that clamps the step also raises the effective spacing fraction, and
/// the two calculations have to agree on which number won.
constexpr float kMinimumSpacing = 0.5f;

float clamp01(float v) noexcept {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

float lerp(float a, float b, float t) noexcept {
    return a + (b - a) * t;
}

float catmullRom(float p0, float p1, float p2, float p3, float t) noexcept {
    const float t2 = t * t;
    const float t3 = t2 * t;
    return 0.5f * ((2.0f * p1)
                 + (-p0 + p2) * t
                 + (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t2
                 + (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t3);
}

/// Tilt as an artist means it: 0 upright, 1 flat to the glass.
float tiltInput(float altitudeRadians) noexcept {
    return clamp01(1.0f - altitudeRadians / kHalfPi);
}

}  // namespace

StrokePath::StrokePath(const Brush& brush, uint64_t seed)
    : brush_(brush), rng_(seed) {}

float StrokePath::nextRandom() noexcept {
    // splitmix64. Deterministic from the seed, which is what lets a stroke be
    // undone and redone to exactly the same pixels — jitter that differed
    // between runs would make undo lossy.
    rng_ += 0x9E3779B97F4A7C15ULL;
    uint64_t z = rng_;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    z = z ^ (z >> 31);
    return static_cast<float>((z >> 40) & 0xFFFFFF) / 16777216.0f;
}

void StrokePath::addSample(const StrokeSample& sample) {
    if (finished_) return;

    // Latched from the first sample; see the field's note for why not the last.
    if (nodes_.empty()) {
        fromPressureDevice_ = sample.fromPressureDevice;
    }

    Node node;
    node.pressure = clamp01(sample.pressure);
    node.tilt = sample.tilt;

    if (nodes_.empty()) {
        node.x = sample.x;
        node.y = sample.y;
        node.velocity = 0.0f;
    } else {
        const Node& previous = nodes_.back();
        // Pull the sample toward where the path already is. Applied before the
        // spline rather than after, so smoothing changes the curve itself
        // rather than merely resampling a jittery one.
        const float k = clamp01(brush_.smoothing);
        node.x = lerp(sample.x, previous.x, k);
        node.y = lerp(sample.y, previous.y, k);

        const float dx = node.x - previous.x;
        const float dy = node.y - previous.y;
        const float distance = std::sqrt(dx * dx + dy * dy);

        // A duplicate position yields a zero-length tangent, which propagates
        // NaN through the entire spline rather than failing locally.
        if (distance < 1e-4f) return;

        const double dt = sample.timestamp - lastTimestamp_;
        node.velocity = dt > 1e-6 ? static_cast<float>(distance / dt) : previous.velocity;
    }

    lastTimestamp_ = sample.timestamp;
    nodes_.push_back(node);
    emitReadySegments(false);
}

void StrokePath::emitReadySegments(bool flushing) {
    // A Catmull-Rom segment from node k to k+1 needs k+2 as its outgoing
    // tangent, so it can only be emitted once a further sample has landed
    // behind it. On finish that sample will never come, and the last segment
    // falls back to duplicating its own endpoint.
    const size_t limit = flushing
        ? (nodes_.empty() ? 0 : nodes_.size() - 1)
        : (nodes_.size() < 2 ? 0 : nodes_.size() - 2);

    while (nextSegment_ < limit) {
        emitSegment(nextSegment_);
        ++nextSegment_;
    }
}

void StrokePath::emitSegment(size_t index) {
    const size_t last = nodes_.size() - 1;
    const Node& p0 = nodes_[index == 0 ? 0 : index - 1];
    const Node& p1 = nodes_[index];
    const Node& p2 = nodes_[index + 1];
    const Node& p3 = nodes_[std::min(last, index + 2)];

    if (!cursor_.valid) {
        cursor_.x = p1.x;
        cursor_.y = p1.y;
        cursor_.pressure = p1.pressure;
        cursor_.tilt = p1.tilt;
        cursor_.velocity = p1.velocity;
        cursor_.valid = true;
        // The first dab lands on the first sample, so a tap leaves a mark
        // rather than nothing at all.
        if (dabs_.empty()) {
            placeDab(cursor_, 0.0f, 0.0f);
        }
    }

    for (int step = 1; step <= kSubsteps; ++step) {
        const float t = static_cast<float>(step) / static_cast<float>(kSubsteps);

        Walker target;
        target.x = catmullRom(p0.x, p1.x, p2.x, p3.x, t);
        target.y = catmullRom(p0.y, p1.y, p2.y, p3.y, t);
        // Attributes interpolate linearly. Splining them too would overshoot
        // past full pressure on a sharp change and then clamp, which reads as
        // a flat spot in the width exactly where the stroke is most expressive.
        target.pressure = lerp(p1.pressure, p2.pressure, t);
        target.tilt = lerp(p1.tilt, p2.tilt, t);
        target.velocity = lerp(p1.velocity, p2.velocity, t);
        target.valid = true;

        const float dx = target.x - cursor_.x;
        const float dy = target.y - cursor_.y;
        const float span = std::sqrt(dx * dx + dy * dy);
        if (span < 1e-6f) continue;

        const float dirX = dx / span;
        const float dirY = dy / span;

        // Walk along this substep, dropping dabs wherever the running arc
        // length crosses the spacing threshold. Interpolating within the
        // substep matters: a fast stroke can make one substep several dabs
        // long, and placing them all at the substep end would leave a gap
        // followed by a clump.
        float covered = 0.0f;
        while (carried_ + (span - covered) >= nextSpacing_) {
            const float need = nextSpacing_ - carried_;
            covered += need;

            const float f = covered / span;
            Walker at;
            at.x = lerp(cursor_.x, target.x, f);
            at.y = lerp(cursor_.y, target.y, f);
            at.pressure = lerp(cursor_.pressure, target.pressure, f);
            at.tilt = lerp(cursor_.tilt, target.tilt, f);
            at.velocity = lerp(cursor_.velocity, target.velocity, f);
            at.valid = true;

            travelled_ += need;
            carried_ = 0.0f;
            placeDab(at, dirX, dirY);
        }

        carried_ += span - covered;
        travelled_ += span - covered;
        cursor_ = target;
    }
}

void StrokePath::placeDab(const Walker& at, float dirX, float dirY) {
    const float pressure = clamp01(at.pressure);
    const float tilt = tiltInput(at.tilt);
    const float velocity = brush_.velocityReference > 0.0f
        ? clamp01(at.velocity / brush_.velocityReference)
        : 0.0f;

    float diameter = brush_.size * brush_.sizeDynamics.evaluate(pressure, tilt, velocity);

    // A floor rather than a clamp to zero: a sample at no pressure should
    // taper the line, not punch a hole in it.
    const float floorDiameter = brush_.size * clamp01(brush_.minimumSizeFraction);
    diameter = std::max(diameter, floorDiameter);

    // Start taper. The end taper cannot be applied here because it depends on
    // where the stroke stops, which is not yet known — see applyEndTaper().
    const TaperEnd& startTaper = activeTaper().start;
    if (startTaper.length > 0.0f && travelled_ < startTaper.length) {
        const float t = travelled_ / startTaper.length;
        diameter *= lerp(clamp01(startTaper.scale), 1.0f, t);
    }

    if (brush_.sizeJitter > 0.0f) {
        // Jitter only ever removes size, so `size` stays the honest upper
        // bound the UI shows and the tile bounds stay conservative.
        diameter *= 1.0f - clamp01(brush_.sizeJitter) * nextRandom();
    }

    float flow = clamp01(brush_.flow * brush_.flowDynamics.evaluate(pressure, tilt, velocity));
    if (brush_.flowJitter > 0.0f) {
        flow *= 1.0f - clamp01(brush_.flowJitter) * nextRandom();
    }

    // Base orientation. Jitter is applied per *stamp* below rather than here,
    // so that several stamps at one position do not all share one draw and
    // land as a single thicker mark.
    float angle = brush_.angle;
    if (brush_.angleFollowsDirection && (dirX != 0.0f || dirY != 0.0f)) {
        angle += std::atan2(dirY, dirX);
    }

    Dab dab;
    dab.x = at.x;
    dab.y = at.y;
    dab.radius = std::max(kMinimumRadius, diameter * 0.5f);
    dab.angle = angle;

    // Flow is what ONE DAB deposits, and the dabs accumulate freely from there.
    //
    // This was briefly the opposite, and the reasoning that changed it was
    // sound but aimed at the wrong control. The symptom was real — Flow 50%
    // draws a solid line, because seventeen dabs cover every pixel at the
    // default spacing and 1 - 0.5^17 is 0.99999 — and the conclusion drawn from
    // it was that Flow should be inverted so a stroke finished at the value
    // asked for. That made the slider literal at the cost of matching nothing:
    //
    //   * Photoshop's Flow is a per-dab alpha, uncompensated.
    //   * Procreate's is too. Measured 2026-09-08: four strokes at one Opacity
    //     over an 8x range of Spacing came out at 0.03, 0.06, 0.08 and 0.09 ink.
    //     Compensation requires those to be equal. They are not.
    //
    // What was actually missing was noticing that `opacity` already does the
    // job. It multiplies the finished stroke once, at composite, so it caps
    // what a stroke can reach however much it overlaps itself — a per-stroke
    // ceiling, which is exactly Photoshop's Opacity and exactly what Procreate
    // calls a Glaze rendering style. Flow and Opacity stopped being redundant
    // when density got its own channel; the mistake was still treating Flow as
    // the strength control after that.
    //
    // The consequence is worth stating rather than fixing: Flow's useful range
    // is bunched at the bottom, because anything above roughly 20% saturates in
    // one pass. That is true of Photoshop too, and it is why Procreate keeps
    // Opacity on the main screen and Flow buried in Brush Studio. If the slider
    // proves hard to use, the answer is a curve on the slider, not a change to
    // what the number means.
    //
    // Opacity joins it here in a Blending style, and stays off the dab in a
    // Glaze. That one branch is the whole rendering-style difference, and it
    // lives in the engine rather than the shell for the usual reason: which
    // family a brush is in changes what a dab deposits, and a dab is something
    // CI can count.
    //
    // Blending was wrong here until 2026-09-09. Opacity was applied only at
    // composite, for every brush, which is a Glaze — so the always-visible
    // Opacity slider capped a stroke instead of building it, and scrubbing a
    // patch at 25% could never reach solid. Procreate's stock brushes are
    // Blending, so that is what an artist means by the word, and the device
    // said so before this file did.
    //
    // The Blending amount is not the slider itself but the slider to the power
    // 2.6 — measured on the Studio Pen on 2026-09-24, and the fix for bug 21.
    dab.flow = brush_.renderingStyle == RenderingStyle::Blending
                 ? flow * blendingDabOpacity(brush_.opacity)
                 : flow;
    dab.roundness = clamp01(brush_.roundness);
    dab.hardness = clamp01(brush_.hardness);

    // Arc length *at this dab*, recorded before scatter moves it: rolling
    // grain should scroll with progress along the stroke, and scatter is a
    // lateral shake of where the dab lands rather than travel along the path.
    dab.grainOffset = travelled_;

    // Shape Count: how many stamps of the shape land at this one position.
    //
    // Only meaningful together with scatter or angle jitter. With neither, the
    // stamps land exactly on top of one another, which the geometry channel
    // ignores (a maximum of equal values) while the density channel darkens —
    // a legitimate way to thicken ink, but not what Count is for. Count is how
    // a spray, a stipple or a foliage brush is built.
    //
    // Stamps are separate dabs rather than a flag on one, so nothing
    // downstream needs to know this feature exists: the GPU stamps them, the
    // tile capture notes each one where it actually lands, and undo replays
    // them like any other.
    int32_t stamps = brush_.shapeCount < 1 ? 1 : brush_.shapeCount;
    if (stamps > 1 && brush_.shapeCountJitter > 0.0f) {
        // Jitter only ever removes stamps, so `shapeCount` stays the honest
        // upper bound the panel shows — the same rule size jitter follows.
        const float keep = 1.0f - clamp01(brush_.shapeCountJitter) * nextRandom();
        const int32_t jittered = static_cast<int32_t>(
            std::lround(static_cast<float>(stamps) * keep));
        stamps = jittered < 1 ? 1 : jittered;
    }

    for (int32_t s = 0; s < stamps; ++s) {
        Dab stamp = dab;

        if (brush_.angleJitter > 0.0f) {
            stamp.angle += (nextRandom() * 2.0f - 1.0f) * brush_.angleJitter;
        }
        if (brush_.scatter > 0.0f) {
            const float theta = nextRandom() * 6.2831853f;
            const float reach = nextRandom() * brush_.scatter * diameter;
            stamp.x += std::cos(theta) * reach;
            stamp.y += std::sin(theta) * reach;
        }

        dabs_.push_back(stamp);
        // After scatter, so the tiles follow where the stamp actually landed
        // rather than where the dab position was.
        noteTiles(stamp);
    }

    // Spacing is a fraction of *this* dab's diameter, so the stroke keeps its
    // character as pressure changes the width. Recomputed after placement
    // rather than before, because the diameter is only known once dynamics and
    // jitter have run.
    //
    // The half-pixel floor is not a detail. Procreate has one too: at 5% and 2%
    // spacing its strokes came out almost equally dark, where the dab counts
    // say the second should have been far darker. Correct for a floor and its
    // per-dab alpha is constant across the whole range, which is what showed
    // the engine is uncompensated rather than partially compensated.
    nextSpacing_ = std::max(kMinimumSpacing, brush_.spacing * dab.radius * 2.0f);
}

void StrokePath::noteTiles(const Dab& dab) {
    // One pixel of slack for the antialiased edge. The radius is taken at its
    // widest, so an elliptical dab is fully covered whatever its angle.
    const float reach = dab.radius + 1.0f;
    const int32_t minX = static_cast<int32_t>(std::floor(dab.x - reach));
    const int32_t maxX = static_cast<int32_t>(std::floor(dab.x + reach));
    const int32_t minY = static_cast<int32_t>(std::floor(dab.y - reach));
    const int32_t maxY = static_cast<int32_t>(std::floor(dab.y + reach));

    for (int32_t ty = tileIndexForPixel(minY); ty <= tileIndexForPixel(maxY); ++ty) {
        for (int32_t tx = tileIndexForPixel(minX); tx <= tileIndexForPixel(maxX); ++tx) {
            touched_.insert(TileCoord{tx, ty});
        }
    }
}

const Taper& StrokePath::activeTaper() const {
    // A finger reports no real pressure, so a brush whose character comes from
    // pressure makes nothing recognisable from one. Which taper applies is
    // therefore a property of the input, not of the brush alone.
    return fromPressureDevice_ ? brush_.taper.pressure : brush_.taper.touch;
}

void StrokePath::applyEndTaper() {
    const TaperEnd& endTaper = activeTaper().end;
    if (endTaper.length <= 0.0f || dabs_.size() < 2) return;

    // Walk backwards from the final dab, scaling by how close each one is to
    // the end. Tiles were noted at the untapered radius, which is a superset
    // of what the tapered dabs cover, so the capture stays correct.
    float distance = 0.0f;
    for (size_t i = dabs_.size(); i-- > 0;) {
        if (i + 1 < dabs_.size()) {
            const float dx = dabs_[i + 1].x - dabs_[i].x;
            const float dy = dabs_[i + 1].y - dabs_[i].y;
            distance += std::sqrt(dx * dx + dy * dy);
        }
        if (distance >= endTaper.length) break;

        const float t = distance / endTaper.length;
        dabs_[i].radius = std::max(
            kMinimumRadius,
            dabs_[i].radius * lerp(clamp01(endTaper.scale), 1.0f, t));
    }
}

void StrokePath::finish() {
    if (finished_) return;
    emitReadySegments(true);

    // A segment needs two samples, but a tap is one - and it still has to put
    // ink down, because dotting an i is a tap.
    if (dabs_.empty() && nodes_.size() == 1) {
        Walker at;
        at.x = nodes_[0].x;
        at.y = nodes_[0].y;
        at.pressure = nodes_[0].pressure;
        at.tilt = nodes_[0].tilt;
        at.valid = true;
        placeDab(at, 0.0f, 0.0f);
    }

    applyEndTaper();
    finished_ = true;
}

size_t StrokePath::consumeNewDabs() noexcept {
    const size_t first = consumed_;
    consumed_ = dabs_.size();
    return first;
}

}  // namespace mc
