cmake_minimum_required(VERSION 3.20)
project(lenny_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Threads REQUIRED)

# Apps build it shared (one copy per process, so Dart FFI and Kotlin/C++ plugins share session handles).
# Tests need the internals, so they only build against the static library.
option(LENNY_SHARED "Build lenny_core as a shared library" OFF)
if(LENNY_SHARED)
    set(LENNY_LIB_TYPE SHARED)
else()
    set(LENNY_LIB_TYPE STATIC)
endif()

add_library(lenny_core ${LENNY_LIB_TYPE}
    src/wire.cpp
    src/session.cpp
    src/tcp_transport.cpp
    src/c_api.cpp)
target_include_directories(lenny_core PUBLIC include PRIVATE src)
target_link_libraries(lenny_core PRIVATE Threads::Threads)
if(WIN32)
    target_link_libraries(lenny_core PRIVATE ws2_32)
endif()
if(LENNY_SHARED)
    target_compile_definitions(lenny_core PRIVATE LENNY_BUILD_SHARED)
    set_target_properties(lenny_core PROPERTIES CXX_VISIBILITY_PRESET hidden)
endif()
if(MSVC)
    target_compile_options(lenny_core PRIVATE /W4 /permissive- /utf-8)
else()
    target_compile_options(lenny_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

option(LENNY_BUILD_TESTS "Build core tests" ON)
if(LENNY_BUILD_TESTS AND NOT LENNY_SHARED)
    enable_testing()
    add_executable(lenny_tests tests/main.cpp tests/test_wire.cpp tests/test_session.cpp)
    target_include_directories(lenny_tests PRIVATE src)
    target_link_libraries(lenny_tests PRIVATE lenny_core Threads::Threads)
    target_compile_definitions(lenny_tests PRIVATE
        LENNY_VECTORS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../protocol/vectors")
    if(MSVC)
        target_compile_options(lenny_tests PRIVATE /utf-8)
    endif()
    add_test(NAME lenny_tests COMMAND lenny_tests)

    add_executable(lenny_probe tools/probe.cpp)
    target_link_libraries(lenny_probe PRIVATE lenny_core)
endif()
