#pragma once

//
//  tile.h — the unit of canvas storage.
//
//  A layer is not a big rectangle of pixels. It is a sparse map from tile
//  coordinate to tile, so a layer that has only been painted in one corner
//  costs one tile rather than a full canvas.
//
//  This is the single decision that removes the layer cap. A 4096×4096 RGBA8
//  layer is 64 MB if stored densely, which is why Procreate computes a maximum
//  layer count from device RAM and canvas size. A typical illustration layer
//  actually touches 10–40% of its canvas, so storing only touched tiles is a
//  3–10× win before any paging is involved.
//
//  Note: these storage tiles are a different concept from the GPU's hardware
//  raster tiles (~32×32 imageblocks on Apple silicon). Do not conflate them.
//

#include <cstddef>
#include <cstdint>

namespace mc {

/// Tile edge length in pixels. 256×256 RGBA8 = 256 KB per tile.
/// 128 would give finer paging granularity at the cost of more bookkeeping;
/// worth benchmarking once the residency tiers exist.
inline constexpr int32_t kTileSize = 256;

inline constexpr int32_t kTileBytesPerPixel = 4; // RGBA8, premultiplied
inline constexpr size_t  kTileBytes =
    static_cast<size_t>(kTileSize) * kTileSize * kTileBytesPerPixel;

/// Position of a tile in the layer's infinite tile grid. Signed, so the canvas
/// can extend in any direction without an origin shift.
struct TileCoord {
    int32_t x = 0;
    int32_t y = 0;

    friend bool operator==(const TileCoord&, const TileCoord&) = default;
};

struct TileCoordHash {
    size_t operator()(const TileCoord& c) const noexcept {
        // splitmix64 over the packed pair. Tile coordinates are small and
        // highly clustered, and a naive hash would pile them into a handful of
        // buckets — the pathological case for an open-addressing map.
        uint64_t k = (static_cast<uint64_t>(static_cast<uint32_t>(c.x)) << 32)
                   |  static_cast<uint64_t>(static_cast<uint32_t>(c.y));
        k ^= k >> 30; k *= 0xbf58476d1ce4e5b9ULL;
        k ^= k >> 27; k *= 0x94d049bb133111ebULL;
        k ^= k >> 31;
        return static_cast<size_t>(k);
    }
};

/// Floor division, so that pixel -1 belongs to tile -1 rather than tile 0.
/// Plain integer division truncates toward zero and would map both -1 and +1
/// to tile 0, silently folding the canvas across its own origin.
inline int32_t tileIndexForPixel(int32_t pixel) noexcept {
    return pixel >= 0 ? pixel / kTileSize
                      : -(((-pixel) + kTileSize - 1) / kTileSize);
}

inline TileCoord tileForPixel(int32_t x, int32_t y) noexcept {
    return TileCoord{tileIndexForPixel(x), tileIndexForPixel(y)};
}

/// Offset of a pixel within its tile, always in [0, kTileSize).
inline int32_t pixelWithinTile(int32_t pixel) noexcept {
    const int32_t m = pixel % kTileSize;
    return m < 0 ? m + kTileSize : m;
}

/// Byte offset of a pixel inside a tile's buffer.
inline size_t byteOffsetWithinTile(int32_t x, int32_t y) noexcept {
    return (static_cast<size_t>(pixelWithinTile(y)) * kTileSize
          + static_cast<size_t>(pixelWithinTile(x))) * kTileBytesPerPixel;
}

/// One RGBA8 pixel, premultiplied.
struct Rgba8 {
    uint8_t r = 0, g = 0, b = 0, a = 0;
    friend bool operator==(const Rgba8&, const Rgba8&) = default;
};

} // namespace mc
