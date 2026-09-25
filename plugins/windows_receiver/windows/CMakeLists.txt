# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "windows_receiver")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "windows_receiver_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "windows_receiver_plugin.cpp"
  "windows_receiver_plugin.h"
  "receiver.cpp"
  "receiver.h"
  "h264_decoder.cpp"
  "h264_decoder.h"
  "nv12.h"
)

# The shared core, built as lenny_core.dll. Dart FFI opens this same DLL, so the plugin and Dart share sessions.
set(LENNY_SHARED ON CACHE BOOL "" FORCE)
set(LENNY_BUILD_TESTS OFF CACHE BOOL "" FORCE)
# Flutter builds plugins through a link in app/windows/flutter/ephemeral, which CMake doesn't resolve on Windows,
# so locate /core from the app instead (CMAKE_SOURCE_DIR = app/windows). Monorepo layout; override if it moves.
set(LENNY_CORE_DIR "${CMAKE_SOURCE_DIR}/../../core" CACHE PATH "Path to Lenny's /core")
add_subdirectory("${LENNY_CORE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/lenny_core")

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/windows_receiver/windows_receiver_plugin_c_api.h"
  "windows_receiver_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_20)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin lenny_core
  mfplat mfuuid wmcodecdspuuid)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(windows_receiver_bundled_libraries
  $<TARGET_FILE:lenny_core>
  PARENT_SCOPE
)
