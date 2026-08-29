#include "core/canvas_api.h"

#include "core/layer.h"
#include "core/layer_stack.h"
#include "core/tile.h"
#include "core/tile_store.h"
#include "core/undo.h"

#include <cstring>
#include <string>
#include <vector>

using namespace mc;

struct MCCanvas {
    TileStore store;
    LayerStack layers;
    UndoStack undo;

    /// Tiles the shell needs to re-upload after the last history operation.
    std::vector<TileCoord> changed;

    /// Counts edits made with no action open. See MCCanvasStats.
    uint64_t storesOutsideAction = 0;

    MCCanvas() : store(0), layers(store), undo(store, layers) {
        // A drawing always has at least one layer. The C ABI is still
        // single-layer; the stack is here so that history, which addresses
        // layers by id, is already correct when layer controls arrive.
        layers.add("Layer 1");
    }

    Layer* active() { return layers.pixels(layers.active()); }
};

namespace {

/// Every entry point takes a handle from the shell, so none of them can assume
/// it is valid.
inline bool ok(const MCCanvas* canvas) { return canvas != nullptr; }

} // namespace

int32_t mc_tile_size(void) {
    return kTileSize;
}

MCCanvas* mc_canvas_create(const char* scratchPath) {
    auto* canvas = new (std::nothrow) MCCanvas();
    if (canvas == nullptr) return nullptr;

    if (scratchPath != nullptr && scratchPath[0] != '\0') {
        // Failing to open the scratch file is not fatal: the canvas simply
        // keeps everything in RAM. Refusing to start would be a far worse
        // outcome than using more memory.
        canvas->store.enableSpilling(std::string(scratchPath));
    }
    return canvas;
}

void mc_canvas_destroy(MCCanvas* canvas) {
    delete canvas;
}

void mc_canvas_set_budgets(MCCanvas* canvas, uint64_t residentBytes, uint64_t compressedBytes) {
    if (!ok(canvas)) return;
    canvas->store.setResidentBudget(static_cast<size_t>(residentBytes));
    canvas->store.setCompressedBudget(static_cast<size_t>(compressedBytes));
}

void mc_canvas_evict(MCCanvas* canvas) {
    if (!ok(canvas)) return;
    canvas->store.evictToBudget();
}

// MARK: - Editing

void mc_canvas_begin_stroke(MCCanvas* canvas, const char* name) {
    if (!ok(canvas)) return;
    canvas->undo.beginAction(name != nullptr ? std::string(name) : std::string("Stroke"));
}

void mc_canvas_store_tile(MCCanvas* canvas, int32_t tx, int32_t ty, const uint8_t* rgba) {
    if (!ok(canvas) || rgba == nullptr) return;

    const TileCoord coord{tx, ty};

    // Writing outside an action is almost always a caller bug, and a silent
    // one: the paint lands correctly and only undo misbehaves. Count it so it
    // can be seen rather than deduced.
    if (!canvas->undo.isRecording()) {
        ++canvas->storesOutsideAction;
    }

    // Order matters: capture history before the tile is separated by writeTile,
    // or undo would record the pixels we are about to overwrite.
    canvas->undo.willModify(canvas->layers.active(), coord);

    Layer* layer = canvas->active();
    if (layer == nullptr) return;

    uint8_t* destination = layer->writeTile(coord);
    if (destination != nullptr) {
        std::memcpy(destination, rgba, kTileBytes);
    }
}

void mc_canvas_commit_stroke(MCCanvas* canvas) {
    if (!ok(canvas)) return;
    canvas->undo.commitAction();
}

void mc_canvas_abort_stroke(MCCanvas* canvas) {
    if (!ok(canvas)) return;
    canvas->undo.abortAction();
}

int32_t mc_canvas_load_tile(MCCanvas* canvas, int32_t tx, int32_t ty, uint8_t* rgba) {
    if (!ok(canvas) || rgba == nullptr) return 0;

    const Layer* layer = canvas->active();
    if (layer == nullptr) return 0;

    const uint8_t* source = layer->readTile(TileCoord{tx, ty});
    if (source == nullptr) {
        // Never painted. Leaving the caller's buffer alone lets it skip the
        // upload entirely rather than pushing a tile of transparent pixels.
        return 0;
    }
    std::memcpy(rgba, source, kTileBytes);
    return 1;
}

void mc_canvas_clear(MCCanvas* canvas) {
    if (!ok(canvas)) return;

    Layer* layer = canvas->active();
    if (layer == nullptr) return;

    // Clearing is undoable like anything else. Collect the coordinates first,
    // because dropping tiles mutates the map being iterated.
    std::vector<TileCoord> coords;
    coords.reserve(layer->tileCount());
    for (const auto& [coord, id] : layer->tiles()) {
        coords.push_back(coord);
    }

    canvas->undo.beginAction("Clear");
    for (const TileCoord& coord : coords) {
        canvas->undo.willModify(canvas->layers.active(), coord);
        layer->dropTile(coord);
    }
    canvas->undo.commitAction();

    canvas->changed = std::move(coords);
}

// MARK: - History

int32_t mc_canvas_can_undo(MCCanvas* canvas) {
    return ok(canvas) && canvas->undo.canUndo() ? 1 : 0;
}

int32_t mc_canvas_can_redo(MCCanvas* canvas) {
    return ok(canvas) && canvas->undo.canRedo() ? 1 : 0;
}

int32_t mc_canvas_undo(MCCanvas* canvas) {
    if (!ok(canvas)) return 0;
    if (!canvas->undo.undo()) return 0;
    canvas->changed = canvas->undo.lastAffectedTiles();
    return 1;
}

int32_t mc_canvas_redo(MCCanvas* canvas) {
    if (!ok(canvas)) return 0;
    if (!canvas->undo.redo()) return 0;
    canvas->changed = canvas->undo.lastAffectedTiles();
    return 1;
}

int32_t mc_canvas_changed_tile_count(MCCanvas* canvas) {
    return ok(canvas) ? static_cast<int32_t>(canvas->changed.size()) : 0;
}

void mc_canvas_changed_tile_at(MCCanvas* canvas, int32_t index, int32_t* tx, int32_t* ty) {
    if (!ok(canvas) || tx == nullptr || ty == nullptr) return;
    if (index < 0 || static_cast<size_t>(index) >= canvas->changed.size()) return;
    *tx = canvas->changed[static_cast<size_t>(index)].x;
    *ty = canvas->changed[static_cast<size_t>(index)].y;
}

// MARK: - Instrumentation

void mc_canvas_stats(MCCanvas* canvas, MCCanvasStats* out) {
    if (out == nullptr) return;
    std::memset(out, 0, sizeof(*out));
    if (!ok(canvas)) return;

    const TileStore& store = canvas->store;
    out->liveTiles = store.liveTileCount();
    out->residentTiles = store.residentTileCount();
    out->compressedTiles = store.compressedTileCount();
    out->spilledTiles = store.spilledTileCount();
    out->residentBytes = store.residentBytes();
    out->compressedBytes = store.compressedBytes();
    out->spillFileBytes = store.spillFileBytes();
    out->decompressions = store.decompressionCount();
    out->spillReads = store.spillReadCount();
    out->undoDepth = canvas->undo.undoDepth();
    out->redoDepth = canvas->undo.redoDepth();
    out->historyTiles = canvas->undo.retainedTileCount();
    out->storesOutsideAction = canvas->storesOutsideAction;
}
