# The core is a Rust crate (Cargo.toml). This file only builds it with cargo and exposes it to CMake consumers
# (plugins/windows_receiver) as the shared-library target `lenny_core`, as before the port.
# Only exercised on Linux so far; the Windows build is pending a local session (see CLAUDE.md).
cmake_minimum_required(VERSION 3.20)
project(lenny_core NONE)

find_program(CARGO cargo REQUIRED)
set(LENNY_CARGO_DIR ${CMAKE_CURRENT_BINARY_DIR}/cargo)
set(out ${LENNY_CARGO_DIR}/release)
if(WIN32)
    set(lib ${out}/lenny_core.dll)
    set(implib ${out}/lenny_core.dll.lib)
elseif(APPLE)
    set(lib ${out}/liblenny_core.dylib)
else()
    set(lib ${out}/liblenny_core.so)
endif()

add_custom_target(lenny_core_cargo ALL
    COMMAND ${CARGO} build --release --lib --manifest-path ${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml
            --target-dir ${LENNY_CARGO_DIR}
    BYPRODUCTS ${lib} ${implib}
    USES_TERMINAL)
add_library(lenny_core SHARED IMPORTED GLOBAL)
set_target_properties(lenny_core PROPERTIES
    IMPORTED_LOCATION ${lib}
    INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_CURRENT_SOURCE_DIR}/include)
if(WIN32)
    set_target_properties(lenny_core PROPERTIES IMPORTED_IMPLIB ${implib})
endif()
add_dependencies(lenny_core lenny_core_cargo)
