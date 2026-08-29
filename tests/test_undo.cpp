#include "check.h"

#include "core/layer.h"
#include "core/layer_stack.h"
#include "core/tile_store.h"
#include "core/undo.h"

#include <cstring>
#include <vector>

using namespace mc;

namespace {

const Rgba8 kRed{255, 0, 0, 255};
const Rgba8 kBlue{0, 0, 255, 255};
const Rgba8 kGreen{0, 255, 0, 255};

void testUndoRedoRoundTrip() {
    std::printf("undo/redo round trip\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    layer.setPixel(10, 10, kRed);

    undo.beginAction("Stroke");
    undo.willModify(id, TileCoord{0, 0});
    layer.setPixel(10, 10, kBlue);
    undo.commitAction();

    CHECK(layer.pixel(10, 10) == kBlue);
    CHECK(undo.canUndo());
    CHECK(!undo.canRedo());
    CHECK(undo.undoName() == "Stroke");

    CHECK(undo.undo());
    CHECK(layer.pixel(10, 10) == kRed);
    CHECK(undo.canRedo());

    CHECK(undo.redo());
    CHECK(layer.pixel(10, 10) == kBlue);
}

void testWillModifyForcesCopyOnWrite() {
    std::printf("willModify forces copy-on-write\n");

    // The mechanism the whole design rests on: taking a reference for history
    // is what makes the next write separate the tile instead of overwriting
    // the pixels the history is holding.
    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    layer.setPixel(10, 10, kRed);
    const TileId original = layer.tileId(TileCoord{0, 0});
    CHECK_EQ(store.refCount(original), 1);

    undo.beginAction("Stroke");
    undo.willModify(id, TileCoord{0, 0});
    CHECK_EQ(store.refCount(original), 2);   // history now holds one

    layer.setPixel(10, 10, kBlue);
    // The layer must have moved to a different tile, leaving the original
    // untouched for the history.
    CHECK(layer.tileId(TileCoord{0, 0}) != original);
    CHECK_EQ(store.refCount(original), 1);
    undo.commitAction();

    CHECK(undo.undo());
    CHECK_EQ(layer.tileId(TileCoord{0, 0}), original);
}

void testUndoOfTileCreation() {
    std::printf("undo of tile creation\n");

    // A tile that did not exist before must be removed by undo, not restored
    // as a tile full of transparent pixels — otherwise undo would silently
    // grow memory.
    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    CHECK_EQ(layer.tileCount(), 0);

    undo.beginAction("First stroke");
    undo.willModify(id, TileCoord{0, 0});
    layer.setPixel(10, 10, kRed);
    undo.commitAction();
    CHECK_EQ(layer.tileCount(), 1);

    CHECK(undo.undo());
    CHECK_EQ(layer.tileCount(), 0);
    CHECK(layer.pixel(10, 10) == Rgba8{});

    CHECK(undo.redo());
    CHECK_EQ(layer.tileCount(), 1);
    CHECK(layer.pixel(10, 10) == kRed);

    // And the cycle must be stable rather than drifting.
    CHECK(undo.undo());
    CHECK_EQ(layer.tileCount(), 0);
    CHECK(undo.redo());
    CHECK(layer.pixel(10, 10) == kRed);
}

void testMultipleActionsUnwindInOrder() {
    std::printf("multiple actions unwind in order\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    layer.setPixel(10, 10, kRed);

    undo.beginAction("Second");
    undo.willModify(id, TileCoord{0, 0});
    layer.setPixel(10, 10, kBlue);
    undo.commitAction();

    undo.beginAction("Third");
    undo.willModify(id, TileCoord{0, 0});
    layer.setPixel(10, 10, kGreen);
    undo.commitAction();

    CHECK_EQ(undo.undoDepth(), 2);
    CHECK(layer.pixel(10, 10) == kGreen);

    CHECK(undo.undo());
    CHECK(layer.pixel(10, 10) == kBlue);
    CHECK(undo.undo());
    CHECK(layer.pixel(10, 10) == kRed);
    CHECK(!undo.undo());   // nothing left

    CHECK(undo.redo());
    CHECK(layer.pixel(10, 10) == kBlue);
    CHECK(undo.redo());
    CHECK(layer.pixel(10, 10) == kGreen);
}

void testRepeatedWillModifyRecordsOnce() {
    std::printf("repeated willModify records once\n");

    // A stroke calls this for every dab. Recording each one would make undo
    // step back one dab at a time instead of one stroke at a time.
    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    layer.setPixel(10, 10, kRed);

    undo.beginAction("Stroke");
    for (int i = 0; i < 50; ++i) {
        undo.willModify(id, TileCoord{0, 0});
        layer.setPixel(10, 10, Rgba8{static_cast<uint8_t>(i), 0, 0, 255});
    }
    undo.commitAction();

    CHECK_EQ(undo.retainedTileCount(), 1);
    CHECK(undo.undo());
    CHECK(layer.pixel(10, 10) == kRed);
}

void testEmptyActionIsDiscarded() {
    std::printf("empty action is discarded\n");

    // Otherwise the user presses undo and nothing visible happens.
    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    undo.beginAction("Nothing happened");
    undo.commitAction();
    CHECK(!undo.canUndo());
    CHECK_EQ(undo.undoDepth(), 0);
}

void testNewActionClearsRedo() {
    std::printf("new action clears redo\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    layer.setPixel(10, 10, kRed);

    undo.beginAction("Blue");
    undo.willModify(id, TileCoord{0, 0});
    layer.setPixel(10, 10, kBlue);
    undo.commitAction();

    CHECK(undo.undo());
    CHECK(undo.canRedo());

    undo.beginAction("Green");
    undo.willModify(id, TileCoord{0, 0});
    layer.setPixel(10, 10, kGreen);
    undo.commitAction();

    CHECK(!undo.canRedo());
    CHECK_EQ(undo.redoDepth(), 0);
}

void testAbortReleasesEverything() {
    std::printf("abort releases everything\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers);

    layer.setPixel(10, 10, kRed);
    const TileId original = layer.tileId(TileCoord{0, 0});

    undo.beginAction("Cancelled stroke");
    undo.willModify(id, TileCoord{0, 0});
    CHECK_EQ(store.refCount(original), 2);

    undo.abortAction();
    CHECK_EQ(store.refCount(original), 1);
    CHECK(!undo.canUndo());
}

void testHistoryIsBounded() {
    std::printf("history is bounded\n");

    // Without a cap, a long session grows the history until the app is killed.
    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers, 10);

    for (int i = 0; i < 40; ++i) {
        undo.beginAction("Stroke");
        undo.willModify(id, TileCoord{i, 0});
        layer.setPixel(i * kTileSize, 0, kRed);
        undo.commitAction();
    }

    CHECK_EQ(undo.undoDepth(), 10);
    // Dropped actions must release their tiles, or bounding the depth would
    // bound nothing that matters.
    CHECK(undo.retainedTileCount() <= 10);
}

void testClearReleasesTiles() {
    std::printf("clear releases tiles\n");

    TileStore store;
    LayerStack layers(store);
    UndoStack undo(store, layers);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);

    layer.setPixel(10, 10, kRed);

    undo.beginAction("Stroke");
    undo.willModify(id, TileCoord{0, 0});
    layer.setPixel(10, 10, kBlue);
    undo.commitAction();

    CHECK_EQ(store.liveTileCount(), 2); // history tile + layer tile
    undo.clear();
    CHECK_EQ(store.liveTileCount(), 1); // only the layer's

    layers.remove(id);
    CHECK_EQ(store.liveTileCount(), 0);
}

void testHistoryForDeletedLayerIsInert() {
    std::printf("history for a deleted layer is inert\n");

    // The reason edits name layers by id rather than by pointer. History
    // routinely outlives the layers it refers to: the user deletes a layer and
    // then presses undo. With a pointer this was a use-after-free waiting for
    // exactly that sequence.
    TileStore store;
    LayerStack layers(store);
    UndoStack undo(store, layers);

    const LayerId doomed = layers.add("Doomed");
    const LayerId keeper = layers.add("Keeper");

    layers.pixels(doomed)->setPixel(10, 10, kRed);
    layers.pixels(keeper)->setPixel(10, 10, kRed);

    undo.beginAction("Stroke across both");
    undo.willModify(doomed, TileCoord{0, 0});
    undo.willModify(keeper, TileCoord{0, 0});
    layers.pixels(doomed)->setPixel(10, 10, kBlue);
    layers.pixels(keeper)->setPixel(10, 10, kBlue);
    undo.commitAction();

    CHECK(layers.remove(doomed));
    CHECK_EQ(layers.count(), 1);

    // Undo must still work, applying only to the layer that survives.
    CHECK(undo.undo());
    CHECK(layers.pixels(keeper)->pixel(10, 10) == kRed);
    CHECK(layers.pixels(doomed) == nullptr);

    // And redo must not resurrect anything or corrupt the survivor.
    CHECK(undo.redo());
    CHECK(layers.pixels(keeper)->pixel(10, 10) == kBlue);
}

void testDeepHistoryMemoryProfile() {
    std::printf("deep history memory profile\n");

    // A realistic session: a 4096x4096 page, 100 strokes, each touching two
    // tiles. Snapshotting whole layers would cost 100 x 64 MB.
    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Layer 1");
    Layer& layer = *layers.pixels(id);
    UndoStack undo(store, layers, 250);

    std::vector<uint8_t> art(kTileBytes);
    for (size_t i = 0; i < kTileBytes; i += 4) {
        art[i] = art[i + 1] = art[i + 2] = 255;
        art[i + 3] = 255;
    }
    for (int32_t ty = 0; ty < 16; ++ty) {
        for (int32_t tx = 0; tx < 16; ++tx) {
            std::memcpy(layer.writeTile(TileCoord{tx, ty}), art.data(), kTileBytes);
        }
    }

    for (int i = 0; i < 100; ++i) {
        undo.beginAction("Stroke");
        const TileCoord a{i % 16, (i / 16) % 16};
        const TileCoord b{(i + 1) % 16, (i / 16) % 16};
        undo.willModify(id, a);
        undo.willModify(id, b);
        layer.setPixel(a.x * kTileSize + 5, a.y * kTileSize + 5, kRed);
        layer.setPixel(b.x * kTileSize + 5, b.y * kTileSize + 5, kRed);
        undo.commitAction();
    }

    const size_t retained = undo.retainedTileCount();
    CHECK_EQ(undo.undoDepth(), 100);
    CHECK(retained > 0);

    // Compress the history, which is exactly what eviction would do to tiles
    // nobody is drawing on.
    for (int32_t ty = 0; ty < 16; ++ty) {
        for (int32_t tx = 0; tx < 16; ++tx) {
            store.compressTile(layer.tileId(TileCoord{tx, ty}));
        }
    }
    store.setResidentBudget(8 * kTileBytes);
    store.evictToBudget();

    const size_t snapshotCost = size_t(100) * 4096 * 4096 * 4;
    const size_t actualCost = store.residentBytes() + store.compressedBytes();
    CHECK(actualCost < snapshotCost / 1000);

    std::printf("  100 undo steps: %zu tiles retained, %zu KB total\n",
                retained, actualCost / 1024);
    std::printf("  layer snapshots would cost %zu MB\n",
                snapshotCost / (1024 * 1024));

    // And it must still actually work after all that paging.
    CHECK(undo.undo());
    CHECK(undo.undo());
}

} // namespace

int main() {
    testUndoRedoRoundTrip();
    testWillModifyForcesCopyOnWrite();
    testUndoOfTileCreation();
    testMultipleActionsUnwindInOrder();
    testRepeatedWillModifyRecordsOnce();
    testEmptyActionIsDiscarded();
    testNewActionClearsRedo();
    testAbortReleasesEverything();
    testHistoryIsBounded();
    testClearReleasesTiles();
    testHistoryForDeletedLayerIsInert();
    testDeepHistoryMemoryProfile();
    return check::report("undo");
}
