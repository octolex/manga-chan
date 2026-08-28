# Tests are deliberately dependency-free: no FetchContent, so a network hiccup
# can never be the reason CI goes red. See check.h.

function(add_core_test name)
    add_executable(${name} ${name}.cpp)
    target_link_libraries(${name} PRIVATE core)
    target_include_directories(${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    add_test(NAME ${name} COMMAND ${name})
endfunction()

add_core_test(test_core_api)
add_core_test(test_tiles)
add_core_test(test_residency)
add_core_test(test_undo)
add_core_test(test_spill)
