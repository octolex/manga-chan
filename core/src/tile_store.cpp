#include "core/tile_store.h"

#include <cassert>
#include <cstring>

namespace mc {

TileStore::TileStore() {
    // Slot 0 is the sentinel for kInvalidTile and never holds pixels.
    slots_.emplace_back();
}

TileStore::~TileStore() = default;

TileId TileStore::acquireBlank() {
    TileId id = kInvalidTile;

    if (!freeList_.empty()) {
        id = freeList_.back();
        freeList_.pop_back();
        std::memset(slots_[id].pixels.get(), 0, kTileBytes);
    } else {
        slots_.push_back(Slot{std::make_unique<uint8_t[]>(kTileBytes), 0});
        id = static_cast<TileId>(slots_.size() - 1);
        std::memset(slots_[id].pixels.get(), 0, kTileBytes);
        ++allocatedTiles_;
    }

    slots_[id].refs = 1;
    ++liveTiles_;
    if (liveTiles_ > peakLiveTiles_) {
        peakLiveTiles_ = liveTiles_;
    }
    return id;
}

TileId TileStore::acquireCopy(TileId source) {
    if (!valid(source)) {
        return acquireBlank();
    }
    const TileId id = acquireBlank();
    // acquireBlank may have reallocated slots_, so both pointers are taken
    // after it returns rather than before.
    std::memcpy(slots_[id].pixels.get(), slots_[source].pixels.get(), kTileBytes);
    return id;
}

void TileStore::retain(TileId id) {
    if (!valid(id)) return;
    ++slots_[id].refs;
}

void TileStore::release(TileId id) {
    if (!valid(id)) return;
    Slot& slot = slots_[id];
    assert(slot.refs > 0 && "releasing a tile that holds no references");
    if (slot.refs == 0) return;

    if (--slot.refs == 0) {
        // Keep the allocation; only the reference is gone.
        freeList_.push_back(id);
        --liveTiles_;
    }
}

uint32_t TileStore::refCount(TileId id) const {
    return valid(id) ? slots_[id].refs : 0;
}

const uint8_t* TileStore::data(TileId id) const {
    return valid(id) ? slots_[id].pixels.get() : nullptr;
}

uint8_t* TileStore::mutableData(TileId id) {
    return valid(id) ? slots_[id].pixels.get() : nullptr;
}

} // namespace mc
