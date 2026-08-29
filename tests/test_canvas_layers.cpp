#include "check.h"

#include "core/canvas_api.h"

#include <cstring>
#include <string>
#include <vector>

namespace {

std::vector<uint8_t> solidTile(uint8_t value) {
    const size_t bytes = static_cast<size_t>(mc_tile_size()) * mc_tile_size() * 4;
    return std::vector<uint8_t>(bytes, value);
}

void testStartsWithOneLayer() {
    std::printf("starts with one layer\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    CHECK_EQ(mc_canvas_layer_count(canvas), 1);
    CHECK(mc_canvas_active_layer(canvas) != MC_INVALID_LAYER);
    CHECK_EQ(mc_canvas_layer_index(canvas, mc_canvas_active_layer(canvas)), 0);
    mc_canvas_destroy(canvas);
}

void testAddInsertsAboveTheActiveLayer() {
    std::printf("add inserts above the active layer\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId first = mc_canvas_active_layer(canvas);
    const MCLayerId second = mc_canvas_add_layer(canvas, "Second");
    const MCLayerId third = mc_canvas_add_layer(canvas, "Third");

    CHECK_EQ(mc_canvas_layer_count(canvas), 3);
    CHECK_EQ(mc_canvas_layer_at(canvas, 0), first);
    CHECK_EQ(mc_canvas_layer_at(canvas, 1), second);
    CHECK_EQ(mc_canvas_layer_at(canvas, 2), third);
    CHECK_EQ(mc_canvas_active_layer(canvas), third);

    // Selecting mid-stack and adding puts the new layer directly above it,
    // which is where someone reaches for it rather than at the very top.
    mc_canvas_set_active_layer(canvas, first);
    const MCLayerId inserted = mc_canvas_add_layer(canvas, "Inserted");
    CHECK_EQ(mc_canvas_layer_index(canvas, inserted), 1);
    CHECK_EQ(mc_canvas_layer_count(canvas), 4);

    mc_canvas_destroy(canvas);
}

void testCannotRemoveTheLastLayer() {
    std::printf("cannot remove the last layer\n");

    // Otherwise the active layer goes invalid and the next stroke has nowhere
    // to land — a crash or a silent no-op, neither of which is acceptable.
    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId only = mc_canvas_active_layer(canvas);
    CHECK_EQ(mc_canvas_remove_layer(canvas, only), 0);
    CHECK_EQ(mc_canvas_layer_count(canvas), 1);

    const MCLayerId second = mc_canvas_add_layer(canvas, "Second");
    CHECK_EQ(mc_canvas_remove_layer(canvas, second), 1);
    CHECK_EQ(mc_canvas_layer_count(canvas), 1);
    CHECK_EQ(mc_canvas_active_layer(canvas), only);

    mc_canvas_destroy(canvas);
}

void testLayerInfoRoundTrip() {
    std::printf("layer info round trip\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId layer = mc_canvas_active_layer(canvas);

    MCLayerInfo info;
    CHECK_EQ(mc_canvas_layer_info(canvas, layer, &info), 1);
    CHECK_EQ(info.opacity, 1.0f);
    CHECK_EQ(info.blend, 0);
    CHECK_EQ(info.visible, 1);
    CHECK_EQ(info.clipToBelow, 0);

    info.opacity = 0.5f;
    info.blend = 1;              // Multiply
    info.visible = 0;
    info.clipToBelow = 1;
    CHECK_EQ(mc_canvas_set_layer_info(canvas, layer, &info), 1);

    MCLayerInfo readBack;
    mc_canvas_layer_info(canvas, layer, &readBack);
    CHECK_EQ(readBack.opacity, 0.5f);
    CHECK_EQ(readBack.blend, 1);
    CHECK_EQ(readBack.visible, 0);
    CHECK_EQ(readBack.clipToBelow, 1);

    // Values from the shell cannot be trusted to be in range.
    info.opacity = 5.0f;
    info.blend = 9999;
    mc_canvas_set_layer_info(canvas, layer, &info);
    mc_canvas_layer_info(canvas, layer, &readBack);
    CHECK_EQ(readBack.opacity, 1.0f);
    CHECK_EQ(readBack.blend, 0);   // out-of-range falls back to Normal

    CHECK_EQ(mc_canvas_layer_info(canvas, MC_INVALID_LAYER, &readBack), 0);
    mc_canvas_destroy(canvas);
}

void testLayerNames() {
    std::printf("layer names\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId layer = mc_canvas_active_layer(canvas);

    char buffer[64];
    CHECK(mc_canvas_layer_name(canvas, layer, buffer, sizeof(buffer)) > 0);
    CHECK(std::string(buffer) == "Layer 1");

    CHECK_EQ(mc_canvas_set_layer_name(canvas, layer, "Line art"), 1);
    mc_canvas_layer_name(canvas, layer, buffer, sizeof(buffer));
    CHECK(std::string(buffer) == "Line art");

    // A short buffer must truncate and stay terminated rather than overrun.
    char tiny[5];
    const int32_t written = mc_canvas_layer_name(canvas, layer, tiny, sizeof(tiny));
    CHECK_EQ(written, 4);
    CHECK(std::string(tiny) == "Line");

    mc_canvas_destroy(canvas);
}

void testLayersHoldSeparatePixels() {
    std::printf("layers hold separate pixels\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId lower = mc_canvas_active_layer(canvas);
    const MCLayerId upper = mc_canvas_add_layer(canvas, "Upper");

    const auto lowerInk = solidTile(0x30);
    const auto upperInk = solidTile(0xC0);

    mc_canvas_begin_stroke(canvas, "Stroke");
    mc_canvas_store_tile_in(canvas, lower, 0, 0, lowerInk.data());
    mc_canvas_store_tile_in(canvas, upper, 0, 0, upperInk.data());
    mc_canvas_commit_stroke(canvas);

    auto out = solidTile(0);
    CHECK_EQ(mc_canvas_load_tile_from(canvas, lower, 0, 0, out.data()), 1);
    CHECK(out == lowerInk);
    CHECK_EQ(mc_canvas_load_tile_from(canvas, upper, 0, 0, out.data()), 1);
    CHECK(out == upperInk);

    // The unqualified calls act on whichever layer is selected.
    mc_canvas_set_active_layer(canvas, lower);
    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 1);
    CHECK(out == lowerInk);

    mc_canvas_destroy(canvas);
}

void testCompositePlanThroughTheAbi() {
    std::printf("composite plan through the ABI\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId bottom = mc_canvas_active_layer(canvas);
    const MCLayerId middle = mc_canvas_add_layer(canvas, "Middle");
    const MCLayerId top = mc_canvas_add_layer(canvas, "Top");
    mc_canvas_set_active_layer(canvas, middle);

    MCCompositePlan plan;
    mc_canvas_refresh_plan(canvas, &plan);

    CHECK_EQ(plan.underCount, 1);
    CHECK_EQ(plan.liveCount, 1);
    CHECK_EQ(plan.overCount, 1);
    CHECK_EQ(plan.activeLayer, middle);
    CHECK_EQ(mc_canvas_plan_layer(canvas, MCCompositeSectionUnder, 0), bottom);
    CHECK_EQ(mc_canvas_plan_layer(canvas, MCCompositeSectionLive, 0), middle);
    CHECK_EQ(mc_canvas_plan_layer(canvas, MCCompositeSectionOver, 0), top);

    // Out-of-range requests must be answerable rather than undefined.
    CHECK_EQ(mc_canvas_plan_layer(canvas, MCCompositeSectionUnder, 99), MC_INVALID_LAYER);
    CHECK_EQ(mc_canvas_plan_layer(canvas, 42, 0), MC_INVALID_LAYER);

    mc_canvas_destroy(canvas);
}

void testClipGroupStaysLiveThroughTheAbi() {
    std::printf("clip group stays live through the ABI\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const MCLayerId base = mc_canvas_active_layer(canvas);
    const MCLayerId flats = mc_canvas_add_layer(canvas, "Flats");

    MCLayerInfo info;
    mc_canvas_layer_info(canvas, flats, &info);
    info.clipToBelow = 1;
    mc_canvas_set_layer_info(canvas, flats, &info);

    mc_canvas_set_active_layer(canvas, base);

    MCCompositePlan plan;
    mc_canvas_refresh_plan(canvas, &plan);

    // Painting the base changes everything clipped onto it, so the clipped
    // layer cannot be flattened into the over cache.
    CHECK_EQ(plan.liveCount, 2);
    CHECK_EQ(plan.overCount, 0);
    CHECK_EQ(mc_canvas_plan_layer(canvas, MCCompositeSectionLive, 0), base);
    CHECK_EQ(mc_canvas_plan_layer(canvas, MCCompositeSectionLive, 1), flats);

    mc_canvas_destroy(canvas);
}

void testCachesSurviveAStroke() {
    std::printf("caches survive a stroke through the ABI\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    mc_canvas_add_layer(canvas, "Middle");
    const MCLayerId active = mc_canvas_active_layer(canvas);
    mc_canvas_add_layer(canvas, "Top");
    mc_canvas_set_active_layer(canvas, active);

    MCCompositePlan plan;
    mc_canvas_refresh_plan(canvas, &plan);   // first frame builds both
    mc_canvas_refresh_plan(canvas, &plan);
    CHECK_EQ(plan.underDirty, 0);
    CHECK_EQ(plan.overDirty, 0);

    MCCanvasStats before;
    mc_canvas_stats(canvas, &before);

    const auto ink = solidTile(0x80);
    for (int32_t frame = 0; frame < 30; ++frame) {
        mc_canvas_begin_stroke(canvas, "Stroke");
        mc_canvas_store_tile(canvas, frame, 0, ink.data());
        mc_canvas_commit_stroke(canvas);

        mc_canvas_refresh_plan(canvas, &plan);
        CHECK_EQ(plan.underDirty, 0);
        CHECK_EQ(plan.overDirty, 0);
    }

    MCCanvasStats after;
    mc_canvas_stats(canvas, &after);
    CHECK_EQ(after.underCacheRebuilds, before.underCacheRebuilds);
    CHECK_EQ(after.overCacheRebuilds, before.overCacheRebuilds);
    std::printf("  30 painted frames, 0 cache rebuilds through the ABI\n");

    // Selecting a different layer moves the split, so both caches go stale.
    mc_canvas_set_active_layer(canvas, mc_canvas_layer_at(canvas, 0));
    mc_canvas_refresh_plan(canvas, &plan);
    CHECK_EQ(plan.underDirty, 1);
    CHECK_EQ(plan.overDirty, 1);

    mc_canvas_destroy(canvas);
}

void testNullSafety() {
    std::printf("null safety\n");

    CHECK_EQ(mc_canvas_layer_count(nullptr), 0);
    CHECK_EQ(mc_canvas_layer_at(nullptr, 0), MC_INVALID_LAYER);
    CHECK_EQ(mc_canvas_add_layer(nullptr, "x"), MC_INVALID_LAYER);
    CHECK_EQ(mc_canvas_remove_layer(nullptr, 1), 0);
    CHECK_EQ(mc_canvas_set_active_layer(nullptr, 1), 0);
    CHECK_EQ(mc_canvas_layer_info(nullptr, 1, nullptr), 0);
    CHECK_EQ(mc_canvas_layer_name(nullptr, 1, nullptr, 0), 0);
    mc_canvas_invalidate_caches(nullptr);

    MCCompositePlan plan;
    mc_canvas_refresh_plan(nullptr, &plan);
    CHECK_EQ(plan.underCount, 0);
    CHECK_EQ(plan.activeLayer, MC_INVALID_LAYER);
}

} // namespace

int main() {
    testStartsWithOneLayer();
    testAddInsertsAboveTheActiveLayer();
    testCannotRemoveTheLastLayer();
    testLayerInfoRoundTrip();
    testLayerNames();
    testLayersHoldSeparatePixels();
    testCompositePlanThroughTheAbi();
    testClipGroupStaysLiveThroughTheAbi();
    testCachesSurviveAStroke();
    testNullSafety();
    return check::report("canvas_layers");
}
