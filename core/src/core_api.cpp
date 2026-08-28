#include "core/core_api.h"

#include <memory>
#include <numeric>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr const char* kVersion = "0.0.1";

#ifdef NDEBUG
constexpr const char* kBuildInfo = "core " "0.0.1" " (release)";
#else
constexpr const char* kBuildInfo = "core " "0.0.1" " (debug)";
#endif

} // namespace

const char* core_version_string(void) {
    return kVersion;
}

const char* core_build_info(void) {
    return kBuildInfo;
}

int32_t core_self_test(void) {
    // Heap + std::string. Catches a missing or mismatched libc++.
    auto text = std::make_unique<std::string>("manga");
    if (*text != "manga") {
        return 1;
    }

    // Vector + <numeric>. Sum of 0..99 == 4950.
    std::vector<int> values(100);
    std::iota(values.begin(), values.end(), 0);
    if (std::accumulate(values.begin(), values.end(), 0) != 4950) {
        return 2;
    }

    // Hash map — this is the container the sparse tile store will lean on, so
    // it is worth proving it works on device before M1 depends on it.
    std::unordered_map<int64_t, int> tiles;
    for (int i = 0; i < 1000; ++i) {
        tiles[static_cast<int64_t>(i) * 7919] = i;
    }
    if (tiles.size() != 1000 || tiles[7919] != 1) {
        return 3;
    }

    return 0;
}
