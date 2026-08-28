#include "core/layer.h"

#include <cstring>
#include <utility>

namespace mc {

Layer::Layer(TileStore& store) : store_(&store) {}

Layer::~Layer() {
    releaseAll();
}

Layer::Layer(Layer&& other) noexcept
    : store_(other.store_), tiles_(std::move(other.tiles_)) {
    other.tiles_.clear();
}

Layer& Layer::operator=(Layer&& other) noexcept {
    if (this != &other) {
        releaseAll();
        store_ = other.store_;
        tiles_ = std::move(other.tiles_);
        other.tiles_.clear();
    }
    return *this;
}

void Layer::releaseAll() {
    if (store_ != nullptr) {
        for (const auto& [coord, id] : tiles_) {
            store_->release(id);
        }
    }
    tiles_.clear();
}

Layer Layer::clone() const {
    Layer copy(*store_);
    copy.tiles_ = tiles_;
    // Every shared tile gains a reference. None of them are copied — the first
    // write to any tile is what separates it.
    for (const auto& [coord, id] : copy.tiles_) {
        store_->retain(id);
    }
    return copy;
}

bool Layer::hasTile(TileCoord coord) const {
    return tiles_.find(coord) != tiles_.end();
}

TileId Layer::tileId(TileCoord coord) const {
    const auto it = tiles_.find(coord);
    return it == tiles_.end() ? kInvalidTile : it->second;
}

const uint8_t* Layer::readTile(TileCoord coord) const {
    const auto it = tiles_.find(coord);
    return it == tiles_.end() ? nullptr : store_->data(it->second);
}

uint8_t* Layer::writeTile(TileCoord coord) {
    const auto it = tiles_.find(coord);

    if (it == tiles_.end()) {
        const TileId id = store_->acquireBlank();
        tiles_.emplace(coord, id);
        return store_->mutableData(id);
    }

    // Shared with another layer or an undo record: separate it before writing,
    // or we would silently modify their pixels too.
    if (store_->refCount(it->second) > 1) {
        const TileId separated = store_->acquireCopy(it->second);
        store_->release(it->second);
        it->second = separated;
    }
    return store_->mutableData(it->second);
}

void Layer::adoptTile(TileCoord coord, TileId id) {
    if (id == kInvalidTile) {
        dropTile(coord);
        return;
    }
    store_->retain(id);
    const auto it = tiles_.find(coord);
    if (it == tiles_.end()) {
        tiles_.emplace(coord, id);
    } else {
        store_->release(it->second);
        it->second = id;
    }
}

void Layer::dropTile(TileCoord coord) {
    const auto it = tiles_.find(coord);
    if (it == tiles_.end()) return;
    store_->release(it->second);
    tiles_.erase(it);
}

void Layer::clear() {
    releaseAll();
}

Rgba8 Layer::pixel(int32_t x, int32_t y) const {
    const uint8_t* tile = readTile(tileForPixel(x, y));
    if (tile == nullptr) {
        return Rgba8{}; // untouched tiles read as transparent
    }
    const uint8_t* p = tile + byteOffsetWithinTile(x, y);
    return Rgba8{p[0], p[1], p[2], p[3]};
}

void Layer::setPixel(int32_t x, int32_t y, Rgba8 value) {
    uint8_t* tile = writeTile(tileForPixel(x, y));
    uint8_t* p = tile + byteOffsetWithinTile(x, y);
    p[0] = value.r;
    p[1] = value.g;
    p[2] = value.b;
    p[3] = value.a;
}

} // namespace mc
