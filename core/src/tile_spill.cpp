#include "core/tile_spill.h"

#include <algorithm>
#include <system_error>

namespace mc {

TileSpillFile::TileSpillFile(std::filesystem::path path) : path_(std::move(path)) {
    // trunc creates the file and discards anything left by a previous run —
    // a stale scratch file would otherwise be read as if it were ours.
    file_.open(path_, std::ios::in | std::ios::out | std::ios::binary | std::ios::trunc);
    open_ = file_.is_open();
}

TileSpillFile::~TileSpillFile() {
    if (open_) {
        file_.close();
    }
    std::error_code ignored;
    std::filesystem::remove(path_, ignored);
}

TileSpillFile::Ref TileSpillFile::write(const uint8_t* data, size_t size) {
    Ref ref;
    if (!open_ || data == nullptr || size == 0 || size > UINT32_MAX) {
        return ref;
    }

    // First fit over released blocks. Reusing space is what stops the file
    // growing without bound when the same tiles spill and return repeatedly.
    const auto fit = std::find_if(freeList_.begin(), freeList_.end(),
                                  [size](const FreeBlock& block) {
                                      return block.capacity >= size;
                                  });

    if (fit != freeList_.end()) {
        ref.offset = fit->offset;
        ref.capacity = fit->capacity;
        freeList_.erase(fit);
    } else {
        ref.offset = end_;
        ref.capacity = static_cast<uint32_t>(size);
        end_ += size;
    }
    ref.size = static_cast<uint32_t>(size);

    file_.clear();
    file_.seekp(static_cast<std::streamoff>(ref.offset), std::ios::beg);
    file_.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(size));
    if (!file_.good()) {
        // Out of space, or the file went away. Hand back an invalid Ref so the
        // caller keeps the tile in memory rather than losing the user's work.
        file_.clear();
        release(ref);
        return Ref{};
    }
    file_.flush();

    liveBytes_ += ref.capacity;
    ++writes_;
    return ref;
}

bool TileSpillFile::read(const Ref& ref, std::vector<uint8_t>& out) {
    if (!open_ || !ref.valid() || ref.size == 0) {
        return false;
    }

    out.resize(ref.size);
    file_.clear();
    file_.seekg(static_cast<std::streamoff>(ref.offset), std::ios::beg);
    file_.read(reinterpret_cast<char*>(out.data()), static_cast<std::streamsize>(ref.size));
    if (file_.gcount() != static_cast<std::streamsize>(ref.size)) {
        file_.clear();
        return false;
    }
    ++reads_;
    return true;
}

void TileSpillFile::release(const Ref& ref) {
    if (!ref.valid()) return;
    freeList_.push_back(FreeBlock{ref.offset, ref.capacity});
    liveBytes_ -= std::min<uint64_t>(liveBytes_, ref.capacity);
}

} // namespace mc
