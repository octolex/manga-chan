# M0 keeps tests dependency-free on purpose: no FetchContent, so a network
# hiccup can never be the reason CI goes red. A real framework (doctest)
# arrives in M1 when the tile store gives us something worth testing properly.

add_executable(core_tests test_core_api.cpp)
target_link_libraries(core_tests PRIVATE core)

add_test(NAME core_tests COMMAND core_tests)
