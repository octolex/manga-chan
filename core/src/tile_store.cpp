#include "core/tile_store.h"

#include <algorithm>
#include <cassert>
#include <cstring>

namespace mc {

TileStore::TileStore(size_t residentBudgetBytes)
    : residentBudget_(residentBudgetBytes) {
    // Slot 0 is the sentinel for kInvalidTile and never holds pixels.
    slots_.emplace_back();
}

TileStore::~TileStore() = default;

// MARK: - Buffer pool

std::unique_ptr<uint8_t[]> TileStore::takeBuffer() const {
    if (!bufferPool_.empty()) {
        auto buffer = std::move(bufferPool_.back());
        bufferPool_.pop_back();
        return buffer;
    }
    return std::make_unique<uint8_t[]>(kTileBytes);
}

void TileStore::recycleBuffer(std::unique_ptr<uint8_t[]> buffer) const {
    if (bufferPool_.size() < kMaxPooledBuffers) {
        bufferPool_.push_back(std::move(buffer));
    }
    // Otherwise let it go. An unbounded pool would hold memory the budget
    // just worked to free.
}

void TileStore::noteResidentBytes() const {
    const size_t bytes = residentBytes();
    if (bytes > peakResidentBytes_) {
        peakResidentBytes_ = bytes;
    }
}

// MARK: - Ownership

TileId TileStore::acquireBlank() {
    TileId id = kInvalidTile;
    if (!freeIds_.empty()) {
        id = freeIds_.back();
        freeIds_.pop_back();
    } else {
        slots_.emplace_back();
        id = static_cast<TileId>(slots_.size() - 1);
    }

    Slot& slot = slots_[id];
    slot.pixels = takeBuffer();
    std::memset(slot.pixels.get(), 0, kTileBytes);
    slot.compressed.clear();
    slot.compressed.shrink_to_fit();
    slot.refs = 1;
    slot.lastTouch = ++clock_;

    ++liveTiles_;
    ++residentBuffers_;
    noteResidentBytes();
    return id;
}

TileId TileStore::acquireCopy(TileId source) {
    if (!valid(source)) {
        return acquireBlank();
    }
    // Materialise the source first: acquireBlank may reallocate slots_, which
    // would dangle a pointer taken before it.
    const uint8_t* sourcePixels = materialise(source);
    if (sourcePixels == nullptr) {
        return acquireBlank();
    }

    const TileId id = acquireBlank();
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

    if (--slot.refs > 0) return;

    if (slot.pixels != nullptr) {
        recycleBuffer(std::move(slot.pixels));
        --residentBuffers_;
    }
    compressedBytes_ -= slot.compressed.size();
    slot.compressed.clear();
    slot.compressed.shrink_to_fit();

    if (slot.spill.valid() && spillFile_ != nullptr) {
        spillFile_->release(slot.spill);
        slot.spill = TileSpillFile::Ref{};
        --spilledTiles_;
    }

    freeIds_.push_back(id);
    --liveTiles_;
}

uint32_t TileStore::refCount(TileId id) const {
    return valid(id) ? slots_[id].refs : 0;
}

// MARK: - Access

uint8_t* TileStore::materialise(TileId id) const {
    if (!valid(id)) return nullptr;
    const Slot& slot = slots_[id];

    if (slot.pixels == nullptr) {
        // Cold tier first: the payload has to be back in RAM before it can be
        // decoded.
        if (slot.compressed.empty() && slot.spill.valid() && spillFile_ != nullptr) {
            std::vector<uint8_t> payload;
            if (!spillFile_->read(slot.spill, payload)) {
                assert(false && "spilled tile could not be read back");
                return nullptr;
            }
            spillFile_->release(slot.spill);
            slot.spill = TileSpillFile::Ref{};
            slot.compressed = std::move(payload);
            compressedBytes_ += slot.compressed.size();
            --spilledTiles_;
        }

        auto buffer = takeBuffer();
        if (!codec_.decode(slot.compressed.data(), slot.compressed.size(), buffer.get())) {
            // A corrupt payload is unrecoverable, and handing back stale or
            // random pixels would be worse than handing back nothing.
            assert(false && "tile payload failed to decode");
            return nullptr;
        }
        slot.pixels = std::move(buffer);
        compressedBytes_ -= slot.compressed.size();
        slot.compressed.clear();
        slot.compressed.shrink_to_fit();
        ++residentBuffers_;
        ++decompressions_;
        noteResidentBytes();
    }

    slot.lastTouch = ++clock_;
    return slot.pixels.get();
}

const uint8_t* TileStore::data(TileId id) const {
    return materialise(id);
}

uint8_t* TileStore::mutableData(TileId id) {
    uint8_t* pixels = materialise(id);
    if (pixels == nullptr) return nullptr;
    // Any compressed copy is about to be stale.
    Slot& slot = slots_[id];
    compressedBytes_ -= slot.compressed.size();
    slot.compressed.clear();
    slot.compressed.shrink_to_fit();
    return pixels;
}

// MARK: - Residency

void TileStore::setResidentBudget(size_t bytes) {
    residentBudget_ = bytes;
}

size_t TileStore::residentTileCount() const {
    return residentBuffers_;
}

size_t TileStore::compressedTileCount() const {
    return liveTiles_ - residentBuffers_ - spilledTiles_;
}

void TileStore::setCompressedBudget(size_t bytes) {
    compressedBudget_ = bytes;
}

bool TileStore::enableSpilling(const std::filesystem::path& scratchFile) {
    auto file = std::make_unique<TileSpillFile>(scratchFile);
    if (!file->isOpen()) {
        return false;
    }
    spillFile_ = std::move(file);
    return true;
}

uint64_t TileStore::spillFileBytes() const {
    return spillFile_ != nullptr ? spillFile_->fileBytes() : 0;
}

uint64_t TileStore::spillReadCount() const {
    return spillFile_ != nullptr ? spillFile_->readCount() : 0;
}

bool TileStore::spillTile(TileId id) {
    if (spillFile_ == nullptr || !valid(id)) return false;
    Slot& slot = slots_[id];
    if (slot.pixels != nullptr) return false;    // compress it first
    if (slot.compressed.empty()) return false;   // nothing to write, or already spilled

    const auto ref = spillFile_->write(slot.compressed.data(), slot.compressed.size());
    if (!ref.valid()) {
        // Disk full or unwritable. Keeping the tile in RAM is the only safe
        // answer; dropping it would lose the user's work.
        return false;
    }

    slot.spill = ref;
    compressedBytes_ -= slot.compressed.size();
    slot.compressed.clear();
    slot.compressed.shrink_to_fit();
    ++spilledTiles_;
    return true;
}

size_t TileStore::residentBytes() const {
    return (residentBuffers_ + bufferPool_.size()) * kTileBytes;
}

bool TileStore::compressTile(TileId id) {
    if (!valid(id)) return false;
    Slot& slot = slots_[id];
    if (slot.pixels == nullptr) return false; // already compressed

    slot.compressed = codec_.encode(slot.pixels.get());
    compressedBytes_ += slot.compressed.size();

    // Released outright, never pooled. The pool absorbs churn from
    // acquire/release, but pooled buffers still count against the budget —
    // so recycling here would hold on to exactly the memory that compressing
    // just worked to free, and an eviction loop would never converge.
    slot.pixels.reset();
    --residentBuffers_;
    ++compressions_;
    return true;
}

size_t TileStore::evictToBudget() {
    size_t demoted = 0;

    // Tier 1 -> 2: uncompressed pixels become compressed payloads.
    if (residentBudget_ > 0 && residentBytes() > residentBudget_) {
        // Pooled buffers hold no content, so releasing them is pure profit
        // compared to compressing a tile someone may want back.
        bufferPool_.clear();

        if (residentBytes() > residentBudget_) {
            // Oldest touch first, so the tiles most likely to be needed again
            // — the ones just drawn on — are the last to go.
            std::vector<std::pair<uint64_t, TileId>> candidates;
            candidates.reserve(residentBuffers_);
            for (size_t i = 1; i < slots_.size(); ++i) {
                const Slot& slot = slots_[i];
                if (slot.refs > 0 && slot.pixels != nullptr) {
                    candidates.emplace_back(slot.lastTouch, static_cast<TileId>(i));
                }
            }
            std::sort(candidates.begin(), candidates.end());

            for (const auto& [touch, id] : candidates) {
                if (residentBytes() <= residentBudget_) break;
                if (compressTile(id)) ++demoted;
            }
            bufferPool_.clear();
        }
    }

    // Tier 2 -> 3: compressed payloads that are still cold leave RAM entirely.
    if (spillFile_ != nullptr && compressedBudget_ > 0
        && compressedBytes_ > compressedBudget_) {
        std::vector<std::pair<uint64_t, TileId>> cold;
        for (size_t i = 1; i < slots_.size(); ++i) {
            const Slot& slot = slots_[i];
            if (slot.refs > 0 && slot.pixels == nullptr && !slot.compressed.empty()) {
                cold.emplace_back(slot.lastTouch, static_cast<TileId>(i));
            }
        }
        std::sort(cold.begin(), cold.end());

        for (const auto& [touch, id] : cold) {
            if (compressedBytes_ <= compressedBudget_) break;
            if (spillTile(id)) ++demoted;
        }
    }

    return demoted;
}

} // namespace mc
