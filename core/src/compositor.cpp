#include "core/compositor.h"

#include <cstring>

namespace mc {
namespace {

/// splitmix64, mixing one value into a running hash.
inline uint64_t mix(uint64_t hash, uint64_t value) {
    uint64_t k = hash ^ (value + 0x9e3779b97f4a7c15ULL + (hash << 6) + (hash >> 2));
    k ^= k >> 30; k *= 0xbf58476d1ce4e5b9ULL;
    k ^= k >> 27; k *= 0x94d049bb133111ebULL;
    k ^= k >> 31;
    return k;
}

inline uint64_t bitsOf(float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

} // namespace

CompositePlan planComposite(const LayerStack& layers) {
    CompositePlan plan;
    plan.activeLayer = layers.active();

    const size_t count = layers.count();
    if (count == 0) {
        return plan;
    }

    const int activeIndex = layers.indexOf(plan.activeLayer);
    if (activeIndex < 0) {
        // Nothing is selected, so nothing is being painted and nothing needs
        // to stay live.
        for (size_t i = 0; i < count; ++i) {
            plan.under.push_back(layers.at(i));
        }
        plan.activeLayer = kInvalidLayer;
        return plan;
    }

    // Walk down to the base of the clip group: the nearest layer at or below
    // the active one that is not itself clipped. A clipped layer at the very
    // bottom has nothing to clip to, so it acts as its own base.
    size_t start = static_cast<size_t>(activeIndex);
    while (start > 0) {
        const LayerInfo* info = layers.info(layers.at(start));
        if (info == nullptr || !info->clipToBelow) break;
        --start;
    }

    // Then up through every layer clipped onto that base. These depend on the
    // group's content, so they cannot be flattened away either.
    size_t end = start;
    while (end + 1 < count) {
        const LayerInfo* info = layers.info(layers.at(end + 1));
        if (info == nullptr || !info->clipToBelow) break;
        ++end;
    }

    // Where the cacheable suffix begins.
    //
    // The under cache is always exact: compositing is sequential from the
    // bottom, so whatever accumulates below the live group IS the backdrop,
    // whatever blend modes produced it.
    //
    // The over cache is not. Flattening the layers above into one texture and
    // compositing it on top is only equivalent for source-over, which is
    // associative — a run of Normal layers at any opacity can be pre-flattened
    // onto transparent and then composited over the result below. A non-Normal
    // blend is not associative that way: Multiply above the layer being
    // painted depends on the actual backdrop, including the wet stroke, so
    // caching it would freeze it against stale pixels.
    //
    // So the over cache is the maximal all-Normal suffix, and anything below
    // that in the over region has to stay live.
    size_t overStart = count;
    while (overStart > end + 1) {
        const LayerInfo* info = layers.info(layers.at(overStart - 1));
        if (info == nullptr) break;
        // Invisible layers contribute nothing, so they never block caching.
        // A clipped layer is fine here because its base is scanned too.
        const bool cacheable = !info->visible || info->blend == BlendMode::Normal;
        if (!cacheable) break;
        --overStart;
    }

    // The cache must not begin with a clipped layer: it would be clipping to
    // the live result, which by definition is not in the cache.
    while (overStart < count) {
        const LayerInfo* info = layers.info(layers.at(overStart));
        if (info == nullptr || !info->clipToBelow) break;
        ++overStart;
    }

    for (size_t i = 0; i < start; ++i)              plan.under.push_back(layers.at(i));
    for (size_t i = start; i <= end; ++i)           plan.live.push_back(layers.at(i));
    for (size_t i = end + 1; i < overStart; ++i)    plan.live.push_back(layers.at(i));
    for (size_t i = overStart; i < count; ++i)      plan.over.push_back(layers.at(i));

    return plan;
}

uint64_t compositeSignature(const LayerStack& layers, const std::vector<LayerId>& ids) {
    // Seeded with the count so that an empty side and a side whose single
    // layer happens to hash to zero are distinguishable.
    uint64_t hash = mix(0x243F6A8885A308D3ULL, ids.size());

    for (const LayerId id : ids) {
        hash = mix(hash, id);

        const LayerInfo* info = layers.info(id);
        const Layer* pixels = layers.pixels(id);
        if (info == nullptr || pixels == nullptr) {
            // A layer named by the plan but missing from the stack is itself a
            // change worth invalidating on.
            hash = mix(hash, 0xDEADBEEFULL);
            continue;
        }

        // Everything that changes what this layer contributes. Name is
        // excluded on purpose: renaming must not discard a cache.
        hash = mix(hash, bitsOf(info->opacity));
        hash = mix(hash, static_cast<uint64_t>(info->blend));
        hash = mix(hash, info->visible ? 1u : 0u);
        hash = mix(hash, info->clipToBelow ? 1u : 0u);
        hash = mix(hash, pixels->contentRevision());
    }
    return hash;
}

void CompositeCache::refresh(const LayerStack& layers) {
    plan_ = planComposite(layers);

    const uint64_t under = compositeSignature(layers, plan_.under);
    const uint64_t over = compositeSignature(layers, plan_.over);

    underDirty_ = !hasCached_ || under != underSignature_;
    overDirty_ = !hasCached_ || over != overSignature_;

    if (underDirty_) ++underRebuilds_;
    if (overDirty_) ++overRebuilds_;

    underSignature_ = under;
    overSignature_ = over;
    hasCached_ = true;
}

void CompositeCache::invalidate() {
    hasCached_ = false;
    underDirty_ = true;
    overDirty_ = true;
}

} // namespace mc
