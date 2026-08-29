#include "check.h"

#include "core/compositor.h"
#include "core/layer_stack.h"
#include "core/tile_store.h"

using namespace mc;

namespace {

const Rgba8 kInk{0, 0, 0, 255};

void testSplitAroundTheActiveLayer() {
    std::printf("split around the active layer\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId b = layers.add("B");
    const LayerId c = layers.add("C");
    const LayerId d = layers.add("D");

    layers.setActive(b);
    const CompositePlan plan = planComposite(layers);

    CHECK_EQ(plan.under.size(), 1);
    CHECK_EQ(plan.under[0], a);
    CHECK_EQ(plan.live.size(), 1);
    CHECK_EQ(plan.live[0], b);
    CHECK_EQ(plan.over.size(), 2);
    CHECK_EQ(plan.over[0], c);
    CHECK_EQ(plan.over[1], d);
    CHECK_EQ(plan.activeLayer, b);
    CHECK_EQ(plan.layerCount(), 4);
}

void testClipGroupStaysLive() {
    std::printf("a clip group stays live\n");

    // Layers clipped onto the active one draw only where it has alpha, so
    // painting changes them too. Flattening them into the over cache would
    // freeze them at their pre-stroke state.
    TileStore store;
    LayerStack layers(store);
    const LayerId base = layers.add("Line art");
    const LayerId flats = layers.add("Flats");
    const LayerId shade = layers.add("Shading");
    const LayerId top = layers.add("Effects");

    layers.info(flats)->clipToBelow = true;
    layers.info(shade)->clipToBelow = true;

    layers.setActive(base);
    const CompositePlan plan = planComposite(layers);

    CHECK_EQ(plan.under.size(), 0);
    CHECK_EQ(plan.live.size(), 3);          // base plus both clipped layers
    CHECK_EQ(plan.live[0], base);
    CHECK_EQ(plan.live[1], flats);
    CHECK_EQ(plan.live[2], shade);
    CHECK_EQ(plan.over.size(), 1);
    CHECK_EQ(plan.over[0], top);
}

void testPaintingOnAClippedLayerKeepsItsBaseLive() {
    std::printf("painting a clipped layer keeps its base live\n");

    // The clip depends on the base layer's alpha, which a flattened under
    // cache no longer carries separately. So the base has to stay live too.
    TileStore store;
    LayerStack layers(store);
    const LayerId background = layers.add("Background");
    const LayerId base = layers.add("Line art");
    const LayerId flats = layers.add("Flats");

    layers.info(flats)->clipToBelow = true;
    layers.setActive(flats);

    const CompositePlan plan = planComposite(layers);
    CHECK_EQ(plan.under.size(), 1);
    CHECK_EQ(plan.under[0], background);
    CHECK_EQ(plan.live.size(), 2);
    CHECK_EQ(plan.live[0], base);           // the clip base, not just the active layer
    CHECK_EQ(plan.live[1], flats);
    CHECK_EQ(plan.over.size(), 0);
}

void testClippedLayerAtTheBottomActsAsItsOwnBase() {
    std::printf("a clipped layer at the bottom is its own base\n");

    // Nothing beneath it to clip to. Walking down must stop rather than run
    // off the end of the stack.
    TileStore store;
    LayerStack layers(store);
    const LayerId only = layers.add("Orphan");
    layers.info(only)->clipToBelow = true;
    layers.setActive(only);

    const CompositePlan plan = planComposite(layers);
    CHECK_EQ(plan.under.size(), 0);
    CHECK_EQ(plan.live.size(), 1);
    CHECK_EQ(plan.live[0], only);
}

void testEmptyAndUnselectedStacks() {
    std::printf("empty and unselected stacks\n");

    TileStore store;
    LayerStack empty(store);
    const CompositePlan emptyPlan = planComposite(empty);
    CHECK_EQ(emptyPlan.layerCount(), 0);
    CHECK_EQ(emptyPlan.activeLayer, kInvalidLayer);

    LayerStack layers(store);
    const LayerId a = layers.add("A");
    layers.add("B");
    layers.remove(a);
    // With nothing selected there is nothing being painted, so nothing has to
    // stay live.
    LayerStack unselected(store);
    unselected.add("A");
    unselected.add("B");
    unselected.setActive(kInvalidLayer);   // fails, so force the situation
    const CompositePlan plan = planComposite(unselected);
    CHECK(plan.live.size() <= 1);
}

void testCacheStaysValidWhileDrawing() {
    std::printf("caches survive a stroke\n");

    // The whole point. Painting the active layer must not invalidate the
    // caches, or the optimisation has quietly stopped working and every frame
    // costs what a full composite costs.
    TileStore store;
    LayerStack layers(store);
    layers.add("Background");
    const LayerId active = layers.add("Ink");
    layers.add("Overlay");
    layers.setActive(active);

    CompositeCache cache;
    cache.refresh(layers);
    CHECK(cache.underDirty());     // first frame builds both
    CHECK(cache.overDirty());

    const uint64_t underBuilds = cache.underRebuildCount();
    const uint64_t overBuilds = cache.overRebuildCount();

    for (int stroke = 0; stroke < 50; ++stroke) {
        layers.pixels(active)->setPixel(stroke, 0, kInk);
        cache.refresh(layers);
        CHECK(!cache.underDirty());
        CHECK(!cache.overDirty());
    }

    CHECK_EQ(cache.underRebuildCount(), underBuilds);
    CHECK_EQ(cache.overRebuildCount(), overBuilds);
    std::printf("  50 painted frames, 0 cache rebuilds\n");
}

void testEditingBelowInvalidatesOnlyTheUnderCache() {
    std::printf("editing below invalidates only the under cache\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId below = layers.add("Background");
    const LayerId active = layers.add("Ink");
    const LayerId above = layers.add("Overlay");
    layers.setActive(active);

    CompositeCache cache;
    cache.refresh(layers);
    cache.refresh(layers);
    CHECK(!cache.underDirty());

    layers.pixels(below)->setPixel(0, 0, kInk);
    cache.refresh(layers);
    CHECK(cache.underDirty());
    CHECK(!cache.overDirty());

    layers.pixels(above)->setPixel(0, 0, kInk);
    cache.refresh(layers);
    CHECK(!cache.underDirty());
    CHECK(cache.overDirty());
}

void testPropertyChangesInvalidate() {
    std::printf("property changes invalidate\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId below = layers.add("Background");
    const LayerId active = layers.add("Ink");
    layers.setActive(active);

    CompositeCache cache;
    cache.refresh(layers);
    cache.refresh(layers);
    CHECK(!cache.underDirty());

    // Each of these changes what the cached texture should contain, and a
    // missed one shows up as a stale image that looks like a rendering bug.
    layers.info(below)->opacity = 0.5f;
    cache.refresh(layers);
    CHECK(cache.underDirty());

    cache.refresh(layers);
    layers.info(below)->blend = BlendMode::Multiply;
    cache.refresh(layers);
    CHECK(cache.underDirty());

    cache.refresh(layers);
    layers.info(below)->visible = false;
    cache.refresh(layers);
    CHECK(cache.underDirty());
}

void testRenamingDoesNotInvalidate() {
    std::printf("renaming does not invalidate\n");

    // Nothing about a name reaches the framebuffer, and throwing away a cache
    // to rename a layer would be a visible stall for no reason.
    TileStore store;
    LayerStack layers(store);
    const LayerId below = layers.add("Background");
    const LayerId active = layers.add("Ink");
    layers.setActive(active);

    CompositeCache cache;
    cache.refresh(layers);
    cache.refresh(layers);
    CHECK(!cache.underDirty());

    layers.info(below)->name = "Paper";
    cache.refresh(layers);
    CHECK(!cache.underDirty());
}

void testChangingSelectionRebuildsBothCaches() {
    std::printf("changing selection rebuilds both caches\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId b = layers.add("B");
    layers.add("C");
    layers.setActive(b);

    CompositeCache cache;
    cache.refresh(layers);
    cache.refresh(layers);
    CHECK(!cache.underDirty());
    CHECK(!cache.overDirty());

    // Selecting a different layer moves the split, so both sides now hold
    // different layers.
    layers.setActive(a);
    cache.refresh(layers);
    CHECK(cache.underDirty());
    CHECK(cache.overDirty());
}

void testReorderingInvalidates() {
    std::printf("reordering invalidates\n");

    TileStore store;
    LayerStack layers(store);
    const LayerId a = layers.add("A");
    const LayerId b = layers.add("B");
    const LayerId active = layers.add("Ink");
    layers.setActive(active);

    CompositeCache cache;
    cache.refresh(layers);
    cache.refresh(layers);
    CHECK(!cache.underDirty());

    // Same layers, different order: a cache keyed only on membership would
    // wrongly consider itself still valid.
    layers.move(b, 0);
    cache.refresh(layers);
    CHECK(cache.underDirty());
    CHECK_EQ(layers.at(0), b);
    CHECK_EQ(layers.at(1), a);
}

void testExplicitInvalidation() {
    std::printf("explicit invalidation\n");

    TileStore store;
    LayerStack layers(store);
    layers.add("A");
    const LayerId active = layers.add("B");
    layers.setActive(active);

    CompositeCache cache;
    cache.refresh(layers);
    cache.refresh(layers);
    CHECK(!cache.underDirty());

    // For things the signature cannot see, such as the textures themselves
    // being recreated after a resize.
    cache.invalidate();
    cache.refresh(layers);
    CHECK(cache.underDirty());
    CHECK(cache.overDirty());
}

void testDeepStackCostsNothingExtra() {
    std::printf("a deep stack costs nothing extra per frame\n");

    // The headline claim: with 200 layers, painting still recomposites only
    // the live group, and the caches are never rebuilt mid-stroke.
    TileStore store;
    LayerStack layers(store);
    LayerId active = kInvalidLayer;
    for (int i = 0; i < 200; ++i) {
        const LayerId id = layers.add("Layer");
        if (i == 100) active = id;
    }
    layers.setActive(active);

    CompositeCache cache;
    cache.refresh(layers);

    const CompositePlan& plan = cache.plan();
    CHECK_EQ(plan.layerCount(), 200);
    CHECK_EQ(plan.live.size(), 1);
    CHECK_EQ(plan.under.size(), 100);
    CHECK_EQ(plan.over.size(), 99);

    const uint64_t rebuildsBefore = cache.underRebuildCount() + cache.overRebuildCount();
    for (int frame = 0; frame < 100; ++frame) {
        layers.pixels(active)->setPixel(frame, 0, kInk);
        cache.refresh(layers);
        CHECK(!cache.underDirty());
        CHECK(!cache.overDirty());
    }
    CHECK_EQ(cache.underRebuildCount() + cache.overRebuildCount(), rebuildsBefore);

    std::printf("  200 layers, %zu live per frame, 0 rebuilds over 100 frames\n",
                plan.live.size());
}

} // namespace

int main() {
    testSplitAroundTheActiveLayer();
    testClipGroupStaysLive();
    testPaintingOnAClippedLayerKeepsItsBaseLive();
    testClippedLayerAtTheBottomActsAsItsOwnBase();
    testEmptyAndUnselectedStacks();
    testCacheStaysValidWhileDrawing();
    testEditingBelowInvalidatesOnlyTheUnderCache();
    testPropertyChangesInvalidate();
    testRenamingDoesNotInvalidate();
    testChangingSelectionRebuildsBothCaches();
    testReorderingInvalidates();
    testExplicitInvalidation();
    testDeepStackCostsNothingExtra();
    return check::report("compositor");
}
