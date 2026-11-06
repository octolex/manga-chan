#include "check.h"

#include "core/brush.h"
#include "core/brush_api.h"
#include "core/canvas_api.h"
#include "core/quickshape.h"
#include "core/stroke.h"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace mc;

//
//  QuickShape fitting, and the eyedropper's composite sample — the two
//  Procreate gestures added on 2026-11-06 whose arithmetic can be wrong in
//  ways a test can see.
//

namespace {

constexpr float kPi = 3.14159265f;

float wobble(int i) {
    return 1.5f * std::sin(static_cast<float>(i) * 1.3f) + std::sin(static_cast<float>(i) * 0.37f);
}

std::vector<StrokeSample> traced(const std::vector<std::pair<float, float>>& points) {
    std::vector<StrokeSample> out;
    double t = 0.0;
    for (const auto& [x, y] : points) {
        StrokeSample s;
        s.x = x;
        s.y = y;
        s.pressure = 0.6f;
        s.timestamp = t;
        t += 1.0 / 240.0;
        out.push_back(s);
    }
    return out;
}

std::vector<StrokeSample> wobblyLine(float x0, float y0, float x1, float y1, int n) {
    std::vector<std::pair<float, float>> pts;
    const float len = std::hypot(x1 - x0, y1 - y0);
    const float nx = -(y1 - y0) / len, ny = (x1 - x0) / len;
    for (int i = 0; i < n; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(n - 1);
        const float w = wobble(i);
        pts.emplace_back(x0 + (x1 - x0) * t + nx * w, y0 + (y1 - y0) * t + ny * w);
    }
    return traced(pts);
}

std::vector<StrokeSample> wobblyEllipse(float cx, float cy, float a, float b, float rot,
                                        float turns, int n) {
    std::vector<std::pair<float, float>> pts;
    for (int i = 0; i < n; ++i) {
        const float t = turns * 2.0f * kPi * static_cast<float>(i) / static_cast<float>(n - 1);
        const float u = (a + wobble(i)) * std::cos(t);
        const float v = (b + wobble(i + 7)) * std::sin(t);
        pts.emplace_back(cx + u * std::cos(rot) - v * std::sin(rot),
                         cy + u * std::sin(rot) + v * std::cos(rot));
    }
    return traced(pts);
}

void testLine() {
    std::printf("a wobbly straight stroke is a line, from where it began to where it ended\n");
    const QuickShape s = detectShape(wobblyLine(100, 100, 500, 300, 200));
    CHECK(s.kind == ShapeKind::Line);
    CHECK(std::fabs(s.vx[0] - 100.0f) < 3.0f && std::fabs(s.vy[1] - 300.0f) < 3.0f);
    CHECK(std::fabs(s.pressure - 0.6f) < 1e-4f);
}

void testEllipse() {
    std::printf("a closed oval is an ellipse with the right axes\n");
    const QuickShape s = detectShape(wobblyEllipse(400, 300, 200, 100, 0.4f, 1.0f, 400));
    CHECK(s.kind == ShapeKind::Ellipse);
    const float major = std::max(s.rx, s.ry), minor = std::min(s.rx, s.ry);
    std::printf("    axes %.1f x %.1f, centre (%.1f, %.1f)\n", major, minor, s.cx, s.cy);
    CHECK(std::fabs(major - 200.0f) < 8.0f);
    CHECK(std::fabs(minor - 100.0f) < 8.0f);
    CHECK(std::fabs(s.cx - 400.0f) < 5.0f && std::fabs(s.cy - 300.0f) < 5.0f);
}

void testArc() {
    std::printf("an open curve of constant radius is an arc\n");
    std::vector<std::pair<float, float>> pts;
    for (int i = 0; i < 200; ++i) {
        const float t = 0.2f + 1.8f * static_cast<float>(i) / 199.0f;   // about 103 degrees
        pts.emplace_back(300.0f + (150.0f + wobble(i)) * std::cos(t),
                         300.0f + (150.0f + wobble(i)) * std::sin(t));
    }
    const QuickShape s = detectShape(traced(pts));
    CHECK(s.kind == ShapeKind::Arc);
    CHECK(std::fabs(s.rx - 150.0f) < 6.0f);
    CHECK(std::fabs(std::fabs(s.sweep) - 1.8f) < 0.1f);
}

void testRectangle() {
    std::printf("a closed four-cornered path is a four-vertex polygon\n");
    std::vector<std::pair<float, float>> pts;
    auto edge = [&](float x0, float y0, float x1, float y1) {
        for (int i = 0; i < 60; ++i) {
            const float t = static_cast<float>(i) / 60.0f;
            pts.emplace_back(x0 + (x1 - x0) * t + 0.6f * wobble(i), y0 + (y1 - y0) * t);
        }
    };
    edge(100, 100, 400, 100);
    edge(400, 100, 400, 300);
    edge(400, 300, 100, 300);
    edge(100, 300, 100, 104);
    const QuickShape s = detectShape(traced(pts));
    CHECK(s.kind == ShapeKind::Polyline);
    CHECK(s.closed);
    CHECK_EQ(s.vertexCount, 4);
}

void testScribbleIsLeftAlone() {
    std::printf("a scribble is not a shape, and stays the stroke that was drawn\n");
    std::vector<std::pair<float, float>> pts;
    for (int i = 0; i < 300; ++i) {
        const float t = static_cast<float>(i) * 0.08f;
        pts.emplace_back(200.0f + 80.0f * std::sin(t * 2.3f) + 30.0f * std::sin(t * 7.1f),
                         200.0f + 60.0f * std::cos(t * 1.7f));
    }
    CHECK(detectShape(traced(pts)).kind == ShapeKind::None);
    // And a line drawn back over itself is not a line.
    std::vector<std::pair<float, float>> back;
    for (int i = 0; i <= 100; ++i) back.emplace_back(100.0f + 3.0f * i, 100.0f);
    for (int i = 100; i >= 0; --i) back.emplace_back(100.0f + 3.0f * i, 102.0f);
    CHECK(detectShape(traced(back)).kind != ShapeKind::Line);
    // Too small to be anything.
    CHECK(detectShape(wobblyLine(10, 10, 15, 12, 10)).kind == ShapeKind::None);
}

void testConstrain() {
    std::printf("constrained: lines to 15 degrees, ellipses to circles\n");
    QuickShape line = detectShape(wobblyLine(100, 100, 500, 130, 200));
    CHECK(line.kind == ShapeKind::Line);
    constrainShape(line);
    CHECK(std::fabs(line.vy[1] - line.vy[0]) < 0.01f);   // ~4 degrees snaps flat

    moveShapeEnd(line, 300.0f, 310.0f, true);   // ~45 degrees from (100,100)
    const float angle = std::atan2(line.vy[1] - line.vy[0], line.vx[1] - line.vx[0]);
    CHECK(std::fabs(angle - kPi / 4.0f) < 1e-3f);

    QuickShape oval = detectShape(wobblyEllipse(400, 300, 200, 100, 0.0f, 1.0f, 400));
    constrainShape(oval);
    CHECK(oval.rx == oval.ry);
}

void testShapeSamplesDrawTheShape() {
    std::printf("a fitted shape walks out as dense samples on the shape\n");
    QuickShape circle;
    circle.kind = ShapeKind::Ellipse;
    circle.closed = true;
    circle.cx = 200; circle.cy = 200; circle.rx = circle.ry = 50;
    const auto samples = shapeSamples(circle, 1.0, true);
    CHECK(samples.size() > 200);   // circumference 314 px at 1.5 px
    float worst = 0.0f;
    for (const auto& s : samples) {
        worst = std::max(worst, std::fabs(std::hypot(s.x - 200.0f, s.y - 200.0f) - 50.0f));
    }
    CHECK(worst < 1e-3f);
    CHECK(samples.back().timestamp > samples.front().timestamp);

    // Through the ABI: the stroke it builds is unfinished, unsmoothed, and
    // draws on the circle.
    MCBrush brush = mc_brush_ink_pen();   // StreamLine 35% — must not apply
    MCQuickShape shape{};
    shape.kind = MC_SHAPE_ELLIPSE;
    shape.closed = 1;
    shape.cx = 200; shape.cy = 200; shape.rx = shape.ry = 50;
    shape.pressure = 1.0f;
    shape.tilt = 1.57f;
    MCStrokePath* path = mc_quickshape_stroke(&shape, &brush, 7, 0.0, 1);
    mc_stroke_finish(path);
    const MCDab* dabs = mc_stroke_dabs(path);
    const size_t count = mc_stroke_dab_count(path);
    CHECK(count > 100);
    float dabWorst = 0.0f;
    for (size_t i = 0; i < count; ++i) {
        dabWorst = std::max(dabWorst, std::fabs(std::hypot(dabs[i].x - 200.0f, dabs[i].y - 200.0f) - 50.0f));
    }
    std::printf("    furthest dab from the circle: %.3f px\n", dabWorst);
    CHECK(dabWorst < 0.5f);
    mc_stroke_end(path);
}

void testDetectThroughTheAbi() {
    std::printf("detection through the ABI uses the stroke as drawn\n");
    MCBrush brush = mc_brush_ink_pen();
    MCStrokePath* path = mc_stroke_begin(&brush, 1);
    for (int i = 0; i < 120; ++i) {
        mc_stroke_add_sample(path, 100.0f + 3.0f * i, 200.0f + 0.5f * wobble(i), 0.5f,
                             1.2f, 0.0f, -1.0f, i / 240.0, 1);
    }
    MCQuickShape shape{};
    CHECK_EQ(mc_quickshape_detect(path, &shape), MC_SHAPE_LINE);
    mc_quickshape_move_end(&shape, 500.0f, 260.0f, 0);
    CHECK(shape.vx[1] == 500.0f && shape.vy[1] == 260.0f);
    mc_stroke_end(path);

    CHECK_EQ(mc_quickshape_detect(nullptr, &shape), MC_SHAPE_NONE);
}

// ---- Eyedropper -------------------------------------------------------------

std::vector<uint8_t> solidTile(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3) {
    const size_t pixels = static_cast<size_t>(mc_tile_size()) * mc_tile_size();
    std::vector<uint8_t> tile(pixels * 4);
    for (size_t i = 0; i < pixels; ++i) {
        tile[i * 4] = b0; tile[i * 4 + 1] = b1; tile[i * 4 + 2] = b2; tile[i * 4 + 3] = b3;
    }
    return tile;
}

void testEyedropperOnBlankCanvasIsWhite() {
    std::printf("eyedropper on an empty canvas reads the white paper\n");
    MCCanvas* canvas = mc_canvas_create(nullptr);
    uint8_t rgba[4] = {};
    mc_canvas_sample_composite(canvas, 10, 10, 1, rgba);
    CHECK(rgba[0] == 255 && rgba[1] == 255 && rgba[2] == 255 && rgba[3] == 255);
    mc_canvas_destroy(canvas);
}

void testEyedropperReadsBgraAsTheShellStoresIt() {
    std::printf("eyedropper swaps the shell's BGRA into RGB\n");
    MCCanvas* canvas = mc_canvas_create(nullptr);
    mc_canvas_begin_stroke(canvas, "fill");
    // Opaque pure red, as a bgra8Unorm texture lays it out: B G R A.
    const auto red = solidTile(0, 0, 255, 255);
    mc_canvas_store_tile_in(canvas, mc_canvas_active_layer(canvas), 0, 0, red.data());
    mc_canvas_commit_stroke(canvas);
    uint8_t rgba[4] = {};
    mc_canvas_sample_composite(canvas, 5, 5, 1, rgba);
    CHECK(rgba[0] == 255 && rgba[1] == 0 && rgba[2] == 0);
    // Outside the painted tile, still paper.
    mc_canvas_sample_composite(canvas, 300, 5, 1, rgba);
    CHECK(rgba[0] == 255 && rgba[1] == 255 && rgba[2] == 255);
    mc_canvas_destroy(canvas);
}

void testEyedropperHonoursOpacityAndVisibility() {
    std::printf("eyedropper follows layer opacity, visibility and order\n");
    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId bottom = mc_canvas_active_layer(canvas);
    const MCLayerId top = mc_canvas_add_layer(canvas, "Top");

    mc_canvas_begin_stroke(canvas, "fill");
    const auto black = solidTile(0, 0, 0, 255);
    mc_canvas_store_tile_in(canvas, top, 0, 0, black.data());
    mc_canvas_commit_stroke(canvas);

    MCLayerInfo info{};
    mc_canvas_layer_info(canvas, top, &info);
    info.opacity = 0.5f;
    mc_canvas_set_layer_info(canvas, top, &info);

    uint8_t rgba[4] = {};
    mc_canvas_sample_composite(canvas, 5, 5, 1, rgba);
    std::printf("    black at 50%% over white reads %d\n", rgba[0]);
    CHECK(rgba[0] >= 126 && rgba[0] <= 129);

    info.visible = 0;
    mc_canvas_set_layer_info(canvas, top, &info);
    mc_canvas_sample_composite(canvas, 5, 5, 1, rgba);
    CHECK(rgba[0] == 255);
    (void)bottom;
    mc_canvas_destroy(canvas);
}

}  // namespace

int main() {
    testLine();
    testEllipse();
    testArc();
    testRectangle();
    testScribbleIsLeftAlone();
    testConstrain();
    testShapeSamplesDrawTheShape();
    testDetectThroughTheAbi();
    testEyedropperOnBlankCanvasIsWhite();
    testEyedropperReadsBgraAsTheShellStoresIt();
    testEyedropperHonoursOpacityAndVisibility();
    return check::report("test_quickshape");
}
