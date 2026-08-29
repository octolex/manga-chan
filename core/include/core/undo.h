#pragma once

//
//  undo.h — per-tile undo history.
//
//  The rule that makes this affordable: never snapshot a layer. Before a
//  stroke dirties a tile, the undo stack takes a *reference* to the existing
//  tile. Layer::writeTile then sees a reference count above one and separates
//  the tile on write, so the history keeps the old pixels without anything
//  having been copied up front.
//
//  A 250-step history over whole-layer snapshots costs tens of gigabytes on a
//  large document. Per-tile copy-on-write costs tens of megabytes, and only
//  for tiles that were actually touched.
//
//  Usage, from the drawing code:
//
//      undo.beginAction("Stroke");
//      for each tile the stroke touches:
//          undo.willModify(layer, coord);   // must come BEFORE writeTile
//          paint into layer.writeTile(coord);
//      undo.commitAction();
//
//  Calling willModify after writeTile would record the already-modified tile
//  and undo would restore the wrong pixels.
//
//  Edits address layers by stable LayerId, never by pointer or index. The
//  history routinely outlives the layers it refers to — the user deletes a
//  layer and then presses undo — and an entry holding a raw pointer would be a
//  use-after-free waiting to happen. An entry naming a layer that no longer
//  exists simply becomes inert.
//

#include "core/layer.h"
#include "core/layer_stack.h"
#include "core/tile.h"
#include "core/tile_store.h"

#include <cstddef>
#include <deque>
#include <string>
#include <unordered_set>
#include <vector>

namespace mc {

class UndoStack {
public:
    /// `maxActions` bounds the history. Older actions are dropped and their
    /// tile references released, which is what keeps memory bounded during a
    /// long drawing session.
    UndoStack(TileStore& store, LayerStack& layers, size_t maxActions = 250);
    ~UndoStack();

    UndoStack(const UndoStack&) = delete;
    UndoStack& operator=(const UndoStack&) = delete;

    // MARK: - Recording

    void beginAction(std::string name);

    /// Records the current state of one tile. Call before writing to it.
    /// Repeated calls for the same tile within one action are ignored, so the
    /// history holds the state from before the action began.
    void willModify(LayerId layer, TileCoord coord);

    /// Pushes the action onto the undo stack. An action that touched no tiles
    /// is discarded rather than cluttering the history with a no-op.
    void commitAction();

    /// Throws away the action in progress, releasing anything it recorded.
    /// Used when a stroke is cancelled.
    void abortAction();

    bool isRecording() const { return recording_; }

    // MARK: - Navigation

    bool canUndo() const { return !undoStack_.empty(); }
    bool canRedo() const { return !redoStack_.empty(); }

    /// Name of the action that undo/redo would apply, or empty if none.
    const std::string& undoName() const;
    const std::string& redoName() const;

    bool undo();
    bool redo();

    /// Tiles touched by the most recent undo() or redo(). The renderer uses
    /// this to re-upload only what actually changed, rather than the whole
    /// canvas — otherwise the cost of undo would scale with document size
    /// instead of with the size of the edit.
    const std::vector<TileCoord>& lastAffectedTiles() const { return lastAffected_; }

    void clear();

    // MARK: - Instrumentation

    size_t undoDepth() const { return undoStack_.size(); }
    size_t redoDepth() const { return redoStack_.size(); }

    /// Tiles held alive solely by the history. Multiply by kTileBytes for a
    /// worst-case figure; most will be compressed well below that.
    size_t retainedTileCount() const;

private:
    struct TileEdit {
        LayerId layer = kInvalidLayer;
        TileCoord coord;
        /// The tile as it was before the action. kInvalidTile means the tile
        /// did not exist, so undoing removes it rather than restoring pixels.
        TileId before = kInvalidTile;
    };

    struct Action {
        std::string name;
        std::vector<TileEdit> edits;
    };

    struct EditKey {
        LayerId layer;
        TileCoord coord;
        friend bool operator==(const EditKey&, const EditKey&) = default;
    };

    struct EditKeyHash {
        size_t operator()(const EditKey& key) const noexcept {
            const size_t a = std::hash<LayerId>{}(key.layer);
            const size_t b = TileCoordHash{}(key.coord);
            return a ^ (b + 0x9e3779b97f4a7c15ULL + (a << 6) + (a >> 2));
        }
    };

    /// Swaps the layer's current tile with the one held in the edit, so the
    /// same operation serves both undo and redo.
    void applyAndSwap(TileEdit& edit);

    void releaseAction(Action& action);

    TileStore* store_;
    LayerStack* layers_;
    size_t maxActions_;

    bool recording_ = false;
    Action pending_;
    std::unordered_set<EditKey, EditKeyHash> pendingKeys_;

    std::deque<Action> undoStack_;
    std::deque<Action> redoStack_;
    std::vector<TileCoord> lastAffected_;
};

} // namespace mc
