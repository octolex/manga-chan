/*
 * brush_api.h — the brush engine, exposed to the Swift shell.
 *
 * Same boundary rules as the rest of the ABI: plain C, opaque handles, the
 * core owns its memory, no C++ types cross the line.
 *
 * How the shell is expected to use this:
 *
 *   MCStrokePath* path = mc_stroke_begin(&brush, seed);
 *   ... per touch event:
 *       mc_stroke_add_sample(path, x, y, pressure, tilt, azimuth, roll, t);
 *       size_t first = mc_stroke_consume_new(path);
 *       ... upload dabs [first, mc_stroke_dab_count(path)) to the GPU ...
 *   mc_stroke_finish(path);
 *   ... read back exactly mc_stroke_tile_count(path) tiles ...
 *   mc_stroke_end(path);
 *
 * The dab array is contiguous and stable between calls that do not add
 * samples, so the shell can hand its address straight to a Metal buffer rather
 * than copying. MCDab is laid out to match the GPU vertex struct exactly, and
 * that agreement is checked with a static assertion in brush_api.cpp — a
 * silent mismatch there produces garbage geometry with no error message,
 * which is the one class of bug we cannot debug without a frame debugger.
 */
#ifndef BRUSH_API_H
#define BRUSH_API_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One stamp of the brush shape. The entire contract with the renderer. */
typedef struct {
    float x;
    float y;
    float radius;     /* canvas pixels, after dynamics, jitter and taper */
    float angle;      /* radians */
    float flow;       /* per-dab alpha, before stroke opacity */
    float roundness;  /* 1 circular, below that flattened along `angle` */
    float hardness;   /* 1 hard edge, 0 fades from the centre */
    float grainOffset;/* arc length from the stroke start, for rolling grain */
} MCDab;

/* Matches mc::GrainMovement. */
typedef enum {
    MC_GRAIN_CANVAS = 0,   /* fixed to the canvas, like the tooth of the paper */
    MC_GRAIN_ROLLING = 1,  /* travels with the stroke, like dry media dragged */
} MCGrainMovement;

/* Matches mc::RenderingStyle. Decides what `opacity` below means: in a
 * Blending style it multiplies each dab and the dabs pile up with no ceiling;
 * in a Glaze it is left off the dab and caps the finished stroke instead. */
typedef enum {
    MC_RENDER_BLENDING = 0,  /* opacity per dab, accumulates — Procreate's default */
    MC_RENDER_GLAZE = 1,     /* opacity caps the whole stroke, once at composite */
} MCRenderingStyle;

/* Matches mc::ResponseCurve. Six interior points; the curve always runs from
 * (0,0) to (1,1), so `count` of 0 is linear and needs no points at all.
 *
 * Fixed capacity rather than a pointer because MCBrush is passed by value, and
 * a struct that owns memory cannot be. Revising the capacity is an ABI change,
 * which is why it is a named constant on both sides rather than a literal. */
#define MC_RESPONSE_CURVE_MAX_POINTS 6

typedef struct {
    int32_t count;
    float x[MC_RESPONSE_CURVE_MAX_POINTS];
    float y[MC_RESPONSE_CURVE_MAX_POINTS];
} MCResponseCurve;

/* Matches mc::Response. */
typedef struct {
    float minimum;
    float maximum;
    MCResponseCurve curve;
    int32_t enabled;   /* int rather than bool: C and C++ bool need not agree */
} MCResponse;

/* Matches mc::TaperEnd. */
typedef struct {
    float length;   /* canvas pixels the ramp runs over; 0 disables this end */
    float scale;    /* size multiplier at the very tip */
} MCTaperEnd;

/* Matches mc::Taper. Procreate presents this as one Vector2D control. */
typedef struct {
    MCTaperEnd start;
    MCTaperEnd end;
} MCTaper;

/* Matches mc::StrokeTapers. A finger reports no real pressure, so it needs a
 * taper of its own or a pressure-driven brush makes nothing from it. */
typedef struct {
    MCTaper pressure;
    MCTaper touch;
} MCStrokeTapers;

/* Matches mc::Modulation. */
typedef struct {
    MCResponse byPressure;
    MCResponse byTilt;
    MCResponse byVelocity;
} MCModulation;

/*
 * Matches mc::Brush field for field.
 *
 * Passed by value rather than through an opaque handle with setters. A brush
 * is a value — it gets copied, interpolated, and serialised — and forty
 * setters across the ABI would be forty chances to forget one.
 */
typedef struct {
    float size;
    float spacing;
    float hardness;
    float roundness;
    float angle;
    int32_t angleFollowsDirection;

    int32_t shapeCount;        /* stamps per dab position; 1 is one stamp */
    float shapeCountJitter;    /* 0...1, only ever removes stamps */

    float flow;                /* ink per dab; density accumulates across them */
    float opacity;             /* strength; per-dab in Blending, a cap in Glaze */
    int32_t renderingStyle;    /* MCRenderingStyle */

    float grainDepth;          /* tooth height; caps where ink may sit */
    float grainScale;          /* canvas pixels per repeat of the map */
    float grainBrightness;     /* -1...+1, 0 neutral; shifts the whole map */
    float grainContrast;       /* -1...+1, 0 neutral; opens it out around 0.5 */
    int32_t grainMovement;     /* MCGrainMovement */

    MCModulation sizeDynamics;
    MCModulation flowDynamics;
    float velocityReference;

    float sizeJitter;
    float angleJitter;
    float scatter;
    float flowJitter;

    MCStrokeTapers taper;

    float smoothing;           /* StreamLine amount; pull per 240 Hz sample, applied in time */
    float minimumSizeFraction;

    float stabilization;              /* Stabilization amount, 0...1 */
    float motionFiltering;            /* Motion filtering amount, 0...1; 0 is off */
    float motionFilteringExpression;  /* Motion filtering expression, 0...1 */
} MCBrush;

/* Matches mc::InputSettings: Procreate's Preferences → Pressure and Smoothing.
 * App-wide, applied to every stroke whatever the brush. */
typedef struct {
    MCResponseCurve pressureCurve;    /* the person's pressure curve; count 0 is linear */
    float pressureSmoothing;          /* 0...1 */
    float stabilization;              /* 0...1, a floor under every brush's own */
    float motionFiltering;            /* 0...1, a floor under every brush's own */
    float motionFilteringExpression;  /* 0...1, used when the global filtering wins */
} MCInputSettings;

/* Everything off and the curve linear. */
MCInputSettings mc_input_settings_default(void);

/* Evaluates a response curve at t in 0...1. For drawing the curve in the UI
 * with exactly the arithmetic the engine applies. */
float mc_response_curve_evaluate(const MCResponseCurve* curve, float t);

/* The smallest radius the dab shader draws. Must equal MS_MIN_DRAWN_RADIUS in
 * ShaderTypes.h; the harness checks. See mc::kMinimumDrawnRadius. */
#define MC_MIN_DRAWN_RADIUS 1.25f

/* The default inking brush: hard edge, tight spacing, width on pressure. */
MCBrush mc_brush_ink_pen(void);

/*
 * Fills `out` with a seamlessly tiling grain map: `size` x `size` single-channel
 * 8-bit texels, row-major from the top left. Returns the number of bytes
 * written, or 0 if `capacity` is too small.
 *
 * Generated rather than loaded from an asset. That keeps the asset-format
 * decision inside the brush editor milestone where it belongs, and it means the
 * map is a pure function of its seed — so the grain the shader samples on the
 * device is bit-identical to the one the C++ suite and the simulator harness
 * check against, with no file crossing between them.
 *
 * Upload the result as an r8Unorm texture with a repeating, linear sampler.
 * Those two choices are not incidental: repeat is what makes the tiling
 * seamless, and linear is what mc::AlphaTexture::sample reproduces.
 */
size_t mc_grain_generate(int32_t size, uint64_t seed, uint8_t* out, size_t capacity);

/*
 * The grain value the shader is expected to read at a point, for tests.
 * `u` and `v` are in map space, where 1.0 is one full repeat. This is the
 * reference the Metal sampler is pinned against — a flipped V or a half-texel
 * offset between the two is invisible on screen and obvious here.
 */
float mc_grain_sample(const uint8_t* map, int32_t size, float u, float v);

/* Procreate's grain Brightness and Contrast on one sampled value, both signed
 * -1...+1 with 0 neutral and exactly the identity. Mirrored in grain_tooth in
 * Shaders.metal; the simulator harness compares the two, which is the only
 * thing that keeps them from drifting. */
float mc_grain_levels(float sample, float brightness, float contrast);

typedef struct MCStrokePath MCStrokePath;

/*
 * `seed` makes jitter reproducible. Undo re-runs a stroke, so a brush that
 * jittered differently on each run would make undo lossy — pass a value
 * derived from the stroke, not from the clock.
 */
MCStrokePath* mc_stroke_begin(const MCBrush* brush, uint64_t seed);
void mc_stroke_end(MCStrokePath* path);

/* Samples must arrive in time order. Coordinates are canvas pixels.
 * `tilt` is altitude in radians (pi/2 upright); `roll` may be negative to mean
 * the hardware cannot report it. */
/* `fromPressureDevice` is 1 for a Pencil and 0 for a finger. It selects which
 * of the brush's two tapers applies and cannot be inferred: a finger reports a
 * synthesised pressure and an upright tilt, and so does a perpendicular Pencil.
 * Only the first sample of a stroke is read. */
void mc_stroke_add_sample(MCStrokePath* path,
                          float x, float y,
                          float pressure,
                          float tilt,
                          float azimuth,
                          float roll,
                          double timestamp,
                          int32_t fromPressureDevice);

/* Flushes the tail of the stroke and applies the end taper. */
void mc_stroke_finish(MCStrokePath* path);

/* Applies the app-wide input settings. Call before the first sample; ignored
 * after it. */
void mc_stroke_set_input_settings(MCStrokePath* path, const MCInputSettings* settings);

/* Index of the first dab revised after emission (the end taper does this), or
 * the dab count when none was. A renderer that has already stamped dabs at or
 * past this index must restamp the stroke. */
size_t mc_stroke_first_revised_dab(const MCStrokePath* path);

size_t mc_stroke_dab_count(const MCStrokePath* path);

/* Contiguous, oldest first. Invalidated by the next mc_stroke_add_sample. */
const MCDab* mc_stroke_dabs(const MCStrokePath* path);

/* Index of the first dab not yet reported, then marks everything as reported.
 * Upload [result, mc_stroke_dab_count(path)) to draw only what is new. */
size_t mc_stroke_consume_new(MCStrokePath* path);

/* Exactly the tiles the stroke covers — not its bounding box. A diagonal
 * stroke's bounding box is most of the canvas. */
size_t mc_stroke_tile_count(const MCStrokePath* path);

/* Writes up to `capacity` tile coordinates as x,y pairs. Returns how many
 * were written. Order is unspecified. */
size_t mc_stroke_copy_tiles(const MCStrokePath* path, int32_t* outXY, size_t capacity);

/* Total arc length walked, in canvas pixels. Useful for the HUD. */
float mc_stroke_length(const MCStrokePath* path);

/* ---- QuickShape ------------------------------------------------------------
 * Draw and hold: the stroke snaps to a line, arc, ellipse or polygon. See
 * core/quickshape.h. The shell decides when (the hold); the engine decides
 * what, and walks the shape out as an ordinary stroke. */

typedef enum {
    MC_SHAPE_NONE = 0,
    MC_SHAPE_LINE = 1,
    MC_SHAPE_ARC = 2,
    MC_SHAPE_ELLIPSE = 3,
    MC_SHAPE_POLYLINE = 4,
} MCShapeKind;

#define MC_QUICKSHAPE_MAX_VERTICES 16

typedef struct {
    int32_t kind;          /* MCShapeKind */
    int32_t closed;
    int32_t vertexCount;
    float vx[MC_QUICKSHAPE_MAX_VERTICES];
    float vy[MC_QUICKSHAPE_MAX_VERTICES];
    float cx, cy, rx, ry, rotation;
    float start, sweep;
    float pressure, tilt;
    /* How far the stroke missed each fit tried, as a multiple of its limit:
     * <= 1 fits, > 1 refused, 0 not tried. For the log. */
    float lineMiss, arcMiss, ellipseMiss, polylineMiss;
} MCQuickShape;

/* Fits a shape to the stroke drawn so far. Returns its kind; MC_SHAPE_NONE
 * means leave the stroke alone. */
int32_t mc_quickshape_detect(const MCStrokePath* path, MCQuickShape* out);

/* Line to the nearest 15 degrees, ellipse to a circle. */
void mc_quickshape_constrain(MCQuickShape* shape);

/* While the pen is still held after the snap, a line's end follows it. */
void mc_quickshape_move_end(MCQuickShape* shape, float x, float y, int32_t constrained);

/* A new, unfinished stroke drawing `shape` with `brush`. Stabilisers are off
 * for it — the shape is already exact, and StreamLine would pull its end
 * short. Finish it when the pen lifts, exactly like any other stroke. */
MCStrokePath* mc_quickshape_stroke(const MCQuickShape* shape, const MCBrush* brush,
                                   uint64_t seed, double startTime,
                                   int32_t fromPressureDevice);

#ifdef __cplusplus
}
#endif

#endif /* BRUSH_API_H */
