#include "check.h"

#include "core/layer.h"
#include "core/tile.h"
#include "core/tile_store.h"

using namespace mc;

namespace {

void testTileCoordinates() {
    std::printf("tile coordinates\n");

    CHECK_EQ(tileIndexForPixel(0), 0);
    CHECK_EQ(tileIndexForPixel(255), 0);
    CHECK_EQ(tileIndexForPixel(256), 1);
    CHECK_EQ(tileIndexForPixel(512), 2);

    // Floor division, not truncation. Truncating would map both -1 and +1 to
    // tile 0 and fold the canvas across its own origin.
    CHECK_EQ(tileIndexForPixel(-1), -1);
    CHECK_EQ(tileIndexForPixel(-256), -1);
    CHECK_EQ(tileIndexForPixel(-257), -2);

    // Offsets stay inside the tile on both sides of the origin.
    CHECK_EQ(pixelWithinTile(0), 0);
    CHECK_EQ(pixelWithinTile(255), 255);
    CHECK_EQ(pixelWithinTile(256), 0);
    CHECK_EQ(pixelWithinTile(-1), 255);
    CHECK_EQ(pixelWithinTile(-256), 0);
}

void testSparsity() {
    std::printf("sparsity\n");

    TileStore store;
    Layer layer(store);

    CHECK_EQ(layer.tileCount(), 0);
    CHECK_EQ(store.residentBytes(), 0);

    layer.setPixel(10, 10, Rgba8{255, 0, 0, 255});
    CHECK_EQ(layer.tileCount(), 1);

    // Same tile: no new allocation.
    layer.setPixel(200, 200, Rgba8{0, 255, 0, 255});
    CHECK_EQ(layer.tileCount(), 1);

    // Different tile.
    layer.setPixel(300, 10, Rgba8{0, 0, 255, 255});
    CHECK_EQ(layer.tileCount(), 2);

    // The canvas extends in every direction, not just the positive quadrant.
    layer.setPixel(-5, -5, Rgba8{1, 2, 3, 255});
    CHECK_EQ(layer.tileCount(), 3);
    CHECK(layer.pixel(-5, -5) == (Rgba8{1, 2, 3, 255}));

    // Untouched regions read as transparent without allocating anything.
    CHECK(layer.pixel(9999, 9999) == Rgba8{});
    CHECK_EQ(layer.tileCount(), 3);
}

void testSparsityBeatsDenseStorage() {
    std::printf("sparse vs dense cost\n");

    // A diagonal across a 4096x4096 canvas. Dense RGBA8 storage would be
    // 64 MB; the diagonal only touches 16 of the 256 tiles.
    TileStore store;
    Layer layer(store);

    for (int32_t i = 0; i < 4096; ++i) {
        layer.setPixel(i, i, Rgba8{0, 0, 0, 255});
    }

    CHECK_EQ(layer.tileCount(), 16);

    const size_t denseBytes = size_t(4096) * 4096 * 4;
    CHECK(store.residentBytes() < denseBytes / 10);
    std::printf("  diagonal: %zu tiles, %zu KB (dense would be %zu KB)\n",
                layer.tileCount(), store.residentBytes() / 1024, denseBytes / 1024);
}

void testCopyOnWrite() {
    std::printf("copy-on-write\n");

    TileStore store;
    Layer original(store);
    original.setPixel(10, 10, Rgba8{255, 0, 0, 255});

    const size_t bytesBeforeClone = store.residentBytes();
    const TileId sharedTile = original.tileId(TileCoord{0, 0});
    CHECK_EQ(store.refCount(sharedTile), 1);

    Layer copy = original.clone();

    // Cloning copies no pixels — it only adds a reference.
    CHECK_EQ(store.residentBytes(), bytesBeforeClone);
    CHECK_EQ(store.refCount(sharedTile), 2);
    CHECK_EQ(copy.tileCount(), 1);
    CHECK(copy.pixel(10, 10) == (Rgba8{255, 0, 0, 255}));

    // Writing to the copy separates that tile and leaves the original alone.
    copy.setPixel(10, 10, Rgba8{0, 0, 255, 255});

    CHECK(original.pixel(10, 10) == (Rgba8{255, 0, 0, 255}));
    CHECK(copy.pixel(10, 10) == (Rgba8{0, 0, 255, 255}));
    CHECK_EQ(store.refCount(sharedTile), 1);
    CHECK_EQ(store.liveTileCount(), 2);
}

void testUndoPattern() {
    std::printf("per-tile undo\n");

    // The undo pattern: take a reference to the pre-modification tile, let the
    // layer separate on write, then put the old tile back to undo.
    TileStore store;
    Layer layer(store);
    layer.setPixel(10, 10, Rgba8{255, 0, 0, 255});

    const TileCoord coord{0, 0};
    const TileId beforeEdit = layer.tileId(coord);
    store.retain(beforeEdit); // the undo record's reference

    layer.setPixel(10, 10, Rgba8{0, 255, 0, 255});
    CHECK(layer.pixel(10, 10) == (Rgba8{0, 255, 0, 255}));

    layer.adoptTile(coord, beforeEdit);
    CHECK(layer.pixel(10, 10) == (Rgba8{255, 0, 0, 255}));

    store.release(beforeEdit); // undo record discarded
    CHECK_EQ(store.refCount(beforeEdit), 1);
}

void testTilePooling() {
    std::printf("tile pooling\n");

    TileStore store;
    {
        Layer layer(store);
        layer.setPixel(10, 10, Rgba8{255, 0, 0, 255});
        layer.setPixel(300, 300, Rgba8{255, 0, 0, 255});
        CHECK_EQ(store.liveTileCount(), 2);
    }

    // Layer destroyed: tiles are unreferenced but stay allocated for reuse,
    // because painting churns tiles and re-allocating 256 KB blocks
    // repeatedly is what fragments a heap.
    CHECK_EQ(store.liveTileCount(), 0);
    CHECK_EQ(store.pooledBufferCount(), 2);

    const size_t bytesAfterRelease = store.residentBytes();
    Layer reused(store);
    reused.setPixel(10, 10, Rgba8{9, 9, 9, 255});
    CHECK_EQ(store.residentBytes(), bytesAfterRelease); // came from the pool

    // Pooled tiles must come back blank, or a new layer would inherit the
    // previous one's pixels.
    CHECK(reused.pixel(200, 200) == Rgba8{});
}

void testClear() {
    std::printf("clear\n");

    TileStore store;
    Layer layer(store);
    layer.setPixel(10, 10, Rgba8{255, 0, 0, 255});
    layer.setPixel(300, 300, Rgba8{255, 0, 0, 255});
    CHECK_EQ(layer.tileCount(), 2);

    layer.clear();
    CHECK_EQ(layer.tileCount(), 0);
    CHECK_EQ(store.liveTileCount(), 0);
    CHECK(layer.pixel(10, 10) == Rgba8{});

    // Dropping a single tile returns that region to costing nothing, rather
    // than storing a tile full of transparent pixels.
    layer.setPixel(10, 10, Rgba8{1, 1, 1, 255});
    CHECK_EQ(layer.tileCount(), 1);
    layer.dropTile(TileCoord{0, 0});
    CHECK_EQ(layer.tileCount(), 0);
}

} // namespace

int main() {
    testTileCoordinates();
    testSparsity();
    testSparsityBeatsDenseStorage();
    testCopyOnWrite();
    testUndoPattern();
    testTilePooling();
    testClear();
    return check::report("tiles");
}
