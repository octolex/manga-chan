#pragma once

//
//  quickshape.h — draw, hold, and the stroke snaps to the shape it meant.
//
//  Procreate's QuickShape: finish a stroke and keep the pen down, and after a
//  moment the line becomes a clean line, arc, ellipse or polygon. Rest a
//  finger on the canvas while holding and the shape is constrained — the line
//  to 15° steps, the ellipse to a circle. For manga inking this is the most
//  used of Procreate's gestures: panel borders, speed lines, eyes, word
//  balloons.
//
//  What lives here is the part that can be wrong in ways a test can see:
//  deciding which shape a hand-drawn path is, fitting it, and walking the
//  fitted shape back out as samples. The shell only decides *when* — the hold
//  — and hands the samples to an ordinary stroke, so the shape is drawn by the
//  same brush, dab for dab, as anything else.
//
//  The thresholds are ours, not measured against Procreate. They are chosen to
//  refuse rather than guess: a stroke that is not clearly a shape stays the
//  stroke that was drawn.
//

#include "core/stroke_sample.h"

#include <cstdint>
#include <vector>

namespace mc {

enum class ShapeKind : int32_t {
    None = 0,
    Line = 1,
    Arc = 2,
    Ellipse = 3,
    Polyline = 4,
};

struct QuickShape {
    static constexpr int kMaxVertices = 16;

    ShapeKind kind = ShapeKind::None;
    bool closed = false;

    /// Line: two vertices, start and end. Polyline: its corners, in order.
    int32_t vertexCount = 0;
    float vx[kMaxVertices] = {};
    float vy[kMaxVertices] = {};

    /// Ellipse: centre, radii along its own axes, and the rotation of the
    /// first axis. Arc: centre and radius (`rx`).
    float cx = 0.0f;
    float cy = 0.0f;
    float rx = 0.0f;
    float ry = 0.0f;
    float rotation = 0.0f;

    /// Arc: where it starts and how far it turns, radians, signed. Ellipse:
    /// `start` is where the hand began, so the seam lands there too.
    float start = 0.0f;
    float sweep = 0.0f;

    /// The stroke's mean pressure and tilt, so the shape is drawn at the
    /// weight the hand was drawing at rather than at an arbitrary one.
    float pressure = 1.0f;
    float tilt = 1.5707963f;
};

/// Decides which shape `samples` is, and fits it. `kind` is None when no
/// shape fits well enough — the stroke should then be left alone.
QuickShape detectShape(const std::vector<StrokeSample>& samples);

/// The constrained form: a line snaps to the nearest 15°, an ellipse becomes
/// the circle of the same mean radius. Other kinds are left as they are.
void constrainShape(QuickShape& shape);

/// While the pen is still held after the snap, a line's end follows it, as in
/// Procreate. Other kinds ignore this.
void moveShapeEnd(QuickShape& shape, float x, float y, bool constrained);

/// The shape walked out as samples about a pixel and a half apart, ready for
/// an ordinary stroke.
std::vector<StrokeSample> shapeSamples(const QuickShape& shape, double startTime,
                                       bool fromPressureDevice);

}  // namespace mc
