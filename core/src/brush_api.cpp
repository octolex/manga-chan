#include "core/brush_api.h"

#include "core/brush.h"
#include "core/quickshape.h"
#include "core/stroke.h"
#include "core/texture.h"

#include <algorithm>
#include <cstring>
#include <type_traits>
#include <vector>

using namespace mc;

// The shell hands the dab array straight to a Metal buffer without copying, so
// the C struct and the C++ one must agree exactly. A mismatch here would show
// up as garbage geometry with no error message — the one failure mode we
// cannot chase without a frame debugger.
static_assert(sizeof(MCDab) == sizeof(Dab), "MCDab must match mc::Dab");
static_assert(offsetof(MCDab, x) == offsetof(Dab, x), "dab x offset");
static_assert(offsetof(MCDab, y) == offsetof(Dab, y), "dab y offset");
static_assert(offsetof(MCDab, radius) == offsetof(Dab, radius), "dab radius offset");
static_assert(offsetof(MCDab, angle) == offsetof(Dab, angle), "dab angle offset");
static_assert(offsetof(MCDab, flow) == offsetof(Dab, flow), "dab flow offset");
static_assert(offsetof(MCDab, roundness) == offsetof(Dab, roundness), "dab roundness offset");
static_assert(offsetof(MCDab, hardness) == offsetof(Dab, hardness), "dab hardness offset");
static_assert(offsetof(MCDab, grainOffset) == offsetof(Dab, grainOffset), "dab grainOffset offset");
static_assert(std::is_trivially_copyable<Dab>::value, "dabs must be memcpy-able to the GPU");
static_assert(MC_MIN_DRAWN_RADIUS == kMinimumDrawnRadius,
              "the C ABI and the engine must agree on the smallest drawn radius");

// The two capacities are declared in two files and can drift apart silently:
// the ABI header is plain C and cannot see the C++ constant. A mismatch would
// copy the wrong number of points across the boundary and be visible only as a
// response curve that goes slightly wrong at one end.
static_assert(MC_RESPONSE_CURVE_MAX_POINTS == ResponseCurve::kMaxPoints,
              "the C and C++ curve capacities must agree");
static_assert(sizeof(MCResponseCurve) == sizeof(ResponseCurve),
              "MCResponseCurve must match mc::ResponseCurve");

struct MCStrokePath {
    explicit MCStrokePath(const Brush& brush, uint64_t seed) : path(brush, seed) {}
    StrokePath path;

    // Scratch for tile export, so the caller can ask for the count and then
    // fetch without the set being walked twice into a temporary.
    std::vector<int32_t> tileScratch;
};

namespace {

ResponseCurve fromC(const MCResponseCurve& c) {
    ResponseCurve out;
    out.count = c.count;
    for (int i = 0; i < ResponseCurve::kMaxPoints; ++i) {
        out.x[i] = c.x[i];
        out.y[i] = c.y[i];
    }
    return out;
}

MCResponseCurve toC(const ResponseCurve& c) {
    MCResponseCurve out{};
    out.count = c.count;
    for (int i = 0; i < ResponseCurve::kMaxPoints; ++i) {
        out.x[i] = c.x[i];
        out.y[i] = c.y[i];
    }
    return out;
}

TaperEnd convert(const MCTaperEnd& e) { return TaperEnd{e.length, e.scale}; }
MCTaperEnd convert(const TaperEnd& e) { return MCTaperEnd{e.length, e.scale}; }

Taper convert(const MCTaper& t) { return Taper{convert(t.start), convert(t.end)}; }
MCTaper convert(const Taper& t) { return MCTaper{convert(t.start), convert(t.end)}; }

StrokeTapers convert(const MCStrokeTapers& t) {
    return StrokeTapers{convert(t.pressure), convert(t.touch)};
}
MCStrokeTapers convert(const StrokeTapers& t) {
    return MCStrokeTapers{convert(t.pressure), convert(t.touch)};
}

Response fromC(const MCResponse& r) {
    Response out;
    out.minimum = r.minimum;
    out.maximum = r.maximum;
    out.curve = fromC(r.curve);
    out.enabled = r.enabled != 0;
    return out;
}

MCResponse toC(const Response& r) {
    MCResponse out;
    out.minimum = r.minimum;
    out.maximum = r.maximum;
    out.curve = toC(r.curve);
    out.enabled = r.enabled ? 1 : 0;
    return out;
}

Modulation fromC(const MCModulation& m) {
    Modulation out;
    out.byPressure = fromC(m.byPressure);
    out.byTilt = fromC(m.byTilt);
    out.byVelocity = fromC(m.byVelocity);
    return out;
}

MCModulation toC(const Modulation& m) {
    MCModulation out;
    out.byPressure = toC(m.byPressure);
    out.byTilt = toC(m.byTilt);
    out.byVelocity = toC(m.byVelocity);
    return out;
}

InputSettings fromC(const MCInputSettings& s) {
    InputSettings out;
    out.pressureCurve = fromC(s.pressureCurve);
    out.pressureSmoothing = s.pressureSmoothing;
    out.stabilization = s.stabilization;
    out.motionFiltering = s.motionFiltering;
    out.motionFilteringExpression = s.motionFilteringExpression;
    return out;
}

MCInputSettings toC(const InputSettings& s) {
    MCInputSettings out;
    out.pressureCurve = toC(s.pressureCurve);
    out.pressureSmoothing = s.pressureSmoothing;
    out.stabilization = s.stabilization;
    out.motionFiltering = s.motionFiltering;
    out.motionFilteringExpression = s.motionFilteringExpression;
    return out;
}

QuickShape fromC(const MCQuickShape& q) {
    QuickShape out;
    switch (q.kind) {
    case MC_SHAPE_LINE: out.kind = ShapeKind::Line; break;
    case MC_SHAPE_ARC: out.kind = ShapeKind::Arc; break;
    case MC_SHAPE_ELLIPSE: out.kind = ShapeKind::Ellipse; break;
    case MC_SHAPE_POLYLINE: out.kind = ShapeKind::Polyline; break;
    default: out.kind = ShapeKind::None; break;
    }
    out.closed = q.closed != 0;
    out.vertexCount = std::clamp(q.vertexCount, 0, QuickShape::kMaxVertices);
    for (int i = 0; i < QuickShape::kMaxVertices; ++i) {
        out.vx[i] = q.vx[i];
        out.vy[i] = q.vy[i];
    }
    out.cx = q.cx; out.cy = q.cy; out.rx = q.rx; out.ry = q.ry;
    out.rotation = q.rotation; out.start = q.start; out.sweep = q.sweep;
    out.pressure = q.pressure; out.tilt = q.tilt;
    return out;
}

MCQuickShape toC(const QuickShape& q) {
    MCQuickShape out{};
    out.kind = static_cast<int32_t>(q.kind);
    out.closed = q.closed ? 1 : 0;
    out.vertexCount = q.vertexCount;
    for (int i = 0; i < QuickShape::kMaxVertices; ++i) {
        out.vx[i] = q.vx[i];
        out.vy[i] = q.vy[i];
    }
    out.cx = q.cx; out.cy = q.cy; out.rx = q.rx; out.ry = q.ry;
    out.rotation = q.rotation; out.start = q.start; out.sweep = q.sweep;
    out.pressure = q.pressure; out.tilt = q.tilt;
    return out;
}

Brush fromC(const MCBrush& b) {
    Brush out;
    out.size = b.size;
    out.spacing = b.spacing;
    out.hardness = b.hardness;
    out.roundness = b.roundness;
    out.angle = b.angle;
    out.angleFollowsDirection = b.angleFollowsDirection != 0;
    out.shapeCount = b.shapeCount;
    out.shapeCountJitter = b.shapeCountJitter;
    out.flow = b.flow;
    out.opacity = b.opacity;
    out.grainDepth = b.grainDepth;
    out.grainScale = b.grainScale;
    out.renderingStyle = b.renderingStyle == MC_RENDER_GLAZE
        ? RenderingStyle::Glaze : RenderingStyle::Blending;
    out.grainBrightness = b.grainBrightness;
    out.grainContrast = b.grainContrast;
    out.grainMovement = b.grainMovement == MC_GRAIN_ROLLING
        ? GrainMovement::Rolling : GrainMovement::Canvas;
    out.sizeDynamics = fromC(b.sizeDynamics);
    out.flowDynamics = fromC(b.flowDynamics);
    out.velocityReference = b.velocityReference;
    out.sizeJitter = b.sizeJitter;
    out.angleJitter = b.angleJitter;
    out.scatter = b.scatter;
    out.flowJitter = b.flowJitter;
    out.taper = convert(b.taper);
    out.smoothing = b.smoothing;
    out.minimumSizeFraction = b.minimumSizeFraction;
    out.stabilization = b.stabilization;
    out.motionFiltering = b.motionFiltering;
    out.motionFilteringExpression = b.motionFilteringExpression;
    return out;
}

MCBrush toC(const Brush& b) {
    MCBrush out;
    out.size = b.size;
    out.spacing = b.spacing;
    out.hardness = b.hardness;
    out.roundness = b.roundness;
    out.angle = b.angle;
    out.angleFollowsDirection = b.angleFollowsDirection ? 1 : 0;
    out.shapeCount = b.shapeCount;
    out.shapeCountJitter = b.shapeCountJitter;
    out.flow = b.flow;
    out.opacity = b.opacity;
    out.grainDepth = b.grainDepth;
    out.grainScale = b.grainScale;
    out.renderingStyle = b.renderingStyle == RenderingStyle::Glaze
        ? MC_RENDER_GLAZE : MC_RENDER_BLENDING;
    out.grainBrightness = b.grainBrightness;
    out.grainContrast = b.grainContrast;
    out.grainMovement = b.grainMovement == GrainMovement::Rolling
        ? MC_GRAIN_ROLLING : MC_GRAIN_CANVAS;
    out.sizeDynamics = toC(b.sizeDynamics);
    out.flowDynamics = toC(b.flowDynamics);
    out.velocityReference = b.velocityReference;
    out.sizeJitter = b.sizeJitter;
    out.angleJitter = b.angleJitter;
    out.scatter = b.scatter;
    out.flowJitter = b.flowJitter;
    out.taper = convert(b.taper);
    out.smoothing = b.smoothing;
    out.minimumSizeFraction = b.minimumSizeFraction;
    out.stabilization = b.stabilization;
    out.motionFiltering = b.motionFiltering;
    out.motionFilteringExpression = b.motionFilteringExpression;
    return out;
}

}  // namespace

extern "C" {

MCBrush mc_brush_ink_pen(void) {
    return toC(inkPen());
}

size_t mc_grain_generate(int32_t size, uint64_t seed, uint8_t* out, size_t capacity) {
    if (out == nullptr || size <= 0) return 0;

    const size_t needed = static_cast<size_t>(size) * static_cast<size_t>(size);
    if (capacity < needed) return 0;

    const AlphaTexture grain = makeGrain(size, seed);
    if (grain.byteCount() != needed) return 0;

    std::memcpy(out, grain.pixels(), needed);
    return needed;
}

float mc_grain_sample(const uint8_t* map, int32_t size, float u, float v) {
    if (map == nullptr || size <= 0) return 1.0f;

    // Repeat, because that is the address mode the grain is uploaded with. A
    // reference sampler that disagreed with the shader's sampler about
    // addressing would pass every test and fail on the device.
    return sampleAlpha(map, size, size, u, v, Wrap::Repeat);
}

float mc_grain_levels(float sample, float brightness, float contrast) {
    return grainLevels(sample, brightness, contrast);
}

MCStrokePath* mc_stroke_begin(const MCBrush* brush, uint64_t seed) {
    if (brush == nullptr) return nullptr;
    return new MCStrokePath(fromC(*brush), seed);
}

void mc_stroke_end(MCStrokePath* path) {
    delete path;
}

void mc_stroke_add_sample(MCStrokePath* path,
                          float x, float y,
                          float pressure,
                          float tilt,
                          float azimuth,
                          float roll,
                          double timestamp,
                          int32_t fromPressureDevice) {
    if (path == nullptr) return;
    StrokeSample sample;
    sample.fromPressureDevice = fromPressureDevice != 0;
    sample.x = x;
    sample.y = y;
    sample.pressure = pressure;
    sample.tilt = tilt;
    sample.azimuth = azimuth;
    sample.roll = roll;
    sample.timestamp = timestamp;
    path->path.addSample(sample);
}

void mc_stroke_finish(MCStrokePath* path) {
    if (path == nullptr) return;
    path->path.finish();
}

MCInputSettings mc_input_settings_default(void) {
    return toC(InputSettings{});
}

float mc_response_curve_evaluate(const MCResponseCurve* curve, float t) {
    if (curve == nullptr) return t;
    return fromC(*curve).evaluate(t);
}

void mc_stroke_set_input_settings(MCStrokePath* path, const MCInputSettings* settings) {
    if (path == nullptr || settings == nullptr) return;
    path->path.setInputSettings(fromC(*settings));
}

size_t mc_stroke_first_revised_dab(const MCStrokePath* path) {
    return path == nullptr ? 0 : path->path.firstRevisedDab();
}

size_t mc_stroke_dab_count(const MCStrokePath* path) {
    return path == nullptr ? 0 : path->path.dabs().size();
}

const MCDab* mc_stroke_dabs(const MCStrokePath* path) {
    if (path == nullptr || path->path.dabs().empty()) return nullptr;
    return reinterpret_cast<const MCDab*>(path->path.dabs().data());
}

size_t mc_stroke_consume_new(MCStrokePath* path) {
    return path == nullptr ? 0 : path->path.consumeNewDabs();
}

size_t mc_stroke_tile_count(const MCStrokePath* path) {
    return path == nullptr ? 0 : path->path.touchedTiles().size();
}

size_t mc_stroke_copy_tiles(const MCStrokePath* path, int32_t* outXY, size_t capacity) {
    if (path == nullptr || outXY == nullptr) return 0;
    size_t written = 0;
    for (const TileCoord& c : path->path.touchedTiles()) {
        if (written >= capacity) break;
        outXY[written * 2] = c.x;
        outXY[written * 2 + 1] = c.y;
        ++written;
    }
    return written;
}

float mc_stroke_length(const MCStrokePath* path) {
    return path == nullptr ? 0.0f : path->path.length();
}

int32_t mc_quickshape_detect(const MCStrokePath* path, MCQuickShape* out) {
    if (path == nullptr || out == nullptr) return MC_SHAPE_NONE;
    const QuickShape shape = detectShape(path->path.nodeSamples());
    *out = toC(shape);
    return out->kind;
}

void mc_quickshape_constrain(MCQuickShape* shape) {
    if (shape == nullptr) return;
    QuickShape q = fromC(*shape);
    constrainShape(q);
    *shape = toC(q);
}

void mc_quickshape_move_end(MCQuickShape* shape, float x, float y, int32_t constrained) {
    if (shape == nullptr) return;
    QuickShape q = fromC(*shape);
    moveShapeEnd(q, x, y, constrained != 0);
    *shape = toC(q);
}

MCStrokePath* mc_quickshape_stroke(const MCQuickShape* shape, const MCBrush* brush,
                                   uint64_t seed, double startTime,
                                   int32_t fromPressureDevice) {
    if (shape == nullptr || brush == nullptr) return nullptr;
    Brush exact = fromC(*brush);
    exact.smoothing = 0.0f;
    exact.stabilization = 0.0f;
    exact.motionFiltering = 0.0f;
    auto* path = new MCStrokePath(exact, seed);
    for (const StrokeSample& s : shapeSamples(fromC(*shape), startTime, fromPressureDevice != 0)) {
        path->path.addSample(s);
    }
    return path;
}

}  // extern "C"
