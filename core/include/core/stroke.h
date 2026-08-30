#pragma once

//
//  stroke.h — input samples in, dabs out.
//
//  This is the stage that used to live in Swift. It moved here for one
//  reason: every bug that has reached the device so far lived in the shell,
//  where the test suite cannot see it. Stroke geometry is pure arithmetic over
//  plain numbers, so there is no excuse for it to sit anywhere untestable.
//
//  Three stages, in order:
//
//    1. Smoothing. Each raw sample is pulled toward the running average.
//       Trades latency for steadiness; a brush setting, not an input setting.
//
//    2. Catmull-Rom through the smoothed samples, walked at fixed arc length.
//       Raw samples are far too sparse to stamp directly — a fast stroke can
//       leave 30+ pixels between consecutive samples, and stamping per sample
//       is exactly what produces visible faceting on curves.
//
//    3. Dab emission at `spacing × diameter` intervals along that arc length,
//       with dynamics and jitter applied per dab.
//
//  Emission is incremental and append-only: each raw sample is processed
//  exactly once, so a long stroke costs the same per sample as a short one.
//  Rebuilding the whole path per event would be O(n²) and would stutter
//  precisely when the artist is drawing fastest.
//
//  The one thing that is *not* incremental is the end taper, which cannot be
//  known until the stroke ends. It is applied to the tail in `finish()`.
//

#include "core/brush.h"
#include "core/tile.h"

#include <cstdint>
#include <unordered_set>
#include <vector>

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
};

/// One stamp of the brush shape. This is the entire contract with the GPU:
/// whatever the brush model grows into, the renderer only ever sees these.
struct Dab {
    float x = 0.0f;
    float y = 0.0f;

    /// Radius in canvas pixels, after dynamics, jitter and taper.
    float radius = 0.0f;

    /// Rotation in radians.
    float angle = 0.0f;

    /// Per-dab alpha, before the stroke-level opacity.
    float flow = 1.0f;

    /// 1 is circular, below that flattens along `angle`.
    float roundness = 1.0f;

    /// Edge falloff, carried per dab so a future dynamic can drive it.
    float hardness = 1.0f;
};

/// Turns a growing list of samples into a growing list of dabs.
class StrokePath {
public:
    /// `seed` makes jitter reproducible. A brush that jitters differently on
    /// every run cannot be tested, and cannot be undone and redone to the same
    /// pixels either — which matters more, because undo must be exact.
    explicit StrokePath(const Brush& brush, uint64_t seed = 0x9E3779B97F4A7C15ULL);

    /// Samples must arrive in time order. Duplicates of the previous position
    /// are dropped: a zero-length tangent would NaN its way through the whole
    /// spline.
    void addSample(const StrokeSample& sample);

    /// Flushes the segments still waiting on a lookahead sample that will
    /// never arrive, then applies the end taper.
    void finish();

    /// Every dab emitted so far, oldest first.
    const std::vector<Dab>& dabs() const noexcept { return dabs_; }

    /// Dabs appended since the last call, for incremental upload. Returns the
    /// range [first, dabs().size()).
    size_t consumeNewDabs() noexcept;

    /// Exactly the tiles the emitted dabs cover — not their bounding box.
    ///
    /// The distinction is expensive: a diagonal stroke's bounding box is most
    /// of the canvas, so capturing by rectangle would read back, and push into
    /// undo history, several times the tiles the stroke actually changed.
    const std::unordered_set<TileCoord, TileCoordHash>& touchedTiles() const noexcept {
        return touched_;
    }

    /// Total arc length walked, in canvas pixels.
    float length() const noexcept { return travelled_; }

    bool finished() const noexcept { return finished_; }

private:
    /// A smoothed sample plus the speed we arrived at it with. Velocity is
    /// derived once here rather than recomputed per dab, because it depends on
    /// the raw timestamps and those are gone by the time the spline is walked.
    struct Node {
        float x = 0.0f;
        float y = 0.0f;
        float pressure = 1.0f;
        float tilt = 1.5707963f;
        float velocity = 0.0f;
    };

    /// A position along the spline, carrying the attributes interpolated to
    /// that point.
    struct Walker {
        float x = 0.0f;
        float y = 0.0f;
        float pressure = 1.0f;
        float tilt = 1.5707963f;
        float velocity = 0.0f;
        bool valid = false;
    };

    void emitReadySegments(bool flushing);
    void emitSegment(size_t index);
    void placeDab(const Walker& at, float dirX, float dirY);
    void noteTiles(const Dab& dab);
    float nextRandom() noexcept;
    void applyEndTaper();

    Brush brush_;
    uint64_t rng_;

    std::vector<Node> nodes_;   // smoothed
    std::vector<Dab> dabs_;
    std::unordered_set<TileCoord, TileCoordHash> touched_;

    size_t nextSegment_ = 0;
    size_t consumed_ = 0;

    Walker cursor_;           // last point the walk reached
    float carried_ = 0.0f;    // arc length accumulated since the last dab
    float nextSpacing_ = 0.0f;// arc length still to cover before the next dab
    float travelled_ = 0.0f;  // total arc length
    double lastTimestamp_ = 0.0;
    bool finished_ = false;
};

}  // namespace mc
