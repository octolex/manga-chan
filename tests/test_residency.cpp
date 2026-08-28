#include "check.h"

#include "core/layer.h"
#include "core/tile_codec.h"
#include "core/tile_store.h"

#include <cstring>
#include <utility>
#include <vector>

using namespace mc;

namespace {

// Deterministic pseudo-random fill, so an incompressible tile is reproducible
// across platforms and a failure is always the same failure.
struct Lcg {
    uint32_t state = 0x12345678u;
    uint32_t next() {
        state = state * 1664525u + 1013904223u;
        return state;
    }
};

std::vector<uint8_t> blankTile() {
    return std::vector<uint8_t>(kTileBytes, 0);
}

std::vector<uint8_t> noiseTile() {
    std::vector<uint8_t> tile(kTileBytes);
    Lcg rng;
    for (size_t i = 0; i < kTileBytes; i += 4) {
        const uint32_t value = rng.next();
        std::memcpy(tile.data() + i, &value, 4);
    }
    return tile;
}

/// A tile that looks like manga line art: white paper with a few black strokes.
std::vector<uint8_t> lineArtTile() {
    std::vector<uint8_t> tile(kTileBytes);
    for (size_t i = 0; i < kTileBytes; i += 4) {
        tile[i] = tile[i + 1] = tile[i + 2] = 255;
        tile[i + 3] = 255;
    }
    for (int32_t y = 0; y < kTileSize; ++y) {
        for (int32_t x = 0; x < kTileSize; ++x) {
            if (x == y || x == kTileSize / 2) {
                const size_t at = (static_cast<size_t>(y) * kTileSize
                                 + static_cast<size_t>(x)) * 4;
                tile[at] = tile[at + 1] = tile[at + 2] = 0;
            }
        }
    }
    return tile;
}

void testCodecRoundTrip() {
    std::printf("codec round trip\n");

    PixelRunCodec codec;
    std::vector<uint8_t> decoded(kTileBytes);

    const std::pair<const char*, std::vector<uint8_t>> cases[] = {
        {"blank",    blankTile()},
        {"line art", lineArtTile()},
        {"noise",    noiseTile()},
    };

    for (const auto& [label, tile] : cases) {
        const auto encoded = codec.encode(tile.data());
        std::memset(decoded.data(), 0xAB, kTileBytes);
        CHECK(codec.decode(encoded.data(), encoded.size(), decoded.data()));
        CHECK(std::memcmp(tile.data(), decoded.data(), kTileBytes) == 0);
        std::printf("  %-9s %7zu -> %7zu bytes  (%.1fx)\n",
                    label, kTileBytes, encoded.size(),
                    static_cast<double>(kTileBytes) / static_cast<double>(encoded.size()));
    }
}

void testCodecWorstCaseIsBounded() {
    std::printf("codec worst case\n");

    // Incompressible input must not blow up. Literal packets cap the overhead
    // at roughly 0.2%, so nothing ever becomes meaningfully larger.
    PixelRunCodec codec;
    const auto tile = noiseTile();
    const auto encoded = codec.encode(tile.data());
    CHECK(encoded.size() < kTileBytes + kTileBytes / 100);
}

void testCodecRejectsTruncatedPayload() {
    std::printf("codec rejects bad payloads\n");

    PixelRunCodec codec;
    const auto tile = lineArtTile();
    auto encoded = codec.encode(tile.data());
    std::vector<uint8_t> decoded(kTileBytes);

    encoded.resize(encoded.size() / 2);
    // Returning stale or half-decoded pixels would be far worse than failing.
    CHECK(!codec.decode(encoded.data(), encoded.size(), decoded.data()));
}

void testCompressionPreservesContent() {
    std::printf("compression preserves content\n");

    TileStore store;
    Layer layer(store);
    layer.setPixel(10, 10, Rgba8{255, 0, 0, 255});
    layer.setPixel(11, 11, Rgba8{0, 255, 0, 255});

    const TileId id = layer.tileId(TileCoord{0, 0});
    CHECK_EQ(store.residentTileCount(), 1);
    CHECK_EQ(store.compressedTileCount(), 0);

    CHECK(store.compressTile(id));
    CHECK_EQ(store.residentTileCount(), 0);
    CHECK_EQ(store.compressedTileCount(), 1);
    CHECK(store.compressedBytes() > 0);

    // Reading it back must materialise it transparently.
    CHECK(layer.pixel(10, 10) == (Rgba8{255, 0, 0, 255}));
    CHECK(layer.pixel(11, 11) == (Rgba8{0, 255, 0, 255}));
    CHECK_EQ(store.residentTileCount(), 1);
    CHECK_EQ(store.decompressionCount(), 1);
    CHECK_EQ(store.compressedBytes(), 0);
}

void testUnlimitedBudgetNeverEvicts() {
    std::printf("unlimited budget\n");

    TileStore store(0);
    Layer layer(store);
    for (int32_t i = 0; i < 8; ++i) {
        layer.setPixel(i * kTileSize, 0, Rgba8{1, 1, 1, 255});
    }
    CHECK_EQ(store.evictToBudget(), 0);
    CHECK_EQ(store.compressedTileCount(), 0);
}

void testEvictionRespectsBudget() {
    std::printf("eviction respects budget\n");

    const size_t budget = 4 * kTileBytes;
    TileStore store(budget);
    Layer layer(store);

    for (int32_t i = 0; i < 16; ++i) {
        layer.setPixel(i * kTileSize, 0, Rgba8{1, 1, 1, 255});
    }
    CHECK_EQ(layer.tileCount(), 16);
    CHECK(store.residentBytes() > budget);

    const size_t evicted = store.evictToBudget();
    CHECK(evicted > 0);
    CHECK(store.residentBytes() <= budget);
    CHECK_EQ(store.liveTileCount(), 16);   // nothing was lost, only compressed

    // Every tile is still readable, which is the whole point.
    for (int32_t i = 0; i < 16; ++i) {
        CHECK(layer.pixel(i * kTileSize, 0) == (Rgba8{1, 1, 1, 255}));
    }
}

void testEvictionPrefersColdTiles() {
    std::printf("eviction is least-recently-used\n");

    TileStore store(0);
    Layer layer(store);
    for (int32_t i = 0; i < 10; ++i) {
        layer.setPixel(i * kTileSize, 0, Rgba8{static_cast<uint8_t>(i), 0, 0, 255});
    }

    // Touch the last two tiles so they are the most recently used.
    (void)layer.pixel(8 * kTileSize, 0);
    (void)layer.pixel(9 * kTileSize, 0);

    store.setResidentBudget(3 * kTileBytes);
    store.evictToBudget();

    CHECK(store.residentBytes() <= 3 * kTileBytes);

    // The two just-touched tiles should have survived. A stroke in progress
    // must not have its own tiles compressed out from under it.
    const TileId hot8 = layer.tileId(tileForPixel(8 * kTileSize, 0));
    const TileId hot9 = layer.tileId(tileForPixel(9 * kTileSize, 0));
    const uint64_t decompressionsBefore = store.decompressionCount();
    (void)store.data(hot8);
    (void)store.data(hot9);
    CHECK_EQ(store.decompressionCount(), decompressionsBefore);
}

void testMangaPageMemoryProfile() {
    std::printf("manga page memory profile\n");

    // A full 4096x4096 page of line art: white paper with strokes. Dense
    // RGBA8 storage is 64 MB per layer, which is exactly the constraint that
    // forces Procreate to cap layer counts by device RAM.
    TileStore store;
    Layer layer(store);

    const auto art = lineArtTile();
    for (int32_t ty = 0; ty < 16; ++ty) {
        for (int32_t tx = 0; tx < 16; ++tx) {
            std::memcpy(layer.writeTile(TileCoord{tx, ty}), art.data(), kTileBytes);
        }
    }
    CHECK_EQ(layer.tileCount(), 256);

    const size_t denseBytes = static_cast<size_t>(4096) * 4096 * 4;
    CHECK_EQ(store.residentBytes(), denseBytes);

    // Page the whole thing out, as would happen when the user scrolls away or
    // switches to a different layer.
    for (int32_t ty = 0; ty < 16; ++ty) {
        for (int32_t tx = 0; tx < 16; ++tx) {
            store.compressTile(layer.tileId(TileCoord{tx, ty}));
        }
    }

    const size_t compressed = store.compressedBytes();
    CHECK(compressed < denseBytes / 4);
    std::printf("  full page line art: %zu KB dense -> %zu KB compressed (%.1fx)\n",
                denseBytes / 1024, compressed / 1024,
                static_cast<double>(denseBytes) / static_cast<double>(compressed));

    // Content survives the round trip.
    CHECK(layer.pixel(0, 0) == (Rgba8{255, 255, 255, 255}));
    CHECK(layer.pixel(5, 5) == (Rgba8{0, 0, 0, 255}));
}

} // namespace

int main() {
    testCodecRoundTrip();
    testCodecWorstCaseIsBounded();
    testCodecRejectsTruncatedPayload();
    testCompressionPreservesContent();
    testUnlimitedBudgetNeverEvicts();
    testEvictionRespectsBudget();
    testEvictionPrefersColdTiles();
    testMangaPageMemoryProfile();
    return check::report("residency");
}
