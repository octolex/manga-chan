#include "core/layer_stack.h"

#include <algorithm>
#include <utility>

namespace mc {

LayerStack::LayerStack(TileStore& store) : store_(&store) {}

LayerStack::~LayerStack() = default;

LayerStack::Entry* LayerStack::find(LayerId id) {
    if (id == kInvalidLayer) return nullptr;
    for (Entry& entry : entries_) {
        if (entry.id == id) return &entry;
    }
    return nullptr;
}

const LayerStack::Entry* LayerStack::find(LayerId id) const {
    return const_cast<LayerStack*>(this)->find(id);
}

LayerId LayerStack::add(std::string name) {
    return insert(std::move(name), entries_.size());
}

LayerId LayerStack::insert(std::string name, size_t index) {
    Entry entry;
    entry.id = nextId_++;
    entry.info.name = std::move(name);
    entry.pixels = std::make_unique<Layer>(*store_);

    const LayerId id = entry.id;
    entries_.insert(entries_.begin() + static_cast<std::ptrdiff_t>(std::min(index, entries_.size())),
                    std::move(entry));
    active_ = id;
    return id;
}

LayerId LayerStack::duplicate(LayerId id) {
    const Entry* source = find(id);
    if (source == nullptr) return kInvalidLayer;

    Entry entry;
    entry.id = nextId_++;
    entry.info = source->info;
    entry.info.name = source->info.name + " copy";
    // clone() shares tiles rather than copying them, so duplicating a fully
    // painted layer is free until one of the two is edited.
    entry.pixels = std::make_unique<Layer>(source->pixels->clone());

    const LayerId newId = entry.id;
    const int at = indexOf(id);
    entries_.insert(entries_.begin() + static_cast<std::ptrdiff_t>(at + 1), std::move(entry));
    active_ = newId;
    return newId;
}

bool LayerStack::remove(LayerId id) {
    const int index = indexOf(id);
    if (index < 0) return false;

    entries_.erase(entries_.begin() + index);

    if (active_ == id) {
        // Fall back to the layer that took its place, or the new topmost.
        if (entries_.empty()) {
            active_ = kInvalidLayer;
        } else {
            const size_t fallback = std::min(static_cast<size_t>(index), entries_.size() - 1);
            active_ = entries_[fallback].id;
        }
    }
    return true;
}

bool LayerStack::move(LayerId id, size_t toIndex) {
    const int from = indexOf(id);
    if (from < 0 || entries_.empty()) return false;

    const size_t to = std::min(toIndex, entries_.size() - 1);
    if (static_cast<size_t>(from) == to) return true;

    Entry entry = std::move(entries_[static_cast<size_t>(from)]);
    entries_.erase(entries_.begin() + from);
    entries_.insert(entries_.begin() + static_cast<std::ptrdiff_t>(to), std::move(entry));
    return true;
}

LayerId LayerStack::at(size_t index) const {
    return index < entries_.size() ? entries_[index].id : kInvalidLayer;
}

int LayerStack::indexOf(LayerId id) const {
    for (size_t i = 0; i < entries_.size(); ++i) {
        if (entries_[i].id == id) return static_cast<int>(i);
    }
    return -1;
}

Layer* LayerStack::pixels(LayerId id) {
    Entry* entry = find(id);
    return entry != nullptr ? entry->pixels.get() : nullptr;
}

const Layer* LayerStack::pixels(LayerId id) const {
    const Entry* entry = find(id);
    return entry != nullptr ? entry->pixels.get() : nullptr;
}

LayerInfo* LayerStack::info(LayerId id) {
    Entry* entry = find(id);
    return entry != nullptr ? &entry->info : nullptr;
}

const LayerInfo* LayerStack::info(LayerId id) const {
    const Entry* entry = find(id);
    return entry != nullptr ? &entry->info : nullptr;
}

bool LayerStack::setActive(LayerId id) {
    if (find(id) == nullptr) return false;
    active_ = id;
    return true;
}

size_t LayerStack::totalTileCount() const {
    size_t total = 0;
    for (const Entry& entry : entries_) {
        total += entry.pixels->tileCount();
    }
    return total;
}

} // namespace mc
