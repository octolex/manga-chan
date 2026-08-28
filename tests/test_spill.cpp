#include "check.h"

#include "core/layer.h"
#include "core/tile_spill.h"
#include "core/tile_store.h"

#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

using namespace mc;

namespace {

std::filesystem::path scratchPath(const char* name) {
    return std::filesystem::temp_directory_path() / (std::string("mangachan-") + name + ".tiles");
}

std::vector<uint8_t> lineArtTile(uint8_t ink) {
    std::vector<uint8_t> tile(kTileBytes);
    for (size_t i = 0; i < kTileBytes; i += 4) {
        tile[i] = tile[i + 1] = tile[i + 2] = 255;
        tile[i + 3] = 255;
    }
    for (int32_t y = 0; y < kTileSize; ++y) {
        const size_t at = (static_cast<size_t>(y) * kTileSize + static_cast<size_t>(y)) * 4;
        tile[at] = tile[at + 1] = tile[at + 2] = ink;
    }
    return tile;
}

void testSpillFileRoundTrip() {
    std::printf("spill file round trip\n");

    TileSpillFile file(scratchPath("roundtrip"));
    CHECK(file.isOpen());

    const std::vector<uint8_t> payload{1, 2, 3, 4, 5, 6, 7, 8};
    const auto ref = file.write(payload.data(), payload.size());
    CHECK(ref.valid());
    CHECK_EQ(ref.size, payload.size());

    std::vector<uint8_t> readBack;
    CHECK(file.read(ref, readBack));
    CHECK(readBack == payload);
    CHECK_EQ(file.liveBytes(), payload.size());
}

void testSpillFileReusesReleasedSpace() {
    std::printf("spill file reuses released space\n");

    // Painting spills and recalls the same tiles over and over. An append-only
    // file would grow without bound across a long session.
    TileSpillFile file(scratchPath("reuse"));
    const std::vector<uint8_t> payload(1024, 0xAB);

    const auto first = file.write(payload.data(), payload.size());
    const uint64_t sizeAfterFirst = file.fileBytes();
    file.release(first);

    for (int i = 0; i < 20; ++i) {
        const auto ref = file.write(payload.data(), payload.size());
        CHECK(ref.valid());
        file.release(ref);
    }

    CHECK_EQ(file.fileBytes(), sizeAfterFirst);
    CHECK_EQ(file.liveBytes(), 0);
}

void testSpillFileRejectsBadRef() {
    std::printf("spill file rejects bad refs\n");

    TileSpillFile file(scratchPath("badref"));
    std::vector<uint8_t> out;
    CHECK(!file.read(TileSpillFile::Ref{}, out));
    CHECK(!file.write(nullptr, 10).valid());
}

void testSpilledTileSurvivesRoundTrip() {
    std::printf("spilled tile survives round trip\n");

    TileStore store;
    CHECK(store.enableSpilling(scratchPath("tile")));
    CHECK(store.spillingEnabled());

    Layer layer(store);
    const auto art = lineArtTile(0);
    std::memcpy(layer.writeTile(TileCoord{0, 0}), art.data(), kTileBytes);
    const TileId id = layer.tileId(TileCoord{0, 0});

    // A tile has to be compressed before it can leave RAM.
    CHECK(!store.spillTile(id));
    CHECK(store.compressTile(id));
    CHECK(store.spillTile(id));

    CHECK_EQ(store.spilledTileCount(), 1);
    CHECK_EQ(store.compressedTileCount(), 0);
    CHECK_EQ(store.residentTileCount(), 0);
    CHECK_EQ(store.compressedBytes(), 0);   // out of RAM entirely
    CHECK(store.spillFileBytes() > 0);

    // Reading it must transparently walk all the way back up the tiers.
    CHECK(layer.pixel(1, 0) == (Rgba8{255, 255, 255, 255}));
    CHECK(layer.pixel(5, 5) == (Rgba8{0, 0, 0, 255}));
    CHECK_EQ(store.spilledTileCount(), 0);
    CHECK_EQ(store.residentTileCount(), 1);
    CHECK_EQ(store.spillReadCount(), 1);
}

void testReleaseFreesDiskBlock() {
    std::printf("release frees the disk block\n");

    TileStore store;
    CHECK(store.enableSpilling(scratchPath("release")));

    {
        Layer layer(store);
        const auto art = lineArtTile(0);
        std::memcpy(layer.writeTile(TileCoord{0, 0}), art.data(), kTileBytes);
        const TileId id = layer.tileId(TileCoord{0, 0});
        store.compressTile(id);
        store.spillTile(id);
        CHECK_EQ(store.spilledTileCount(), 1);
    }

    // Deleting the layer must reclaim the disk block too, or the scratch file
    // grows for the whole session even as tiles come and go.
    CHECK_EQ(store.spilledTileCount(), 0);
    CHECK_EQ(store.liveTileCount(), 0);
}

void testEvictionWalksBothTiers() {
    std::printf("eviction walks both tiers\n");

    TileStore store;
    CHECK(store.enableSpilling(scratchPath("tiers")));
    store.setResidentBudget(4 * kTileBytes);
    store.setCompressedBudget(16 * 1024);

    Layer layer(store);
    const auto art = lineArtTile(0);
    for (int32_t i = 0; i < 24; ++i) {
        std::memcpy(layer.writeTile(TileCoord{i, 0}), art.data(), kTileBytes);
    }

    const size_t demoted = store.evictToBudget();
    CHECK(demoted > 0);

    CHECK(store.residentBytes() <= 4 * kTileBytes);
    CHECK(store.compressedBytes() <= 16 * 1024);
    CHECK(store.spilledTileCount() > 0);
    CHECK_EQ(store.liveTileCount(), 24);   // nothing lost, only moved

    // Everything must still read back correctly from wherever it ended up.
    for (int32_t i = 0; i < 24; ++i) {
        CHECK(layer.pixel(i * kTileSize + 5, 5) == (Rgba8{0, 0, 0, 255}));
    }
}

void testMultiPageDocumentMemoryProfile() {
    std::printf("multi-page document memory profile\n");

    // The case that motivates the cold tier: a manga chapter open at once.
    // 20 pages, 5 layers each, is 100 layers. Even at ~40x compression that
    // is far more RAM than an iPad app is given, so most of it has to be on
    // disk while staying instantly reachable.
    TileStore store;
    CHECK(store.enableSpilling(scratchPath("document")));

    // 16 MB of pixels resident, 1 MB of compressed payloads in RAM.
    store.setResidentBudget(64 * kTileBytes);
    store.setCompressedBudget(1024 * 1024);

    std::vector<Layer> layers;
    layers.reserve(100);
    const auto art = lineArtTile(0);

    for (int page = 0; page < 100; ++page) {
        Layer layer(store);
        // Four tiles of artwork per layer keeps the test quick while still
        // exercising the tier machinery at document scale.
        for (int32_t i = 0; i < 4; ++i) {
            std::memcpy(layer.writeTile(TileCoord{i, 0}), art.data(), kTileBytes);
        }
        layers.push_back(std::move(layer));
        store.evictToBudget();
    }

    CHECK_EQ(store.liveTileCount(), 400);
    CHECK(store.residentBytes() <= 64 * kTileBytes);
    CHECK(store.compressedBytes() <= 1024 * 1024);

    const size_t denseBytes = size_t(400) * kTileBytes;
    const size_t ramBytes = store.residentBytes() + store.compressedBytes();
    std::printf("  400 tiles across 100 layers: %zu KB dense -> %zu KB in RAM, %llu KB on disk\n",
                denseBytes / 1024, ramBytes / 1024,
                static_cast<unsigned long long>(store.spillFileBytes() / 1024));

    CHECK(ramBytes < denseBytes / 4);

    // Any layer, including the coldest, is still readable.
    CHECK(layers.front().pixel(5, 5) == (Rgba8{0, 0, 0, 255}));
    CHECK(layers.back().pixel(5, 5) == (Rgba8{0, 0, 0, 255}));
    std::printf("  disk reads to satisfy that: %llu\n",
                static_cast<unsigned long long>(store.spillReadCount()));
}

} // namespace

int main() {
    testSpillFileRoundTrip();
    testSpillFileReusesReleasedSpace();
    testSpillFileRejectsBadRef();
    testSpilledTileSurvivesRoundTrip();
    testReleaseFreesDiskBlock();
    testEvictionWalksBothTiers();
    testMultiPageDocumentMemoryProfile();
    return check::report("spill");
}
