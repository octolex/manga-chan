#pragma once

//
//  layer_stack.h — the ordered stack of layers that makes up a drawing.
//
//  Layers are addressed by a stable `LayerId`, never by pointer or index.
//  Indices shift when layers are reordered and pointers dangle when layers are
//  deleted, and the undo history outlives both of those events — a history
//  entry recorded against a pointer would be a use-after-free waiting for the
//  user to delete a layer and press undo.
//
//  Order runs bottom to top: index 0 is the backmost layer, which is the order
//  the compositor walks and the reverse of how a layers panel displays them.
//

#include "core/layer.h"
#include "core/tile_store.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mc {

using LayerId = uint32_t;
inline constexpr LayerId kInvalidLayer = 0;

enum class BlendMode : uint8_t {
    Normal = 0,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    ColorDodge,
    ColorBurn,
    HardLight,
    SoftLight,
    Difference,
    Exclusion,
    Count
};

const char* blendModeName(BlendMode mode);

struct LayerInfo {
    std::string name;
    float opacity = 1.0f;
    BlendMode blend = BlendMode::Normal;
    bool visible = true;
    bool locked = false;

    /// Draw only where the layer beneath has pixels.
    ///
    /// Load-bearing for manga rather than a nicety: flats, tones and shading
    /// all clip to the line art layer, and doing that by hand with selections
    /// is most of the tedium the pipeline is supposed to remove.
    bool clipToBelow = false;
};

class LayerStack {
public:
    explicit LayerStack(TileStore& store);
    ~LayerStack();

    LayerStack(const LayerStack&) = delete;
    LayerStack& operator=(const LayerStack&) = delete;

    /// Adds an empty layer on top and makes it active.
    LayerId add(std::string name);

    /// Inserts at `index`, clamped to the current size. 0 is the bottom.
    LayerId insert(std::string name, size_t index);

    /// Duplicates a layer, sharing its tiles copy-on-write, so duplicating a
    /// fully painted layer costs nothing until one of the two is edited.
    LayerId duplicate(LayerId id);

    bool remove(LayerId id);

    /// Moves a layer to a new position in the stack.
    bool move(LayerId id, size_t toIndex);

    size_t count() const { return entries_.size(); }
    bool empty() const { return entries_.empty(); }

    /// Layer at a z-order position, or kInvalidLayer if out of range.
    LayerId at(size_t index) const;

    /// Position of a layer, or -1 if it is not in the stack.
    int indexOf(LayerId id) const;

    bool contains(LayerId id) const { return indexOf(id) >= 0; }

    /// Pixel data, or nullptr if the layer does not exist. Undo relies on the
    /// null return: a history entry for a deleted layer is skipped rather than
    /// following a dead pointer.
    Layer* pixels(LayerId id);
    const Layer* pixels(LayerId id) const;

    LayerInfo* info(LayerId id);
    const LayerInfo* info(LayerId id) const;

    LayerId active() const { return active_; }
    bool setActive(LayerId id);

    /// Total tiles held across every layer, for memory instrumentation.
    size_t totalTileCount() const;

private:
    struct Entry {
        LayerId id = kInvalidLayer;
        LayerInfo info;
        std::unique_ptr<Layer> pixels;
    };

    Entry* find(LayerId id);
    const Entry* find(LayerId id) const;

    TileStore* store_;
    std::vector<Entry> entries_;   // bottom to top
    LayerId nextId_ = 1;           // 0 is reserved for kInvalidLayer
    LayerId active_ = kInvalidLayer;
};

} // namespace mc
