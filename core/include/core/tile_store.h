#pragma once

//
//  tile_store.h — owns tile memory, shares it between layers, and decides
//  what stays uncompressed in RAM.
//
//  Two mechanisms live here.
//
//  Reference counting and copy-on-write. Before a stroke dirties a tile, the
//  old tile is handed to the undo history, which simply takes a second
//  reference. Nothing is copied unless someone writes. Snapshotting whole
//  layers instead costs tens of gigabytes for a 250-step history on a large
//  document; per-tile copy-on-write costs tens of megabytes.
//
//  Residency. Tiles that have not been touched recently are compressed and
//  their 256 KB pixel buffers released, then decoded again on next access.
//  This is what makes memory a function of what is *visible* rather than of
//  document size — and therefore what removes the layer cap. A 200-layer
//  document costs what its visible tiles cost.
//
//  IMPORTANT — pointer lifetime. Pointers from data() and mutableData() stay
//  valid until the next call to evictToBudget() or release() on that tile.
//  Eviction is never spontaneous; the caller decides when it happens, at a
//  frame boundary. Making it automatic would mean a pointer could evaporate
//  mid-stroke, which is not a bug anyone wants to debug on a device with no
//  debugger attached.
//

#include "core/tile.h"
#include "core/tile_codec.h"

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
    /// `residentBudgetBytes` of 0 means unlimited: nothing is ever compressed.
    explicit TileStore(size_t residentBudgetBytes = 0);
    ~TileStore();

    TileStore(const TileStore&) = delete;
    TileStore& operator=(const TileStore&) = delete;

    // MARK: - Ownership

    /// A new tile, zero-filled, with a reference count of 1.
    TileId acquireBlank();

    /// A new tile holding a copy of `source`. The "write" half of
    /// copy-on-write.
    TileId acquireCopy(TileId source);

    void retain(TileId id);

    /// Drops a reference. At zero the tile's buffer returns to the pool.
    void release(TileId id);

    uint32_t refCount(TileId id) const;

    // MARK: - Access
    //
    // Both of these materialise a compressed tile and mark it as recently
    // used, so they participate in the LRU ordering.

    const uint8_t* data(TileId id) const;

    /// Also discards the tile's compressed form, since it is about to go stale.
    uint8_t* mutableData(TileId id);

    // MARK: - Residency

    void setResidentBudget(size_t bytes);
    size_t residentBudget() const { return residentBudget_; }

    /// Compresses least-recently-used tiles until resident memory fits the
    /// budget. Returns the number of tiles compressed.
    ///
    /// Invalidates every pointer previously returned by data()/mutableData().
    size_t evictToBudget();

    /// Compresses one specific tile regardless of budget. Mainly for tests.
    bool compressTile(TileId id);

    // MARK: - Instrumentation
    //
    // These exist because we cannot run Instruments against the device. They
    // are the only visibility we have into memory behaviour, so they are part
    // of the design rather than an afterthought.

    size_t liveTileCount() const { return liveTiles_; }
    size_t residentTileCount() const;
    size_t compressedTileCount() const;
    size_t pooledBufferCount() const { return bufferPool_.size(); }

    /// Uncompressed pixel buffers currently held, including pooled ones. This
    /// is the figure that matters against the device memory ceiling.
    size_t residentBytes() const;

    /// Total size of all compressed payloads.
    size_t compressedBytes() const { return compressedBytes_; }

    size_t peakResidentBytes() const { return peakResidentBytes_; }

    /// Decompressions performed. Climbing steadily while drawing means the
    /// budget is too small for the working set and tiles are thrashing.
    uint64_t decompressionCount() const { return decompressions_; }

    uint64_t compressionCount() const { return compressions_; }

private:
    struct Slot {
        // Mutable because materialising a compressed tile is a caching
        // operation: it changes representation, not content, so const readers
        // are still logically const.
        mutable std::unique_ptr<uint8_t[]> pixels;
        mutable std::vector<uint8_t> compressed;
        mutable uint64_t lastTouch = 0;
        uint32_t refs = 0;
    };

    bool valid(TileId id) const {
        return id != kInvalidTile && id < slots_.size() && slots_[id].refs > 0;
    }

    std::unique_ptr<uint8_t[]> takeBuffer() const;
    void recycleBuffer(std::unique_ptr<uint8_t[]> buffer) const;

    /// Decompresses in place if needed and stamps the LRU clock.
    uint8_t* materialise(TileId id) const;

    void noteResidentBytes() const;

    PixelRunCodec codec_;

    mutable std::vector<Slot> slots_;   // index 0 is a permanently empty sentinel
    std::vector<TileId> freeIds_;
    mutable std::vector<std::unique_ptr<uint8_t[]>> bufferPool_;

    size_t residentBudget_ = 0;
    size_t liveTiles_ = 0;
    mutable size_t residentBuffers_ = 0;   // tiles holding pixels
    mutable size_t compressedBytes_ = 0;
    mutable size_t peakResidentBytes_ = 0;
    mutable uint64_t clock_ = 0;
    mutable uint64_t decompressions_ = 0;
    mutable uint64_t compressions_ = 0;

    /// Spare buffers kept for churn. Painting constantly creates and destroys
    /// tiles, and round-tripping 256 KB blocks through the allocator is what
    /// fragments a heap — but an unbounded pool would defeat the budget.
    static constexpr size_t kMaxPooledBuffers = 8;
};

} // namespace mc
