#include "core/undo.h"

#include <utility>

namespace mc {
namespace {
const std::string kNoName;
} // namespace

UndoStack::UndoStack(TileStore& store, LayerStack& layers, size_t maxActions)
    : store_(&store), layers_(&layers), maxActions_(maxActions == 0 ? 1 : maxActions) {}

UndoStack::~UndoStack() {
    clear();
    releaseAction(pending_);
}

// MARK: - Recording

void UndoStack::beginAction(std::string name) {
    // An unclosed action means someone forgot to commit. Dropping it is better
    // than silently merging two actions into one undo step.
    if (recording_) {
        abortAction();
    }
    pending_.name = std::move(name);
    pending_.edits.clear();
    pendingKeys_.clear();
    recording_ = true;
}

void UndoStack::willModify(LayerId layer, TileCoord coord) {
    if (!recording_) return;

    Layer* pixels = layers_->pixels(layer);
    if (pixels == nullptr) return;

    // Only the first change to a tile within an action matters — the history
    // needs the state from before the action, not before each brush dab.
    const EditKey key{layer, coord};
    if (!pendingKeys_.insert(key).second) {
        return;
    }

    TileEdit edit;
    edit.layer = layer;
    edit.coord = coord;
    edit.before = pixels->tileId(coord);

    if (edit.before != kInvalidTile) {
        // This reference is what makes the next writeTile copy-on-write
        // instead of modifying the tile the history is holding.
        store_->retain(edit.before);
    }
    pending_.edits.push_back(edit);
}

void UndoStack::commitAction() {
    if (!recording_) return;
    recording_ = false;

    if (pending_.edits.empty()) {
        // Nothing changed. Recording a no-op would make undo appear broken:
        // the user presses it and nothing visible happens.
        pending_.name.clear();
        pendingKeys_.clear();
        return;
    }

    // A new action invalidates the redo branch.
    for (auto& action : redoStack_) {
        releaseAction(action);
    }
    redoStack_.clear();

    undoStack_.push_back(std::move(pending_));
    pending_ = Action{};
    pendingKeys_.clear();

    while (undoStack_.size() > maxActions_) {
        releaseAction(undoStack_.front());
        undoStack_.pop_front();
    }
}

void UndoStack::abortAction() {
    if (!recording_) return;
    recording_ = false;
    releaseAction(pending_);
    pending_ = Action{};
    pendingKeys_.clear();
}

// MARK: - Navigation

const std::string& UndoStack::undoName() const {
    return undoStack_.empty() ? kNoName : undoStack_.back().name;
}

const std::string& UndoStack::redoName() const {
    return redoStack_.empty() ? kNoName : redoStack_.back().name;
}

void UndoStack::applyAndSwap(TileEdit& edit) {
    Layer* pixels = layers_->pixels(edit.layer);
    if (pixels == nullptr) {
        // The layer was deleted after this entry was recorded. There is
        // nothing to restore into, so the entry is inert — which is exactly
        // why edits name layers by id rather than by pointer.
        return;
    }

    const TileId current = pixels->tileId(edit.coord);

    // Retain before handing the tile over. adoptTile and dropTile both release
    // the layer's reference, and if that were the only one the tile would be
    // recycled before the history could take it.
    if (current != kInvalidTile) {
        store_->retain(current);
    }

    if (edit.before == kInvalidTile) {
        pixels->dropTile(edit.coord);
    } else {
        pixels->adoptTile(edit.coord, edit.before);
        // adoptTile took its own reference; release the history's.
        store_->release(edit.before);
    }

    // The edit now holds whatever was displaced, so the same call redoes it.
    edit.before = current;
}

bool UndoStack::undo() {
    if (recording_ || undoStack_.empty()) return false;

    Action action = std::move(undoStack_.back());
    undoStack_.pop_back();

    lastAffected_.clear();
    // Reverse order, so overlapping edits unwind in the order they were made.
    for (auto it = action.edits.rbegin(); it != action.edits.rend(); ++it) {
        applyAndSwap(*it);
        lastAffected_.push_back(it->coord);
    }

    redoStack_.push_back(std::move(action));
    return true;
}

bool UndoStack::redo() {
    if (recording_ || redoStack_.empty()) return false;

    Action action = std::move(redoStack_.back());
    redoStack_.pop_back();

    lastAffected_.clear();
    for (auto& edit : action.edits) {
        applyAndSwap(edit);
        lastAffected_.push_back(edit.coord);
    }

    undoStack_.push_back(std::move(action));
    return true;
}

void UndoStack::releaseAction(Action& action) {
    for (auto& edit : action.edits) {
        if (edit.before != kInvalidTile) {
            store_->release(edit.before);
            edit.before = kInvalidTile;
        }
    }
    action.edits.clear();
}

void UndoStack::clear() {
    for (auto& action : undoStack_) releaseAction(action);
    for (auto& action : redoStack_) releaseAction(action);
    undoStack_.clear();
    redoStack_.clear();
}

size_t UndoStack::retainedTileCount() const {
    size_t count = 0;
    for (const auto& action : undoStack_) {
        for (const auto& edit : action.edits) {
            if (edit.before != kInvalidTile) ++count;
        }
    }
    for (const auto& action : redoStack_) {
        for (const auto& edit : action.edits) {
            if (edit.before != kInvalidTile) ++count;
        }
    }
    return count;
}

} // namespace mc
