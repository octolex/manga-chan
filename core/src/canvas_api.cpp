#include "core/canvas_api.h"

#include "core/compositor.h"
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
    CompositeCache composite;

    /// Tiles the shell needs to re-upload after the last history operation.
    std::vector<TileCoord> changed;

    /// Counts edits made with no action open. See MCCanvasStats.
    uint64_t storesOutsideAction = 0;

    MCCanvas() : store(0), layers(store), undo(store, layers) {
        // A drawing always has somewhere to paint.
        layers.add("Layer 1");
    }

    Layer* active() { return layers.pixels(layers.active()); }
};

namespace {

/// Every entry point takes a handle from the shell, so none of them can assume
/// it is valid.
inline bool ok(const MCCanvas* canvas) { return canvas != nullptr; }

BlendMode toBlend(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(BlendMode::Count)) {
        return BlendMode::Normal;
    }
    return static_cast<BlendMode>(index);
}

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

// MARK: - Layers

int32_t mc_canvas_layer_count(MCCanvas* canvas) {
    return ok(canvas) ? static_cast<int32_t>(canvas->layers.count()) : 0;
}

MCLayerId mc_canvas_layer_at(MCCanvas* canvas, int32_t index) {
    if (!ok(canvas) || index < 0) return MC_INVALID_LAYER;
    return canvas->layers.at(static_cast<size_t>(index));
}

int32_t mc_canvas_layer_index(MCCanvas* canvas, MCLayerId layer) {
    return ok(canvas) ? canvas->layers.indexOf(layer) : -1;
}

MCLayerId mc_canvas_active_layer(MCCanvas* canvas) {
    return ok(canvas) ? canvas->layers.active() : MC_INVALID_LAYER;
}

int32_t mc_canvas_set_active_layer(MCCanvas* canvas, MCLayerId layer) {
    return ok(canvas) && canvas->layers.setActive(layer) ? 1 : 0;
}

MCLayerId mc_canvas_add_layer(MCCanvas* canvas, const char* name) {
    if (!ok(canvas)) return MC_INVALID_LAYER;
    const std::string label = name != nullptr ? std::string(name) : std::string("Layer");
    // Directly above the active layer, which is where someone adding a layer
    // mid-stack expects it rather than at the very top.
    const int active = canvas->layers.indexOf(canvas->layers.active());
    const size_t index = active < 0 ? canvas->layers.count()
                                    : static_cast<size_t>(active) + 1;
    return canvas->layers.insert(label, index);
}

MCLayerId mc_canvas_duplicate_layer(MCCanvas* canvas, MCLayerId layer) {
    return ok(canvas) ? canvas->layers.duplicate(layer) : MC_INVALID_LAYER;
}

int32_t mc_canvas_remove_layer(MCCanvas* canvas, MCLayerId layer) {
    if (!ok(canvas)) return 0;
    // A drawing always has somewhere to paint. Removing the last layer would
    // leave no active layer and the next stroke with nowhere to go.
    if (canvas->layers.count() <= 1) return 0;
    return canvas->layers.remove(layer) ? 1 : 0;
}

int32_t mc_canvas_move_layer(MCCanvas* canvas, MCLayerId layer, int32_t toIndex) {
    if (!ok(canvas) || toIndex < 0) return 0;
    return canvas->layers.move(layer, static_cast<size_t>(toIndex)) ? 1 : 0;
}

int32_t mc_canvas_layer_info(MCCanvas* canvas, MCLayerId layer, MCLayerInfo* out) {
    if (!ok(canvas) || out == nullptr) return 0;
    const LayerInfo* info = canvas->layers.info(layer);
    if (info == nullptr) return 0;

    out->opacity = info->opacity;
    out->blend = static_cast<int32_t>(info->blend);
    out->visible = info->visible ? 1 : 0;
    out->locked = info->locked ? 1 : 0;
    out->clipToBelow = info->clipToBelow ? 1 : 0;
    return 1;
}

int32_t mc_canvas_set_layer_info(MCCanvas* canvas, MCLayerId layer, const MCLayerInfo* incoming) {
    if (!ok(canvas) || incoming == nullptr) return 0;
    LayerInfo* info = canvas->layers.info(layer);
    if (info == nullptr) return 0;

    info->opacity = incoming->opacity < 0.0f ? 0.0f
                  : (incoming->opacity > 1.0f ? 1.0f : incoming->opacity);
    info->blend = toBlend(incoming->blend);
    info->visible = incoming->visible != 0;
    info->locked = incoming->locked != 0;
    info->clipToBelow = incoming->clipToBelow != 0;
    return 1;
}

int32_t mc_canvas_layer_name(MCCanvas* canvas, MCLayerId layer, char* buffer, int32_t capacity) {
    if (!ok(canvas) || buffer == nullptr || capacity <= 0) return 0;
    const LayerInfo* info = canvas->layers.info(layer);
    if (info == nullptr) {
        buffer[0] = '\0';
        return 0;
    }

    const size_t room = static_cast<size_t>(capacity) - 1;
    const size_t length = info->name.size() < room ? info->name.size() : room;
    std::memcpy(buffer, info->name.data(), length);
    buffer[length] = '\0';
    return static_cast<int32_t>(length);
}

int32_t mc_canvas_set_layer_name(MCCanvas* canvas, MCLayerId layer, const char* name) {
    if (!ok(canvas) || name == nullptr) return 0;
    LayerInfo* info = canvas->layers.info(layer);
    if (info == nullptr) return 0;
    info->name = name;
    return 1;
}

// MARK: - Editing

void mc_canvas_begin_stroke(MCCanvas* canvas, const char* name) {
    if (!ok(canvas)) return;
    canvas->undo.beginAction(name != nullptr ? std::string(name) : std::string("Stroke"));
}

void mc_canvas_store_tile_in(MCCanvas* canvas, MCLayerId layer,
                             int32_t tx, int32_t ty, const uint8_t* rgba) {
    if (!ok(canvas) || rgba == nullptr) return;

    Layer* pixels = canvas->layers.pixels(layer);
    if (pixels == nullptr) return;

    // Writing outside an action is almost always a caller bug, and a silent
    // one: the paint lands correctly and only undo misbehaves. Count it so it
    // can be seen rather than deduced.
    if (!canvas->undo.isRecording()) {
        ++canvas->storesOutsideAction;
    }

    const TileCoord coord{tx, ty};
    // Order matters: capture history before the tile is separated by writeTile,
    // or undo would record the pixels we are about to overwrite.
    canvas->undo.willModify(layer, coord);

    uint8_t* destination = pixels->writeTile(coord);
    if (destination != nullptr) {
        std::memcpy(destination, rgba, kTileBytes);
    }
}

void mc_canvas_store_tile(MCCanvas* canvas, int32_t tx, int32_t ty, const uint8_t* rgba) {
    if (!ok(canvas)) return;
    mc_canvas_store_tile_in(canvas, canvas->layers.active(), tx, ty, rgba);
}

void mc_canvas_commit_stroke(MCCanvas* canvas) {
    if (!ok(canvas)) return;
    canvas->undo.commitAction();
}

void mc_canvas_abort_stroke(MCCanvas* canvas) {
    if (!ok(canvas)) return;
    canvas->undo.abortAction();
}

int32_t mc_canvas_load_tile_from(MCCanvas* canvas, MCLayerId layer,
                                 int32_t tx, int32_t ty, uint8_t* rgba) {
    if (!ok(canvas) || rgba == nullptr) return 0;

    const Layer* pixels = canvas->layers.pixels(layer);
    if (pixels == nullptr) return 0;

    const uint8_t* source = pixels->readTile(TileCoord{tx, ty});
    if (source == nullptr) {
        // Never painted. Leaving the caller's buffer alone lets it skip the
        // upload entirely rather than pushing a tile of transparent pixels.
        return 0;
    }
    std::memcpy(rgba, source, kTileBytes);
    return 1;
}

int32_t mc_canvas_load_tile(MCCanvas* canvas, int32_t tx, int32_t ty, uint8_t* rgba) {
    if (!ok(canvas)) return 0;
    return mc_canvas_load_tile_from(canvas, canvas->layers.active(), tx, ty, rgba);
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

// MARK: - Composite plan

void mc_canvas_refresh_plan(MCCanvas* canvas, MCCompositePlan* out) {
    if (out == nullptr) return;
    std::memset(out, 0, sizeof(*out));
    if (!ok(canvas)) return;

    canvas->composite.refresh(canvas->layers);
    const CompositePlan& plan = canvas->composite.plan();

    out->underCount = static_cast<int32_t>(plan.under.size());
    out->liveCount = static_cast<int32_t>(plan.live.size());
    out->overCount = static_cast<int32_t>(plan.over.size());
    out->underDirty = canvas->composite.underDirty() ? 1 : 0;
    out->overDirty = canvas->composite.overDirty() ? 1 : 0;
    out->activeLayer = plan.activeLayer;
}

MCLayerId mc_canvas_plan_layer(MCCanvas* canvas, int32_t section, int32_t index) {
    if (!ok(canvas) || index < 0) return MC_INVALID_LAYER;
    const CompositePlan& plan = canvas->composite.plan();

    const std::vector<LayerId>* ids = nullptr;
    switch (section) {
    case MCCompositeSectionUnder: ids = &plan.under; break;
    case MCCompositeSectionLive:  ids = &plan.live;  break;
    case MCCompositeSectionOver:  ids = &plan.over;  break;
    default: return MC_INVALID_LAYER;
    }

    if (static_cast<size_t>(index) >= ids->size()) return MC_INVALID_LAYER;
    return (*ids)[static_cast<size_t>(index)];
}

void mc_canvas_invalidate_caches(MCCanvas* canvas) {
    if (!ok(canvas)) return;
    canvas->composite.invalidate();
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
    out->underCacheRebuilds = canvas->composite.underRebuildCount();
    out->overCacheRebuilds = canvas->composite.overRebuildCount();
}
