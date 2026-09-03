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

/* Matches mc::Response. */
typedef struct {
    float minimum;
    float maximum;
    float curve;
    int32_t enabled;   /* int rather than bool: C and C++ bool need not agree */
} MCResponse;

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

    float flow;                /* ink per dab; density accumulates across them */
    float opacity;             /* ceiling on the finished stroke */

    float grainDepth;          /* tooth height; ink is thresholded against it */
    float grainScale;          /* canvas pixels per repeat of the map */
    int32_t grainMovement;     /* MCGrainMovement */

    MCModulation sizeDynamics;
    MCModulation flowDynamics;
    float velocityReference;

    float sizeJitter;
    float angleJitter;
    float scatter;
    float flowJitter;

    float taperLength;
    float taperStartScale;
    float taperEndScale;

    float smoothing;
    float minimumSizeFraction;
} MCBrush;

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
void mc_stroke_add_sample(MCStrokePath* path,
                          float x, float y,
                          float pressure,
                          float tilt,
                          float azimuth,
                          float roll,
                          double timestamp);

/* Flushes the tail of the stroke and applies the end taper. */
void mc_stroke_finish(MCStrokePath* path);

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

#ifdef __cplusplus
}
#endif

#endif /* BRUSH_API_H */
