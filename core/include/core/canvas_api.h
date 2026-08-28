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

/* MARK: - Editing */

void mc_canvas_begin_stroke(MCCanvas* canvas, const char* name);

/*
 * Hands one tile's pixels to the engine. Captures undo state for that tile
 * first, so it must be called between begin_stroke and commit_stroke.
 * `rgba` must point at mc_tile_size() * mc_tile_size() * 4 bytes.
 */
void mc_canvas_store_tile(MCCanvas* canvas, int32_t tx, int32_t ty, const uint8_t* rgba);

void mc_canvas_commit_stroke(MCCanvas* canvas);

/* Discards the stroke in progress, releasing whatever undo state it captured. */
void mc_canvas_abort_stroke(MCCanvas* canvas);

/*
 * Copies a tile out for GPU upload. Returns 1 on success, 0 if that tile has
 * never been painted — in which case `rgba` is left untouched and the caller
 * should treat the region as empty rather than uploading anything.
 */
int32_t mc_canvas_load_tile(MCCanvas* canvas, int32_t tx, int32_t ty, uint8_t* rgba);

void mc_canvas_clear(MCCanvas* canvas);

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
} MCCanvasStats;

void mc_canvas_stats(MCCanvas* canvas, MCCanvasStats* out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CANVAS_API_H */
