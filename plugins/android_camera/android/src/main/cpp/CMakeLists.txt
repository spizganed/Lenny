cmake_minimum_required(VERSION 3.20)
project(lenny_android LANGUAGES CXX)

# The core is Rust: build.gradle.kts runs cargo-ndk first and passes the output dir. Dart FFI opens the same
# liblenny_core.so, so both share sessions.
set(LENNY_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../core)
add_library(lenny_core SHARED IMPORTED)
set_target_properties(lenny_core PROPERTIES
    IMPORTED_LOCATION ${LENNY_RUST_LIB_DIR}/${ANDROID_ABI}/liblenny_core.so
    INTERFACE_INCLUDE_DIRECTORIES ${LENNY_CORE_DIR}/include)

add_library(lenny_jni SHARED lenny_jni.cpp)
target_link_libraries(lenny_jni PRIVATE lenny_core log)
target_compile_features(lenny_jni PRIVATE cxx_std_20)
