#include "core/tile_codec.h"

#include <cstring>

namespace mc {
namespace {

inline constexpr size_t kPixelCount = kTileBytes / 4;

// memcpy rather than a reinterpret_cast to uint32_t*. The cast would break
// strict aliasing, and compilers turn these four-byte copies into single loads
// anyway, so it costs nothing.
inline uint32_t loadPixel(const uint8_t* base, size_t index) {
    uint32_t value;
    std::memcpy(&value, base + index * 4, 4);
    return value;
}

inline void storePixel(uint8_t* base, size_t index, uint32_t value) {
    std::memcpy(base + index * 4, &value, 4);
}

inline void appendPixel(std::vector<uint8_t>& out, uint32_t value) {
    const size_t at = out.size();
    out.resize(at + 4);
    std::memcpy(out.data() + at, &value, 4);
}

} // namespace

std::vector<uint8_t> PixelRunCodec::encode(const uint8_t* tile) const {
    std::vector<uint8_t> out;
    // A flat tile lands near 2.5 KB. Reserving that avoids a handful of
    // reallocations in the common case without over-committing.
    out.reserve(4096);

    size_t i = 0;
    while (i < kPixelCount) {
        const uint32_t first = loadPixel(tile, i);

        size_t run = 1;
        while (i + run < kPixelCount && run < kMaxRun && loadPixel(tile, i + run) == first) {
            ++run;
        }

        if (run >= 2) {
            out.push_back(static_cast<uint8_t>(0x80 | (run - 1)));
            appendPixel(out, first);
            i += run;
            continue;
        }

        // No run here, so gather literals until one appears. Stopping at the
        // start of a run rather than swallowing it is what keeps long flat
        // spans cheap.
        const size_t start = i;
        size_t literals = 0;
        while (i < kPixelCount && literals < kMaxRun) {
            if (i + 1 < kPixelCount && loadPixel(tile, i) == loadPixel(tile, i + 1)) {
                break;
            }
            ++i;
            ++literals;
        }

        out.push_back(static_cast<uint8_t>(literals - 1));
        const size_t at = out.size();
        out.resize(at + literals * 4);
        std::memcpy(out.data() + at, tile + start * 4, literals * 4);
    }

    return out;
}

bool PixelRunCodec::decode(const uint8_t* data, size_t size, uint8_t* tileOut) const {
    size_t read = 0;
    size_t written = 0;

    while (written < kPixelCount) {
        if (read >= size) return false; // truncated

        const uint8_t header = data[read++];
        const size_t count = static_cast<size_t>(header & 0x7F) + 1;

        if (count > kPixelCount - written) return false; // would overrun the tile

        if ((header & 0x80) != 0) {
            if (read + 4 > size) return false;
            uint32_t value;
            std::memcpy(&value, data + read, 4);
            read += 4;
            for (size_t n = 0; n < count; ++n) {
                storePixel(tileOut, written + n, value);
            }
        } else {
            if (read + count * 4 > size) return false;
            std::memcpy(tileOut + written * 4, data + read, count * 4);
            read += count * 4;
        }
        written += count;
    }

    // Trailing bytes mean the payload does not match this tile — better to
    // reject it than to hand back pixels we are not sure about.
    return read == size;
}

} // namespace mc
