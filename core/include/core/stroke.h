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
#include "core/input_filter.h"
#include "core/stroke_sample.h"
#include "core/tile.h"

#include <cstdint>
#include <unordered_set>
#include <vector>

namespace mc {

/// The smallest radius the dab shader draws, in canvas pixels.
///
/// A dab smaller than this is drawn at this size with its flow scaled by the
/// ratio of areas, `(radius / kMinimumDrawnRadius)^2`, rather than drawn at
/// its true size. A disc much under a pixel is sampled at pixel centres, so
/// whether it shows at all depends on where it lands — the cause of the 1 px
/// line that drew invisible or beaded (bug 13). Trading size for opacity below
/// this is what Photoshop and Krita do; at exactly this radius the two agree,
/// so nothing changes for a brush that never goes this small.
///
/// 1.25 rather than 1, measured: in CI at a 1 px minimum a 0.4 px dab put down
/// 1.67 times as much ink landing on a pixel centre as on a pixel corner. The
/// shader's antialiasing band is about a pixel wide, and a disc only a pixel
/// across is mostly band, so where it lands still mattered. A quarter pixel
/// more makes the disc wide enough to sample evenly, and touches only brushes
/// under 2.5 px.
///
/// The shader holds the same number as `MS_MIN_DRAWN_RADIUS`, and the harness
/// tests that the two agree.
inline constexpr float kMinimumDrawnRadius = 1.25f;

/// How long, in seconds, the start of a Pencil stroke is held back while its
/// pressure settles.
///
/// Found on the device, 2026-11-09: with the default pen going to a hairline
/// at light pressure (D4), a stroke started lightly began with one big dab and
/// then ran on at about 1 px. UIKit's corrections to estimated force were
/// measured on the same device and peak at 0.08, far too small to explain it,
/// so the reasoned cause is a real force spike as the nib strikes the glass.
/// During this window the held start takes the lowest pressure seen so far:
/// a spike that falls away is discounted, and a stroke that starts light and
/// presses harder is untouched, because its earliest samples are already the
/// lightest. The price is that the first dab appears this much later; the
/// predicted tip covers most of it.
///
/// **25 ms is a guess** — six Pencil samples. The HUD now shows each stroke's
/// first raw pressures, which is the measurement that sets it.
inline constexpr double kTouchDownSettle = 0.025;

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

    /// Arc length from the start of the stroke, in canvas pixels.
    ///
    /// Carried for `GrainMovement::Rolling`, which scrolls the grain along the
    /// stroke and therefore needs to know how far this dab is into it. Canvas
    /// grain ignores it and derives its coordinate from the pixel position.
    ///
    /// It is here rather than in a uniform because it differs per dab and the
    /// GPU has no way to recover it: arc length is what the walk in
    /// `emitSegment` produces and nothing downstream can reconstruct it from
    /// positions alone once smoothing and scatter have moved the dabs.
    float grainOffset = 0.0f;
};

/// Turns a growing list of samples into a growing list of dabs.
class StrokePath {
public:
    /// `seed` makes jitter reproducible. A brush that jitters differently on
    /// every run cannot be tested, and cannot be undone and redone to the same
    /// pixels either — which matters more, because undo must be exact.
    explicit StrokePath(const Brush& brush, uint64_t seed = 0x9E3779B97F4A7C15ULL);

    /// The app-wide Pressure and Smoothing settings. Must be called before the
    /// first sample; a stroke that changed its filters part-way would kink at
    /// the point it changed, so a late call is ignored rather than honoured.
    void setInputSettings(const InputSettings& settings);

    /// Samples must arrive in time order. Duplicates of the previous position
    /// are dropped: a zero-length tangent would NaN its way through the whole
    /// spline.
    void addSample(const StrokeSample& sample);

    /// Which taper applies, given what drew the stroke.
    const Taper& activeTaper() const;

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

    /// Index of the first dab revised after it was emitted, or `dabs().size()`
    /// when none was.
    ///
    /// Emission is append-only *except* for the end taper, which shrinks dabs
    /// already handed out. A renderer that accumulates coverage incrementally
    /// has already stamped those at full size, and the accumulation cannot be
    /// taken back — so it needs to know, and restamp. Until 2026-11-06 the
    /// renderer assumed nothing was ever revised, and the end taper never
    /// reached the canvas.
    size_t firstRevisedDab() const noexcept {
        return firstRevised_ < dabs_.size() ? firstRevised_ : dabs_.size();
    }

    /// The samples that became spline nodes, after the input filter: what the
    /// stroke is actually drawn through. QuickShape fits shapes to these.
    const std::vector<StrokeSample>& nodeSamples() const noexcept { return nodeSamples_; }

    /// The brush this stroke was begun with.
    const Brush& brush() const noexcept { return brush_; }

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
    InputFilter filter_;
    std::vector<StrokeSample> nodeSamples_;
    size_t firstRevised_ = static_cast<size_t>(-1);
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
    double firstTimestamp_ = 0.0;
    bool finished_ = false;

    /// While the touch-down is settling, lowers every held node's pressure to
    /// `pressure` where that is lower. See kTouchDownSettle.
    void settleStartPressure(float pressure, double timestamp);

    /// Latched from the first sample. One stroke is one touch, so a stroke
    /// that changed device mid-way would be a bug in the shell rather than a
    /// case to handle; taking the first is both correct and stable, where
    /// taking the latest would let a stray sample re-taper the whole stroke
    /// at the moment it finishes.
    bool fromPressureDevice_ = true;
};

}  // namespace mc
