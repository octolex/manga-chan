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

/// The shape of a response, as a set of points — the way Procreate's is a
/// graph rather than a slider.
///
/// This replaced an exponent on 2026-09-09. The exponent covered ease-in,
/// linear and ease-out in four bytes and every call site survived the swap,
/// exactly as the note here predicted it would. What it could not cover is a
/// curve that is flat, then steep, then flat again — the shape an artist draws
/// when they want the middle of the pressure range to carry the control — and
/// that is a shape, not a parameter, so no amount of exponent reaches it.
///
/// **The curve always passes through (0,0) and (1,1).** `count` interior
/// points bend it in between, so a count of 0 is exactly linear and is the
/// default. The endpoints are fixed rather than draggable because moving them
/// is what `minimum` and `maximum` already do, and two controls for one effect
/// is how a brush editor becomes confusing.
///
/// **Fixed capacity, no allocation.** `Brush` crosses the C ABI by value, so a
/// curve cannot own a pointer. Six interior points is a guess at "enough" —
/// generous for a response, cheap at 52 bytes — and it is the one number here
/// that would cost an ABI change to revise, so it is called out rather than
/// buried.
///
/// **Interpolation is piecewise linear, and that is a safety property rather
/// than laziness.** A Catmull-Rom or Bézier through the same points can
/// overshoot, and an overshooting *size* response produces a radius outside
/// the range the UI showed — at best a surprise, at worst a negative number.
/// Linear cannot. Smoothing the drawn curve is an evaluation detail that can
/// change later without touching the taxonomy, which is the distinction this
/// file exists to protect.
struct ResponseCurve {
    /// Revising this costs an ABI change; see above.
    static constexpr int kMaxPoints = 6;

    /// Interior points in use. 0 is linear.
    int32_t count = 0;

    /// Interior control points, ascending in x, both coordinates in 0...1.
    /// Points that do not increase in x are ignored rather than rejected: a
    /// curve arriving from a UI mid-drag, or from a file written by an older
    /// build, must still draw something sane.
    float x[kMaxPoints] = {};
    float y[kMaxPoints] = {};

    /// Maps 0...1 to 0...1.
    float evaluate(float t) const;

    /// The curve `pow(t, e)` used to be, sampled. Kept because it is how the
    /// existing presets were expressed, and because a migration nobody can
    /// check against the old behaviour is a migration nobody should trust.
    static ResponseCurve exponent(float e);
};

/// Maps one normalised input channel onto a multiplier.
struct Response {
    /// Multiplier when the input reads 0.
    float minimum = 1.0f;

    /// Multiplier when the input reads 1.
    float maximum = 1.0f;

    /// The shape between them. Linear by default.
    ResponseCurve curve;

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

    /// Ink laid down **per dab**, accumulating freely across them. This is the
    /// rate at which a stroke builds, not the strength it ends at.
    ///
    /// Uncompensated, deliberately, and measured rather than argued: at one
    /// Opacity across an eight-fold range of Spacing, Procreate produced 0.03,
    /// 0.06, 0.08 and 0.09 ink (2026-09-08). Compensation requires those to be
    /// equal. Photoshop's Flow is the same. More dabs over a pixel is more
    /// pigment on it — that is the medium, not a defect.
    ///
    /// **The consequence, stated rather than fixed:** anything much above 20%
    /// saturates in a single pass, because roughly seventeen dabs cover every
    /// pixel at the default spacing and 1 - 0.8^17 is already 0.98. Flow's
    /// useful range is the bottom of the slider. That is true of Photoshop, and
    /// it is why Procreate keeps Opacity on the main screen and Flow inside
    /// Brush Studio. If it proves awkward the answer is a curve on the slider,
    /// never a change to what the number means.
    float flow = 1.0f;

    /// Stroke-level alpha, applied once when the finished stroke is composited.
    /// A ceiling on the whole stroke rather than a per-dab multiplier, so
    /// lowering it never makes overlaps appear.
    ///
    /// **This is the strength control**, and between them the two fields give
    /// both of Procreate's accumulation families without a mode switch:
    ///
    ///   * Opacity 100% with a low Flow is a **Blending** style — dabs pile up
    ///     freely and a stroke can saturate against itself. Measured: Intense
    ///     Blending at 25% opacity scrubbed to solid black.
    ///   * A lowered Opacity is a **Glaze** style — a stroke cannot exceed it
    ///     however much it overlaps itself, while a *separate* stroke
    ///     composites on top. Measured: Light Glaze at 25% opacity settled at
    ///     0.16 ink under twenty passes without lifting, then reached 0.60
    ///     after five more strokes. Six strokes of 0.16 composited alpha-over
    ///     predict 0.65.
    ///
    /// Procreate spends six named rendering styles on that axis. Two
    /// independent sliders reach the same places, which is why the
    /// Maximum/Buildup switch removed earlier is not coming back — it was a
    /// third control for something these two already span.
    float opacity = 1.0f;

    // MARK: Grain

    /// How high the paper's tooth stands, 0 to 1. It is a *ceiling on where
    /// ink may sit*, not a scaling of how much lands and not a threshold
    /// against how much has accumulated: the tooth multiplies a dab's coverage
    /// before the maximum blend that builds the stroke's silhouette.
    ///
    /// That one line produces both anchoring modes with no special case, which
    /// is the reason to believe it. Canvas grain finds the same tooth at a
    /// pixel for every dab, so `max(tooth * shape)` stays `tooth * silhouette`
    /// however many passes cross it and the pits never fill. Rolling grain is
    /// offset by arc length, so each pass puts its pits somewhere new and the
    /// running maximum climbs to solid.
    ///
    /// Both behaviours were measured in Procreate on 2026-09-05, along with the
    /// two facts that rule out the alternatives: depth changes only how darkly
    /// the gaps are masked and never the pattern's shape, and lower opacity
    /// does *not* show more texture. A threshold against accumulated coverage
    /// would fail that last one badly.
    ///
    /// Three implementations came before this one — multiply, per-dab
    /// threshold, and a planned composite-time threshold — and the first was
    /// mechanically this. It was dropped on the objection that it "veiled the
    /// whole stroke", which the same measurement falsified: a canvas-anchored
    /// grain veils the whole inked area permanently, on purpose. What looked
    /// wrong was almost certainly the map, not the maths.
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
