#include "check.h"

#include "core/canvas_api.h"

#include <cstring>
#include <vector>

namespace {

std::vector<uint8_t> solidTile(uint8_t value) {
    const size_t bytes = static_cast<size_t>(mc_tile_size()) * mc_tile_size() * 4;
    return std::vector<uint8_t>(bytes, value);
}

void testStoreAndLoad() {
    std::printf("store and load\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    CHECK(canvas != nullptr);

    std::vector<uint8_t> out(solidTile(0));
    // Never painted: the caller's buffer must be left alone so it can skip
    // the upload entirely.
    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 0);

    const auto red = solidTile(200);
    mc_canvas_begin_stroke(canvas, "Stroke");
    mc_canvas_store_tile(canvas, 0, 0, red.data());
    mc_canvas_commit_stroke(canvas);

    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 1);
    CHECK(out == red);

    mc_canvas_destroy(canvas);
}

void testUndoReportsChangedTiles() {
    std::printf("undo reports changed tiles\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const auto a = solidTile(10);
    const auto b = solidTile(20);

    mc_canvas_begin_stroke(canvas, "First");
    mc_canvas_store_tile(canvas, 0, 0, a.data());
    mc_canvas_store_tile(canvas, 1, 0, a.data());
    mc_canvas_commit_stroke(canvas);

    mc_canvas_begin_stroke(canvas, "Second");
    mc_canvas_store_tile(canvas, 0, 0, b.data());
    mc_canvas_commit_stroke(canvas);

    CHECK_EQ(mc_canvas_can_undo(canvas), 1);
    CHECK_EQ(mc_canvas_undo(canvas), 1);

    // Only the tile the second stroke touched needs re-uploading. Reporting
    // everything would make undo cost scale with document size.
    CHECK_EQ(mc_canvas_changed_tile_count(canvas), 1);
    int32_t tx = -99, ty = -99;
    mc_canvas_changed_tile_at(canvas, 0, &tx, &ty);
    CHECK_EQ(tx, 0);
    CHECK_EQ(ty, 0);

    std::vector<uint8_t> out(solidTile(0));
    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 1);
    CHECK(out == a);

    CHECK_EQ(mc_canvas_redo(canvas), 1);
    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 1);
    CHECK(out == b);

    mc_canvas_destroy(canvas);
}

void testClearIsUndoable() {
    std::printf("clear is undoable\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const auto ink = solidTile(77);

    mc_canvas_begin_stroke(canvas, "Stroke");
    mc_canvas_store_tile(canvas, 0, 0, ink.data());
    mc_canvas_store_tile(canvas, 3, 2, ink.data());
    mc_canvas_commit_stroke(canvas);

    mc_canvas_clear(canvas);

    std::vector<uint8_t> out(solidTile(0));
    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 0);
    CHECK_EQ(mc_canvas_changed_tile_count(canvas), 2);

    // Clearing by accident must be recoverable.
    CHECK_EQ(mc_canvas_undo(canvas), 1);
    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 1);
    CHECK(out == ink);
    CHECK_EQ(mc_canvas_load_tile(canvas, 3, 2, out.data()), 1);

    mc_canvas_destroy(canvas);
}

void testAbortDiscardsStroke() {
    std::printf("abort discards stroke\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const auto ink = solidTile(5);

    mc_canvas_begin_stroke(canvas, "Cancelled");
    mc_canvas_store_tile(canvas, 0, 0, ink.data());
    mc_canvas_abort_stroke(canvas);

    // The pixels stay — abort drops the history entry, not the paint. The
    // shell is responsible for not having drawn them in the first place.
    CHECK_EQ(mc_canvas_can_undo(canvas), 0);

    mc_canvas_destroy(canvas);
}

void testStatsReflectResidency() {
    std::printf("stats reflect residency\n");

    MCCanvas* canvas = mc_canvas_create(nullptr);
    const size_t tileBytes = static_cast<size_t>(mc_tile_size()) * mc_tile_size() * 4;
    const auto ink = solidTile(1);

    mc_canvas_begin_stroke(canvas, "Stroke");
    for (int32_t i = 0; i < 12; ++i) {
        mc_canvas_store_tile(canvas, i, 0, ink.data());
    }
    mc_canvas_commit_stroke(canvas);

    MCCanvasStats stats;
    mc_canvas_stats(canvas, &stats);
    CHECK_EQ(stats.liveTiles, 12);
    CHECK_EQ(stats.undoDepth, 1);

    mc_canvas_set_budgets(canvas, 4 * tileBytes, 0);
    mc_canvas_evict(canvas);

    mc_canvas_stats(canvas, &stats);
    CHECK(stats.residentBytes <= 4 * tileBytes);
    CHECK(stats.compressedTiles > 0);
    CHECK_EQ(stats.liveTiles, 12);

    // Still readable after eviction.
    std::vector<uint8_t> out(solidTile(0));
    CHECK_EQ(mc_canvas_load_tile(canvas, 0, 0, out.data()), 1);
    CHECK(out == ink);

    mc_canvas_destroy(canvas);
}

void testNullHandlesAreSafe() {
    std::printf("null handles are safe\n");

    // The shell owns these pointers, so nothing here may assume validity.
    mc_canvas_destroy(nullptr);
    mc_canvas_begin_stroke(nullptr, "x");
    mc_canvas_store_tile(nullptr, 0, 0, nullptr);
    mc_canvas_commit_stroke(nullptr);
    mc_canvas_clear(nullptr);
    mc_canvas_evict(nullptr);
    CHECK_EQ(mc_canvas_undo(nullptr), 0);
    CHECK_EQ(mc_canvas_redo(nullptr), 0);
    CHECK_EQ(mc_canvas_changed_tile_count(nullptr), 0);
    CHECK_EQ(mc_canvas_load_tile(nullptr, 0, 0, nullptr), 0);

    MCCanvasStats stats;
    mc_canvas_stats(nullptr, &stats);
    CHECK_EQ(stats.liveTiles, 0);
}

} // namespace

int main() {
    testStoreAndLoad();
    testUndoReportsChangedTiles();
    testClearIsUndoable();
    testAbortDiscardsStroke();
    testStatsReflectResidency();
    testNullHandlesAreSafe();
    return check::report("canvas_api");
}
