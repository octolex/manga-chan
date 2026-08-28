#pragma once

//
//  layer.h — a sparse raster layer.
//
//  A layer holds only the tiles that have actually been painted. Untouched
//  regions cost nothing at all — not a pointer, not an entry in the map.
//  Layer extent is therefore unbounded in every direction, and memory is a
//  function of what has been drawn rather than of canvas dimensions.
//
//  Copying a layer copies no pixels. `clone()` retains the same tiles, and the
//  first write to any tile separates it. That is what makes both layer
//  duplication and undo snapshots cheap.
//

#include "core/tile.h"
#include "core/tile_store.h"

#include <unordered_map>

namespace mc {

class Layer {
public:
    using TileMap = std::unordered_map<TileCoord, TileId, TileCoordHash>;

    explicit Layer(TileStore& store);
    ~Layer();

    // Copying is spelled `clone()` so that sharing tiles is always a
    // deliberate act rather than something a stray pass-by-value does.
    Layer(const Layer&) = delete;
    Layer& operator=(const Layer&) = delete;

    Layer(Layer&& other) noexcept;
    Layer& operator=(Layer&& other) noexcept;

    /// Shares every tile with this layer. No pixels are copied; the tiles
    /// separate individually on first write to each.
    Layer clone() const;

    bool hasTile(TileCoord coord) const;
    size_t tileCount() const { return tiles_.size(); }
    const TileMap& tiles() const { return tiles_; }

    /// Read-only tile pixels, or nullptr if that tile has never been painted.
    const uint8_t* readTile(TileCoord coord) const;

    /// Tile pixels for writing. Creates the tile if absent, and separates it
    /// from any other layer or undo record sharing it.
    uint8_t* writeTile(TileCoord coord);

    /// Handle for the tile at `coord`, or kInvalidTile. Used by undo to take a
    /// reference to the pre-modification tile without copying it.
    TileId tileId(TileCoord coord) const;

    /// Installs `id` at `coord`, taking a reference. Used by undo to restore.
    void adoptTile(TileCoord coord, TileId id);

    /// Drops the tile at `coord` entirely, returning that region to costing
    /// nothing rather than storing transparent pixels.
    void dropTile(TileCoord coord);

    void clear();

    /// Pixel accessors in layer coordinates. Convenient, but per-pixel calls
    /// go through a hash lookup every time — real drawing works tile at a
    /// time. These exist for tests and for sparse edits.
    Rgba8 pixel(int32_t x, int32_t y) const;
    void setPixel(int32_t x, int32_t y, Rgba8 value);

private:
    void releaseAll();

    TileStore* store_;
    TileMap tiles_;
};

} // namespace mc
