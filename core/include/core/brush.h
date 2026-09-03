#pragma once

//
//  brush.h — the brush parameter model.
//
//  A brush is data, not code. Everything here is a plain value that can be
//  serialised, interpolated, and edited in a UI without touching the renderer,
//  because the whole point of a brush engine is that new brushes are authored
//  rather than programmed.
//
//  The shape of this file is the part that is expensive to change later. The
//  individual fields are cheap: adding "grain depth" is a struct member and a
//  shader uniform. What is not cheap is the *taxonomy* — what a dab is, what a
//  dynamic is allowed to modulate, and how several dynamics combine — because
//  that is baked into the emission loop and the GPU vertex format.
//
//  Where this deliberately departs from Procreate: dynamics here are explicit
//  named modulations rather than a generic source/target matrix. A matrix is
//  more expressive on paper, but it makes every dab evaluate a loop over
//  entries that are mostly disabled, and it makes the UI harder to lay out
//  rather than easier. Named fields cost one line each and stay branch-free.
//

#include <cstdint>

namespace mc {

/// What the grain is anchored to.
///
/// This is not a cosmetic choice between two textures — it decides whether the
/// grain reads as a property of the *paper* or of the *brush*, and only one of
/// them survives a stroke crossing its own path unchanged.
enum class GrainMovement : int32_t {
    /// Fixed to the canvas, like the tooth of the paper. Every dab covering a
    /// given canvas pixel breaks against the same tooth height there, so the
    /// texture belongs to the surface rather than to the stroke — two passes
    /// over one spot find the same grain, which is what makes it read as paper
    /// the drawing sits on rather than as a pattern printed onto the line.
    Canvas = 0,

    /// Travels with the stroke, as though the brush head carried it. Dry media
    /// dragged along the paper.
    ///
    /// Deliberately gives up the property above: two dabs at the same pixel
    /// are at different arc lengths, so they break against different grain and
    /// overlaps show. That is correct for the medium it imitates, and it is
    /// why the two modes cannot share one code path with a flag.
    Rolling = 1,
};

/// Maps one normalised input channel onto a multiplier.
///
/// `curve` is an exponent rather than a spline. A spline is what a brush
/// editor eventually wants, but an exponent covers the shapes that matter
/// (ease-in, linear, ease-out) in four bytes with no allocation, and a spline
/// can replace it later without changing a single call site.
struct Response {
    /// Multiplier when the input reads 0.
    float minimum = 1.0f;

    /// Multiplier when the input reads 1.
    float maximum = 1.0f;

    /// Exponent applied to the input before the interpolation. Above 1 the
    /// response stays near `minimum` for longer, which is how a pen that only
    /// opens up under real pressure is expressed.
    float curve = 1.0f;

    /// Disabled responses are skipped entirely rather than evaluating to 1,
    /// so a brush that ignores tilt costs nothing per dab for the privilege.
    bool enabled = false;

    float evaluate(float input) const;
};

/// The set of responses that drive one dab attribute. Enabled responses
/// multiply together.
///
/// Multiplication rather than addition, because these are gains: a brush at
/// half pressure and half tilt should land at a quarter, not at zero. It also
/// means the neutral element is 1, so a disabled response is genuinely free.
struct Modulation {
    Response byPressure;
    Response byTilt;
    Response byVelocity;

    /// All three inputs normalised to 0...1. Tilt is 1 when the pen is flat
    /// to the glass, not when it is upright, so that "more tilt" reads the
    /// way an artist means it.
    float evaluate(float pressure, float tilt, float velocity) const;
};

/// Everything that defines how a stroke puts ink down.
struct Brush {
    // MARK: Shape

    /// Dab diameter in canvas pixels, before any modulation.
    float size = 14.0f;

    /// Distance between consecutive dabs, as a fraction of the current dab
    /// diameter. Expressed as a fraction rather than in pixels so that a
    /// brush keeps its character when resized — the classic mistake here is
    /// absolute spacing, which turns a smooth small brush into a dotted line
    /// when scaled up.
    ///
    /// Below about 0.05 the cost rises steeply for no visible gain; above
    /// ~0.25 the individual dabs start to read as a chain.
    float spacing = 0.08f;

    /// Edge falloff. 1 is a hard-edged disc, 0 fades from the very centre.
    float hardness = 0.9f;

    /// 1 is circular; smaller values flatten the dab along `angle`, which is
    /// what gives a chisel or calligraphic nib.
    float roundness = 1.0f;

    /// Dab rotation in radians, used when the angle is not taken from the
    /// stroke direction.
    float angle = 0.0f;

    /// Rotate each dab to follow the direction of travel. This is what makes
    /// a flat nib behave like a real one through a curve.
    bool angleFollowsDirection = false;

    // MARK: Ink

    /// Ink laid down per dab. Density accumulates across dabs, so this decides
    /// how fast a stroke reaches full strength — and therefore whether it
    /// darkens where it crosses itself.
    ///
    /// At 1 a single pass saturates immediately, so overlaps cannot darken and
    /// the stroke reads as ink. Below 1 the passes build, which is what a
    /// pencil or an airbrush does. There is deliberately no mode switch: the
    /// two behaviours are the ends of this one control, as in Photoshop. A
    /// switch made `flow` and `opacity` redundant at one end of it, since both
    /// then scaled the same final alpha and only their product mattered.
    float flow = 1.0f;

    /// Stroke-level alpha, applied once when the finished stroke is
    /// composited. A ceiling on the whole stroke rather than a per-dab
    /// multiplier, so lowering it never makes overlaps appear.
    float opacity = 1.0f;

    // MARK: Grain

    /// How high the paper's tooth stands, 0 to 1. Ink is *thresholded*
    /// against it rather than scaled by it: pigment sticks where it has more
    /// to give than the tooth takes, and misses entirely where it has less.
    ///
    /// Multiplying was the first attempt and it was wrong. It lightened the
    /// whole stroke uniformly — a veil laid over the line — where real media
    /// leaves a solid body and a broken edge. Thresholding puts the texture
    /// where the ink is thin, which is where a surface actually shows through.
    ///
    /// The consequence worth knowing: at `flow` 1 the body of a stroke is
    /// fully covered, so no tooth shows there and only the edges break. Lower
    /// `flow` to bring the grain into the body. That is not a limitation — it
    /// is the same reason a marker hides paper texture and a pencil does not.
    ///
    /// Defaults to off, so a brush that predates grain behaves as it did.
    float grainDepth = 0.0f;

    /// Canvas pixels spanned by one repeat of the grain map. Larger is a
    /// coarser tooth.
    ///
    /// In canvas pixels rather than in dab diameters, because paper grain does
    /// not get finer when you pick up a smaller pencil.
    float grainScale = 192.0f;

    GrainMovement grainMovement = GrainMovement::Canvas;

    // MARK: Dynamics

    Modulation sizeDynamics;
    Modulation flowDynamics;

    /// Speed in canvas pixels per second that counts as full velocity input.
    /// Without a reference, velocity response would depend on canvas zoom and
    /// on the device's sample rate, which are exactly the things a brush
    /// should not notice.
    float velocityReference = 2000.0f;

    // MARK: Jitter

    /// Random size variation per dab, 0...1, as a fraction of the dab size.
    float sizeJitter = 0.0f;

    /// Random rotation per dab, in radians.
    float angleJitter = 0.0f;

    /// Random lateral offset per dab, as a fraction of the dab diameter.
    /// This is what turns a single shape into a spray or a texture.
    float scatter = 0.0f;

    /// Random per-dab flow variation, 0...1.
    float flowJitter = 0.0f;

    // MARK: Taper

    /// Arc length in canvas pixels over which the stroke ramps up at the start
    /// and down at the end. Zero disables tapering.
    ///
    /// The end taper is why a stroke cannot be finalised until it is finished:
    /// the last `taperLength` pixels change once we know where the end is.
    float taperLength = 0.0f;

    /// Size multiplier at the very start and very end of the taper.
    float taperStartScale = 0.0f;
    float taperEndScale = 0.0f;

    // MARK: Path

    /// Pulls the path toward its own moving average, 0...1. Procreate calls
    /// this StreamLine. It trades latency for steadiness, so it belongs to the
    /// brush rather than to the input layer — an inking pen wants it and a
    /// sketching pencil does not.
    float smoothing = 0.0f;

    /// Minimum size as a fraction of `size`, so that a zero-pressure sample
    /// tapers rather than disappearing and leaving a gap in the stroke.
    float minimumSizeFraction = 0.05f;
};

/// The default inking brush: hard edge, tight spacing, size on pressure,
/// no buildup. Chosen so that the first thing on screen is the one a manga
/// artist would actually reach for.
Brush inkPen();

}  // namespace mc
