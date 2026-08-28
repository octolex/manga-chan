cmake_minimum_required(VERSION 3.24)

project(MangaChan
    VERSION 0.0.1
    DESCRIPTION "Manga-Chan — manga-oriented iPad drawing app"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Predictable output locations. The iOS app project links against
# ${CMAKE_BINARY_DIR}/lib/libcore.a, so this must stay stable.
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# Engine core: platform-agnostic, no graphics API. Builds for Windows and iOS.
add_subdirectory(core)

# Tests only make sense on the host, never in an iOS cross-build.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    enable_testing()
    add_subdirectory(tests)
endif()
