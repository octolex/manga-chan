#pragma once

//
//  A deliberately tiny assertion helper.
//
//  No FetchContent, no external test framework, so a network hiccup can never
//  be the reason CI goes red. A real framework arrives when we need fixtures
//  and parameterised cases; until then this is enough and costs nothing.
//

#include <cstdio>

namespace check {

inline int failures = 0;
inline int checks = 0;

inline void expect(bool condition, const char* what) {
    ++checks;
    if (!condition) {
        ++failures;
        std::printf("  FAIL  %s\n", what);
    }
}

inline void expectEqual(long long actual, long long expected, const char* what) {
    ++checks;
    if (actual != expected) {
        ++failures;
        std::printf("  FAIL  %s  (got %lld, expected %lld)\n", what, actual, expected);
    }
}

inline int report(const char* suite) {
    if (failures == 0) {
        std::printf("%s: %d checks passed\n", suite, checks);
        return 0;
    }
    std::printf("%s: %d of %d checks FAILED\n", suite, failures, checks);
    return 1;
}

} // namespace check

#define CHECK(expr)            ::check::expect((expr), #expr)
#define CHECK_EQ(a, b)         ::check::expectEqual((long long)(a), (long long)(b), #a " == " #b)
