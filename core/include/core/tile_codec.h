#pragma once

//
//  tile_codec.h — compression for tiles that are not currently being drawn on.
//
//  The residency design needs cold tiles to shrink, not disappear. A codec
//  here trades CPU time for RAM: a tile that has not been touched recently is
//  encoded, its 256 KB pixel buffer released, and it is decoded again on the
//  next access.
//
//  Why run-length encoding of whole pixels, specifically:
//
//    · Canvas tiles are overwhelmingly flat. Blank regions, paper white, flat
//      fills and screentone all compress to almost nothing, and those are the
//      majority of tiles in a manga page.
//    · Worst case is bounded and tiny. Literal packets cap the overhead at
//      roughly 0.2% on incompressible data, so nothing ever gets *bigger* in
//      any way that matters.
//    · Zero dependencies, so CI can never fail because a download did.
//
//  It is not the final answer. LZ4 or LZFSE will beat it on painted, textured
//  content, and the interface exists so that swapping the implementation is a
//  one-line change once there is real content to benchmark against.
//

#include "core/tile.h"

#include <cstdint>
#include <vector>

namespace mc {

class TileCodec {
public:
    virtual ~TileCodec() = default;

    /// Encodes exactly kTileBytes from `tile`.
    virtual std::vector<uint8_t> encode(const uint8_t* tile) const = 0;

    /// Decodes into `tileOut`, which must have room for kTileBytes.
    /// Returns false if the payload is malformed or the wrong size.
    virtual bool decode(const uint8_t* data, size_t size, uint8_t* tileOut) const = 0;

    virtual const char* name() const = 0;
};

/// Run-length encoding over 4-byte pixels.
///
/// Packet format, one byte of header then a payload:
///   0x80 | (n-1)   followed by one pixel   — that pixel repeated n times
///   0x00 | (n-1)   followed by n pixels    — n literal pixels
/// n is 1..128 in both cases.
class PixelRunCodec final : public TileCodec {
public:
    std::vector<uint8_t> encode(const uint8_t* tile) const override;
    bool decode(const uint8_t* data, size_t size, uint8_t* tileOut) const override;
    const char* name() const override { return "pixel-rle"; }

    static constexpr size_t kMaxRun = 128;
};

} // namespace mc
