/*
 * canvas_api.h — the drawing surface, exposed to the Swift shell.
 *
 * Same boundary rules as core_api.h: plain C, opaque handles, the core owns
 * its memory, errors are return codes.
 *
 * How the shell is expected to use this:
 *
 *   mc_canvas_begin_stroke(canvas, "Stroke");
 *   ... user draws; the GPU renders into its own texture ...
 *   for each tile the stroke touched:
 *       mc_canvas_store_tile(canvas, tx, ty, pixelsReadBackFromGPU);
 *   mc_canvas_commit_stroke(canvas);
 *
 * The GPU stays the fast path for painting. Tiles come back to the engine once
 * per stroke, not once per frame, which is what keeps undo and paging honest
 * without putting a readback in the frame loop.
 *
 * After undo or redo, ask which tiles changed and re-upload only those.
 * Re-uploading the whole canvas would work but would scale with document size
 * rather than with what actually changed.
 */
#ifndef CANVAS_API_H
#define CANVAS_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCCanvas MCCanvas;

/* Layer handle. Zero means "no layer". Stable across reordering and deletion,
 * unlike an index, which is why undo history can safely refer to one. */
typedef uint32_t MCLayerId;
#define MC_INVALID_LAYER 0u

/* Pixels per tile edge, so the shell can size its readbacks to match. */
int32_t mc_tile_size(void);

/*
 * `scratchPath` is where cold tiles are parked; pass NULL to keep everything
 * in RAM. On iOS this should live in the caches directory — it is rebuildable
 * and must not be backed up.
 */
MCCanvas* mc_canvas_create(const char* scratchPath);
void mc_canvas_destroy(MCCanvas* canvas);

/* Memory ceilings. 0 means unlimited. */
void mc_canvas_set_budgets(MCCanvas* canvas,
                           uint64_t residentBytes,
                           uint64_t compressedBytes);

/* Walks cold tiles down a tier. Call at a frame boundary, never mid-stroke. */
void mc_canvas_evict(MCCanvas* canvas);

/* MARK: - Layers */

int32_t mc_canvas_layer_count(MCCanvas* canvas);

/* Layer at a z-order position, 0 being the backmost. A layers panel displays
 * these in reverse. Returns MC_INVALID_LAYER when out of range. */
MCLayerId mc_canvas_layer_at(MCCanvas* canvas, int32_t index);

/* Position of a layer in z-order, or -1 if it is not in the stack. */
int32_t mc_canvas_layer_index(MCCanvas* canvas, MCLayerId layer);

MCLayerId mc_canvas_active_layer(MCCanvas* canvas);
int32_t mc_canvas_set_active_layer(MCCanvas* canvas, MCLayerId layer);

/* Adds an empty layer directly above the active one and selects it. */
MCLayerId mc_canvas_add_layer(MCCanvas* canvas, const char* name);

/* Shares tiles copy-on-write, so duplicating a fully painted layer costs
 * nothing until one of the two is edited. */
MCLayerId mc_canvas_duplicate_layer(MCCanvas* canvas, MCLayerId layer);

int32_t mc_canvas_remove_layer(MCCanvas* canvas, MCLayerId layer);
int32_t mc_canvas_move_layer(MCCanvas* canvas, MCLayerId layer, int32_t toIndex);

typedef struct {
    float   opacity;      /* 0...1 */
    int32_t blend;        /* index into the blend mode table; see blend_api.h */
    int32_t visible;
    int32_t locked;
    int32_t clipToBelow;  /* draw only where the layer beneath has alpha */
} MCLayerInfo;

int32_t mc_canvas_layer_info(MCCanvas* canvas, MCLayerId layer, MCLayerInfo* out);
int32_t mc_canvas_set_layer_info(MCCanvas* canvas, MCLayerId layer, const MCLayerInfo* info);

/* Copies the name into `buffer`, always null-terminated. Returns the number of
 * bytes written, excluding the terminator. */
int32_t mc_canvas_layer_name(MCCanvas* canvas, MCLayerId layer,
                             char* buffer, int32_t capacity);
int32_t mc_canvas_set_layer_name(MCCanvas* canvas, MCLayerId layer, const char* name);

/* MARK: - Editing */

void mc_canvas_begin_stroke(MCCanvas* canvas, const char* name);

/*
 * Hands one tile's pixels to the engine, into the active layer. Captures undo
 * state for that tile first, so it must be called between begin_stroke and
 * commit_stroke. `rgba` must point at mc_tile_size() * mc_tile_size() * 4
 * bytes.
 */
void mc_canvas_store_tile(MCCanvas* canvas, int32_t tx, int32_t ty, const uint8_t* rgba);

/* As above, but naming the layer explicitly. */
void mc_canvas_store_tile_in(MCCanvas* canvas, MCLayerId layer,
                             int32_t tx, int32_t ty, const uint8_t* rgba);

void mc_canvas_commit_stroke(MCCanvas* canvas);

/* Discards the stroke in progress, releasing whatever undo state it captured. */
void mc_canvas_abort_stroke(MCCanvas* canvas);

/*
 * Copies a tile out for GPU upload. Returns 1 on success, 0 if that tile has
 * never been painted — in which case `rgba` is left untouched and the caller
 * should treat the region as empty rather than uploading anything.
 */
int32_t mc_canvas_load_tile(MCCanvas* canvas, int32_t tx, int32_t ty, uint8_t* rgba);
int32_t mc_canvas_load_tile_from(MCCanvas* canvas, MCLayerId layer,
                                 int32_t tx, int32_t ty, uint8_t* rgba);

/* Clears the active layer. Recorded as a normal undoable action. */
void mc_canvas_clear(MCCanvas* canvas);

/* MARK: - Composite plan */

/*
 * While painting, the screen is under cache + live layers + over cache. Only
 * the live layers are recomposited each frame, so a deep document costs what a
 * shallow one costs while the pen is down.
 *
 * "Live" is the active layer's whole clip group, not just the active layer: a
 * clipped layer draws only where the one beneath has alpha, so neither can be
 * flattened away without the other.
 */
typedef struct {
    int32_t underCount;
    int32_t liveCount;
    int32_t overCount;
    int32_t underDirty;   /* the under cache must be rebuilt this frame */
    int32_t overDirty;
    MCLayerId activeLayer;
} MCCompositePlan;

typedef enum {
    MCCompositeSectionUnder = 0,
    MCCompositeSectionLive = 1,
    MCCompositeSectionOver = 2
} MCCompositeSection;

/* Recomputes the plan and reports which caches went stale. Call once a frame. */
void mc_canvas_refresh_plan(MCCanvas* canvas, MCCompositePlan* out);

/* Layer at `index` within a section, bottom to top. */
MCLayerId mc_canvas_plan_layer(MCCanvas* canvas, int32_t section, int32_t index);

/* Forces both caches to rebuild — after a resize, or anything else that
 * invalidates the textures rather than their contents. */
void mc_canvas_invalidate_caches(MCCanvas* canvas);

/* MARK: - History */

int32_t mc_canvas_can_undo(MCCanvas* canvas);
int32_t mc_canvas_can_redo(MCCanvas* canvas);

/* Return 1 if anything changed. */
int32_t mc_canvas_undo(MCCanvas* canvas);
int32_t mc_canvas_redo(MCCanvas* canvas);

/*
 * Tiles touched by the last undo, redo or clear. Valid until the next call
 * that changes the canvas.
 */
int32_t mc_canvas_changed_tile_count(MCCanvas* canvas);
void mc_canvas_changed_tile_at(MCCanvas* canvas, int32_t index, int32_t* tx, int32_t* ty);

/* MARK: - Instrumentation */

typedef struct {
    uint64_t liveTiles;
    uint64_t residentTiles;
    uint64_t compressedTiles;
    uint64_t spilledTiles;
    uint64_t residentBytes;
    uint64_t compressedBytes;
    uint64_t spillFileBytes;
    uint64_t decompressions;
    uint64_t spillReads;
    uint64_t undoDepth;
    uint64_t redoDepth;
    uint64_t historyTiles;
    /*
     * Tiles written outside a begin/commit pair. Any value above zero means
     * edits are landing with no undo history behind them. Surfaced because a
     * missing begin_stroke is silent otherwise: painting looks perfect and
     * only undo misbehaves, which is a long way from the cause.
     */
    uint64_t storesOutsideAction;
    /*
     * Cache rebuilds. While a single stroke is in progress these must not
     * climb: if they do, something is invalidating the caches every frame and
     * the under/over optimisation has quietly stopped working.
     */
    uint64_t underCacheRebuilds;
    uint64_t overCacheRebuilds;
} MCCanvasStats;

void mc_canvas_stats(MCCanvas* canvas, MCCanvasStats* out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CANVAS_API_H */
