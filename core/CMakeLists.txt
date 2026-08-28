add_library(core STATIC
    src/core_api.cpp
    src/layer.cpp
    src/tile_store.cpp
)

target_include_directories(core PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

target_compile_features(core PUBLIC cxx_std_20)

if(MSVC)
    target_compile_options(core PRIVATE /W4)
else()
    target_compile_options(core PRIVATE -Wall -Wextra -Wpedantic)
endif()

set_target_properties(core PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    OUTPUT_NAME core
)
