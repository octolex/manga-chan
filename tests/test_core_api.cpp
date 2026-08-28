#include "check.h"

#include "core/core_api.h"

#include <cstring>

int main() {
    std::printf("core_api\n");

    CHECK(core_version_string() != nullptr);
    CHECK(std::strlen(core_version_string()) > 0);
    CHECK(core_build_info() != nullptr);
    CHECK_EQ(core_self_test(), 0);

    return check::report("core_api");
}
