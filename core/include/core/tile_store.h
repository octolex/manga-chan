#pragma once

//
//  tile_store.h — owns tile memory and shares it between layers.
//
//  Tiles are reference counted, and that is the whole point. Copy-on-write is
//  what makes undo affordable: before a stroke dirties a tile, the old tile is
//  handed to the undo history, which simply takes a second reference. Nothing
//  is copied unless and until someone writes.
//
//  The alternative — snapshotting whole layers per undo step — costs tens of
//  gigabytes for a 250-step history on a large document. Per-tile copy-on-write
//  costs tens of megabytes for the same history.
//
//  Freed tiles are pooled rather than returned to the allocator. Painting
//  churns tiles continuously, and repeatedly allocating and freeing 256 KB
//  blocks is exactly the pattern that fragments a heap.
//

#include "core/tile.h"

#include <cstdint>
#include <memory>
#include <vector>

namespace mc {

/// Handle into a TileStore. Zero is reserved to mean "no tile", so a
/// default-constructed handle is never mistaken for tile index 0.
using TileId = uint32_t;
inline constexpr TileId kInvalidTile = 0;

class TileStore {
public:
    TileStore();
    ~TileStore();

    TileStore(const TileStore&) = delete;
    TileStore& operator=(const TileStore&) = delete;

    /// A new tile, zero-filled, with a reference count of 1.
    TileId acquireBlank();

    /// A new tile holding a copy of `source`, reference count 1.
    /// This is the "write" half of copy-on-write.
    TileId acquireCopy(TileId source);

    void retain(TileId id);

    /// Drops a reference. At zero the tile returns to the pool.
    void release(TileId id);

    uint32_t refCount(TileId id) const;

    const uint8_t* data(TileId id) const;
    uint8_t* mutableData(TileId id);

    /// Tiles currently referenced by at least one owner.
    size_t liveTileCount() const { return liveTiles_; }

    /// Tiles held in the pool, allocated but unreferenced.
    size_t pooledTileCount() const { return freeList_.size(); }

    /// Bytes actually allocated, including pooled tiles. This is the number
    /// that matters when reasoning about the device memory ceiling.
    size_t allocatedBytes() const { return allocatedTiles_ * kTileBytes; }

    /// High-water mark of live tiles, for memory instrumentation.
    size_t peakLiveTileCount() const { return peakLiveTiles_; }

private:
    struct Slot {
        std::unique_ptr<uint8_t[]> pixels;
        uint32_t refs = 0;
    };

    bool valid(TileId id) const {
        return id != kInvalidTile && id < slots_.size() && slots_[id].pixels != nullptr;
    }

    std::vector<Slot> slots_;      // index 0 is a permanently empty sentinel
    std::vector<TileId> freeList_;
    size_t liveTiles_ = 0;
    size_t allocatedTiles_ = 0;
    size_t peakLiveTiles_ = 0;
};

} // namespace mc
