cmake_minimum_required(VERSION 3.16)
project(CS171-assignment4 LANGUAGES C CXX)
# cmake_policy(SET CMP0135 NEW)

if(CMAKE_VERSION VERSION_GREATER_EQUAL "4.0")
  if(NOT DEFINED CMAKE_POLICY_VERSION_MINIMUM OR
    CMAKE_POLICY_VERSION_MINIMUM VERSION_LESS "3.5")
    set(CMAKE_POLICY_VERSION_MINIMUM "3.5")
  endif()
endif()

find_program(CCACHE_FOUND ccache)
if(CCACHE_FOUND)
  set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE ccache)
  set_property(GLOBAL PROPERTY RULE_LAUNCH_LINK ccache)
endif(CCACHE_FOUND)

option(USE_EMBREE "Enable embree4 as acceleration structure" OFF)
set(USE_SANITIZER
  ""
  CACHE
  STRING
  "Compile with a sanitizer. Options are: Address, Memory, MemoryWithOrigins, Undefined, Thread, Leak, 'Address;Undefined', CFI"
)

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)

# Include CPM
include(data/CPM.cmake)

# Suppress implicit type conversion error
# since most of them are emitted by Properties, which is indeed safe
if (MSVC)
	add_compile_options(/wd4244) # Disable warning C4244
	add_compile_options(/wd4267)
	add_compile_options(/wd4359)
endif()

# Include cmake scripts
CPMAddPackage("gh:StableCoder/cmake-scripts#24.04.1")
include(${cmake-scripts_SOURCE_DIR}/sanitizers.cmake)
include(${cmake-scripts_SOURCE_DIR}/formatting.cmake)

include("${PROJECT_SOURCE_DIR}/data/ext.cmake")
add_subdirectory(src/)

enable_testing()
add_subdirectory(tests/)
