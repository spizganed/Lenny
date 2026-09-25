cmake_minimum_required(VERSION 3.20)
project(lenny_android LANGUAGES CXX)

set(LENNY_SHARED ON CACHE BOOL "" FORCE)
set(LENNY_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../core ${CMAKE_BINARY_DIR}/lenny_core)

add_library(lenny_jni SHARED lenny_jni.cpp)
target_link_libraries(lenny_jni PRIVATE lenny_core log)
target_compile_features(lenny_jni PRIVATE cxx_std_20)
