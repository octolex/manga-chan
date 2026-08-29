#pragma once

//
//  compositor.h — deciding what has to be redrawn, and what does not.
//
//  While the user paints, the screen is:
//
//      under cache  +  the live layers  +  over cache
//
//  Everything below the layer being painted is flattened into one texture,
//  everything above into another, and only the layers in between are
//  recomposited each frame. A 200-layer document then costs the same per
//  painting frame as a three-layer one, and the caches are rebuilt only when
//  the selection or something outside the live set actually changes.
//
//  This is the single biggest source of Procreate's perceived speed — more so
//  than the brush engine, which is the part people assume is responsible.
//
//  The subtlety is clipping. A layer with clipToBelow draws only where the
//  layer beneath it has alpha, so it cannot be flattened into a cache that
//  does not contain that layer. Painting on a clip base changes every layer
//  clipped to it, and those layers therefore have to be live too. So the split
//  is not "below and above the active layer" but "below and above the active
//  layer's whole clip group" — a run starting at an unclipped layer and
//  continuing through every clipped layer stacked on it.
//
//  This header decides the split and detects when a cache has gone stale. The
//  flattening itself is GPU work and lives in the renderer; keeping the policy
//  here means it can be tested without a GPU.
//

#include "core/layer_stack.h"

#include <cstdint>
#include <vector>

namespace mc {

struct CompositePlan {
    /// Bottom to top, flattened into the under cache.
    std::vector<LayerId> under;

    /// The active layer's clip group. Recomposited every frame.
    std::vector<LayerId> live;

    /// Bottom to top, flattened into the over cache.
    std::vector<LayerId> over;

    LayerId activeLayer = kInvalidLayer;

    size_t layerCount() const { return under.size() + live.size() + over.size(); }
};

/// Splits the stack around the active layer's clip group.
///
/// With no active layer, everything lands in `under`: there is nothing being
/// painted, so nothing needs to stay live.
CompositePlan planComposite(const LayerStack& layers);

/// Fingerprint of one side of the split, covering everything that would change
/// what it renders to: membership and order, pixel content, and the properties
/// that affect compositing. Names are excluded — renaming a layer must not
/// throw away a cache.
uint64_t compositeSignature(const LayerStack& layers, const std::vector<LayerId>& ids);

/// Tracks whether the cached under/over textures are still usable.
///
/// Deliberately signature-based rather than a set of invalidation callbacks.
/// Callbacks have to enumerate every way a cache can go stale, and the failure
/// mode of a missed one is a stale image on screen that looks like a rendering
/// bug and is miserable to trace. Comparing a fingerprint cannot miss a case.
class CompositeCache {
public:
    /// Recomputes the plan and reports what changed. Call once per frame.
    void refresh(const LayerStack& layers);

    const CompositePlan& plan() const { return plan_; }

    /// True when the corresponding cache texture has to be rebuilt.
    bool underDirty() const { return underDirty_; }
    bool overDirty() const { return overDirty_; }

    /// Forces both caches to rebuild on the next refresh — after a resize, or
    /// anything else that invalidates the textures rather than their contents.
    void invalidate();

    /// How many rebuilds have happened. While drawing a single stroke this
    /// must not climb: if it does, something is invalidating the caches every
    /// frame and the whole optimisation has quietly stopped working.
    uint64_t underRebuildCount() const { return underRebuilds_; }
    uint64_t overRebuildCount() const { return overRebuilds_; }

private:
    CompositePlan plan_;
    uint64_t underSignature_ = 0;
    uint64_t overSignature_ = 0;
    bool hasCached_ = false;
    bool underDirty_ = true;
    bool overDirty_ = true;
    uint64_t underRebuilds_ = 0;
    uint64_t overRebuilds_ = 0;
};

} // namespace mc
