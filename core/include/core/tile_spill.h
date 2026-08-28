#pragma once

//
//  tile_spill.h — the cold tier: compressed tiles parked on disk.
//
//  Compression alone is not enough for a manga document. A 100-page book with
//  five layers a page is 500 layers; even at the ~40x we get on line art that
//  is still hundreds of megabytes, which an iPad app will not be given. Tiles
//  nobody has looked at in a while have to leave RAM entirely.
//
//  Deliberately plain file I/O rather than mmap. This is the cold tier by
//  definition, so the access latency does not matter, and buffered reads keep
//  core/ free of platform code — which matters more than usual here, because
//  the same code has to run in CI on Linux and Windows where the engine is
//  actually tested. mmap earns its place in the *document format* later, where
//  the goal is opening a file in O(visible tiles); that is a different problem.
//
//  Space is reclaimed with a free list rather than compaction. Painting spills
//  and recalls the same tiles repeatedly, and an append-only file would grow
//  without bound over a long session. First-fit reuse keeps the file roughly
//  proportional to the working set.
//

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <vector>

namespace mc {

class TileSpillFile {
public:
    /// Location of a payload within the file.
    struct Ref {
        uint64_t offset = 0;
        uint32_t size = 0;      // bytes actually used
        uint32_t capacity = 0;  // bytes reserved, >= size when a slot is reused

        bool valid() const { return capacity > 0; }
    };

    /// Creates (or truncates) a scratch file at `path`.
    explicit TileSpillFile(std::filesystem::path path);

    /// Removes the scratch file. Nothing here is meant to outlive the session.
    ~TileSpillFile();

    TileSpillFile(const TileSpillFile&) = delete;
    TileSpillFile& operator=(const TileSpillFile&) = delete;

    bool isOpen() const { return open_; }
    const std::filesystem::path& path() const { return path_; }

    /// Writes a payload and returns where it went. An invalid Ref means the
    /// write failed and the caller must keep the tile in memory.
    Ref write(const uint8_t* data, size_t size);

    /// Reads a payload back into `out`, resizing it to Ref::size.
    bool read(const Ref& ref, std::vector<uint8_t>& out);

    /// Returns the space to the free list for reuse.
    void release(const Ref& ref);

    // MARK: - Instrumentation

    uint64_t fileBytes() const { return end_; }
    uint64_t liveBytes() const { return liveBytes_; }
    size_t freeBlockCount() const { return freeList_.size(); }
    uint64_t readCount() const { return reads_; }
    uint64_t writeCount() const { return writes_; }

private:
    std::filesystem::path path_;
    std::fstream file_;
    bool open_ = false;

    uint64_t end_ = 0;        // high-water mark of the file
    uint64_t liveBytes_ = 0;  // capacity currently allocated to tiles
    uint64_t reads_ = 0;
    uint64_t writes_ = 0;

    struct FreeBlock {
        uint64_t offset;
        uint32_t capacity;
    };
    std::vector<FreeBlock> freeList_;
};

} // namespace mc
