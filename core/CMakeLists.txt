cmake_minimum_required(VERSION 3.24)
project(nibcore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_library(nibcore SHARED
    src/abi/abi_version.cpp
)
target_include_directories(nibcore
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_definitions(nibcore PRIVATE NIB_CORE_BUILDING)

# Tests are host-native and never cross-compiled: they exist to check the
# logic, which is identical on every target.
option(NIB_CORE_TESTS "Build the core test suite" ON)
if(NIB_CORE_TESTS AND NOT CMAKE_CROSSCOMPILING)
    include(FetchContent)
    FetchContent_Declare(Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG        v3.7.1)
    FetchContent_MakeAvailable(Catch2)

    add_executable(nibcore_tests
        tests/test_abi_version.cpp
    )
    target_link_libraries(nibcore_tests PRIVATE nibcore Catch2::Catch2WithMain)
    target_include_directories(nibcore_tests
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
                ${CMAKE_CURRENT_SOURCE_DIR}/tests)

    include(CTest)
    include(Catch)
    catch_discover_tests(nibcore_tests)
endif()
