#include "core/brush_api.h"

#include "core/brush.h"
#include "core/stroke.h"

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
static_assert(std::is_trivially_copyable<Dab>::value, "dabs must be memcpy-able to the GPU");

struct MCStrokePath {
    explicit MCStrokePath(const Brush& brush, uint64_t seed) : path(brush, seed) {}
    StrokePath path;

    // Scratch for tile export, so the caller can ask for the count and then
    // fetch without the set being walked twice into a temporary.
    std::vector<int32_t> tileScratch;
};

namespace {

Response fromC(const MCResponse& r) {
    Response out;
    out.minimum = r.minimum;
    out.maximum = r.maximum;
    out.curve = r.curve;
    out.enabled = r.enabled != 0;
    return out;
}

MCResponse toC(const Response& r) {
    MCResponse out;
    out.minimum = r.minimum;
    out.maximum = r.maximum;
    out.curve = r.curve;
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

Brush fromC(const MCBrush& b) {
    Brush out;
    out.size = b.size;
    out.spacing = b.spacing;
    out.hardness = b.hardness;
    out.roundness = b.roundness;
    out.angle = b.angle;
    out.angleFollowsDirection = b.angleFollowsDirection != 0;
    out.flow = b.flow;
    out.opacity = b.opacity;
    out.accumulation = b.accumulation == MC_ACCUMULATION_BUILDUP
        ? Accumulation::Buildup : Accumulation::Maximum;
    out.sizeDynamics = fromC(b.sizeDynamics);
    out.flowDynamics = fromC(b.flowDynamics);
    out.velocityReference = b.velocityReference;
    out.sizeJitter = b.sizeJitter;
    out.angleJitter = b.angleJitter;
    out.scatter = b.scatter;
    out.flowJitter = b.flowJitter;
    out.taperLength = b.taperLength;
    out.taperStartScale = b.taperStartScale;
    out.taperEndScale = b.taperEndScale;
    out.smoothing = b.smoothing;
    out.minimumSizeFraction = b.minimumSizeFraction;
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
    out.flow = b.flow;
    out.opacity = b.opacity;
    out.accumulation = b.accumulation == Accumulation::Buildup
        ? MC_ACCUMULATION_BUILDUP : MC_ACCUMULATION_MAXIMUM;
    out.sizeDynamics = toC(b.sizeDynamics);
    out.flowDynamics = toC(b.flowDynamics);
    out.velocityReference = b.velocityReference;
    out.sizeJitter = b.sizeJitter;
    out.angleJitter = b.angleJitter;
    out.scatter = b.scatter;
    out.flowJitter = b.flowJitter;
    out.taperLength = b.taperLength;
    out.taperStartScale = b.taperStartScale;
    out.taperEndScale = b.taperEndScale;
    out.smoothing = b.smoothing;
    out.minimumSizeFraction = b.minimumSizeFraction;
    return out;
}

}  // namespace

extern "C" {

MCBrush mc_brush_ink_pen(void) {
    return toC(inkPen());
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
                          double timestamp) {
    if (path == nullptr) return;
    StrokeSample sample;
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

}  // extern "C"
