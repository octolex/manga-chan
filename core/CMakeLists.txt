add_library(core STATIC
    src/blend.cpp
    src/blend_api.cpp
    src/canvas_api.cpp
    src/core_api.cpp
    src/tile_codec.cpp
    src/layer.cpp
    src/layer_stack.cpp
    src/tile_spill.cpp
    src/tile_store.cpp
    src/undo.cpp
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
