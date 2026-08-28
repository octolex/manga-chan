#include "core/core_api.h"

#include <cstdio>
#include <cstring>

namespace {

int failures = 0;

void check(bool condition, const char* what) {
    if (condition) {
        std::printf("  ok   %s\n", what);
    } else {
        std::printf("  FAIL %s\n", what);
        ++failures;
    }
}

} // namespace

int main() {
    std::printf("core_api tests\n");

    check(core_version_string() != nullptr, "version string is non-null");
    check(std::strlen(core_version_string()) > 0, "version string is non-empty");
    check(core_build_info() != nullptr, "build info is non-null");
    check(core_self_test() == 0, "core self-test passes");

    if (failures == 0) {
        std::printf("all passed\n");
        return 0;
    }
    std::printf("%d failure(s)\n", failures);
    return 1;
}
