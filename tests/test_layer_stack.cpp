#include "check.h"

#include "core/layer_stack.h"
#include "core/tile_store.h"

#include <string>

using namespace mc;

namespace {

const Rgba8 kRed{255, 0, 0, 255};
const Rgba8 kBlue{0, 0, 255, 255};

void testOrderingIsBottomToTop() {
    std::printf("ordering is bottom to top\n");

    TileStore store;
    LayerStack layers(store);

    const LayerId a = layers.add("Background");
    const LayerId b = layers.add("Line art");
    const LayerId c = layers.add("Tones");

    CHECK_EQ(layers.count(), 3);
    CHECK_EQ(layers.at(0), a);   // index 0 is the backmost layer
    CHECK_EQ(layers.at(2), c);
    CHECK_EQ(layers.indexOf(b), 1);
    CHECK_EQ(layers.indexOf(kInvalidLayer), -1);
    CHECK_EQ(layers.at(99), kInvalidLayer);

    // Newly added layers become active, which is what the user expects after
    // pressing "add layer".
    CHECK_EQ(layers.active(), c);
}

void testInsertAtIndex() {
    std::printf("insert at index\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId c = layers.add("C");
    const LayerId b = layers.insert("B", 1);

    CHECK_EQ(layers.at(0), a);
    CHECK_EQ(layers.at(1), b);
    CHECK_EQ(layers.at(2), c);

    // Out-of-range insertion clamps rather than failing, so a UI cannot put
    // the stack into an invalid state by miscounting.
    const LayerId d = layers.insert("D", 999);
    CHECK_EQ(layers.at(3), d);
}

void testMoveReorders() {
    std::printf("move reorders\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId b = layers.add("B");
    const LayerId c = layers.add("C");

    CHECK(layers.move(c, 0));
    CHECK_EQ(layers.at(0), c);
    CHECK_EQ(layers.at(1), a);
    CHECK_EQ(layers.at(2), b);

    CHECK(layers.move(c, 99));           // clamps to the top
    CHECK_EQ(layers.at(2), c);
    CHECK(!layers.move(kInvalidLayer, 0));
}

void testRemoveUpdatesActive() {
    std::printf("remove updates active\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId b = layers.add("B");

    CHECK_EQ(layers.active(), b);
    CHECK(layers.remove(b));

    // Something must stay selected, or the next stroke has nowhere to go.
    CHECK_EQ(layers.active(), a);
    CHECK(layers.pixels(b) == nullptr);
    CHECK(!layers.remove(b));

    CHECK(layers.remove(a));
    CHECK_EQ(layers.count(), 0);
    CHECK_EQ(layers.active(), kInvalidLayer);
}

void testRemoveReleasesTiles() {
    std::printf("remove releases tiles\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("A");
    layers.pixels(id)->setPixel(10, 10, kRed);
    layers.pixels(id)->setPixel(300, 300, kRed);
    CHECK_EQ(store.liveTileCount(), 2);

    layers.remove(id);
    CHECK_EQ(store.liveTileCount(), 0);
}

void testDuplicateSharesTiles() {
    std::printf("duplicate shares tiles\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId original = layers.add("Line art");
    layers.pixels(original)->setPixel(10, 10, kRed);

    const size_t bytesBefore = store.residentBytes();
    const TileId shared = layers.pixels(original)->tileId(TileCoord{0, 0});

    const LayerId copy = layers.duplicate(original);
    CHECK(copy != kInvalidLayer);
    CHECK_EQ(layers.count(), 2);
    CHECK_EQ(layers.indexOf(copy), 1);   // sits directly above its source

    // Duplicating a fully painted layer must not copy a single pixel until
    // one of the two is edited.
    CHECK_EQ(store.residentBytes(), bytesBefore);
    CHECK_EQ(store.refCount(shared), 2);
    CHECK(layers.pixels(copy)->pixel(10, 10) == kRed);

    // Editing the copy separates it and leaves the original alone.
    layers.pixels(copy)->setPixel(10, 10, kBlue);
    CHECK(layers.pixels(original)->pixel(10, 10) == kRed);
    CHECK(layers.pixels(copy)->pixel(10, 10) == kBlue);

    CHECK(layers.info(copy)->name == "Line art copy");
    CHECK(layers.duplicate(kInvalidLayer) == kInvalidLayer);
}

void testLayerProperties() {
    std::printf("layer properties\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId id = layers.add("Tones");

    LayerInfo* info = layers.info(id);
    CHECK(info != nullptr);
    CHECK(info->name == "Tones");
    CHECK_EQ(info->opacity, 1.0f);
    CHECK(info->blend == BlendMode::Normal);
    CHECK(info->visible);
    CHECK(!info->clipToBelow);

    info->opacity = 0.5f;
    info->blend = BlendMode::Multiply;
    info->clipToBelow = true;
    CHECK_EQ(layers.info(id)->opacity, 0.5f);
    CHECK(layers.info(id)->blend == BlendMode::Multiply);
    CHECK(layers.info(id)->clipToBelow);

    CHECK(layers.info(kInvalidLayer) == nullptr);
    CHECK(std::string(blendModeName(BlendMode::Multiply)) == "Multiply");
}

void testActiveSelection() {
    std::printf("active selection\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId b = layers.add("B");

    CHECK(layers.setActive(a));
    CHECK_EQ(layers.active(), a);
    CHECK(!layers.setActive(kInvalidLayer));
    CHECK_EQ(layers.active(), a);   // a failed selection must not clear it
    CHECK(layers.setActive(b));
}

void testTotalTileCount() {
    std::printf("total tile count\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId b = layers.add("B");

    layers.pixels(a)->setPixel(10, 10, kRed);
    layers.pixels(b)->setPixel(10, 10, kRed);
    layers.pixels(b)->setPixel(300, 10, kRed);

    CHECK_EQ(layers.totalTileCount(), 3);
}

} // namespace

int main() {
    testOrderingIsBottomToTop();
    testInsertAtIndex();
    testMoveReorders();
    testRemoveUpdatesActive();
    testRemoveReleasesTiles();
    testDuplicateSharesTiles();
    testLayerProperties();
    testActiveSelection();
    testTotalTileCount();
    return check::report("layer_stack");
}
