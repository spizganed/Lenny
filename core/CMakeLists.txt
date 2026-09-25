cmake_minimum_required(VERSION 3.20)
project(lenny_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Threads REQUIRED)

add_library(lenny_core STATIC
    src/wire.cpp
    src/session.cpp
    src/tcp_transport.cpp
    src/c_api.cpp)
target_include_directories(lenny_core PUBLIC include PRIVATE src)
target_link_libraries(lenny_core PRIVATE Threads::Threads)
if(WIN32)
    target_link_libraries(lenny_core PRIVATE ws2_32)
endif()
if(MSVC)
    target_compile_options(lenny_core PRIVATE /W4 /permissive- /utf-8)
else()
    target_compile_options(lenny_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

option(LENNY_BUILD_TESTS "Build core tests" ON)
if(LENNY_BUILD_TESTS)
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
endif()
