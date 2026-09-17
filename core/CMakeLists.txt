cmake_minimum_required(VERSION 3.24)

# Set before project(), which is when the compiler is probed and the value is
# baked into every object. nib supports macOS 13 Ventura, and a core built
# against a newer SDK default would link fine here and refuse to load there.
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "macOS deployment target")
endif()

project(nibcore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FetchContent)

# ICU is a hard dependency, not a convenience.
#
# SentenceSplitter uses enumerateSubstrings(.bySentences, .localized), which is
# ICU's sentence BreakIterator underneath, and WordDiff.tokenize asks for
# Unicode character properties. Reimplementing either by hand would be a
# different answer wearing the same name.
#
# Windows ships its own icu.dll at a version Microsoft chooses. Taking that one
# would mean nib underlining different sentences on the two platforms for
# reasons no one could see in the source, so the Windows build vendors its own
# copy rather than linking the system's.
find_package(ICU 76 COMPONENTS uc i18n data QUIET)
if(NOT ICU_FOUND)
    message(FATAL_ERROR
        "ICU 76+ not found. macOS: brew install icu4c and configure with "
        "-DICU_ROOT=$(brew --prefix icu4c). Container: apt-get install libicu-dev.")
endif()

# The implementation is an object library, and the shared library is a thin
# wrapper around it.
#
# Not ceremony. nibcore exports only its extern "C" ABI -- everything else is
# hidden, which is the whole point of a versioned boundary. That leaves the
# tests unable to link nib::tokenize, because the shared library genuinely does
# not offer it. Linking the objects instead lets the suite reach the
# implementation while the DLL keeps its narrow surface.
add_library(nibcore_obj OBJECT
    src/abi/abi_version.cpp
    src/abi/abi_text.cpp
    src/text/word_tokenize.cpp
    src/text/sentence_split.cpp
)
target_include_directories(nibcore_obj
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_definitions(nibcore_obj PRIVATE NIB_CORE_BUILDING)
target_link_libraries(nibcore_obj PUBLIC ICU::uc ICU::i18n ICU::data)


add_library(nibcore SHARED $<TARGET_OBJECTS:nibcore_obj>)
target_include_directories(nibcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(nibcore PRIVATE ICU::uc ICU::i18n ICU::data)

# Link llvm-mingw's C++ runtime into the DLL.
#
# Left shared, libnibcore.dll imports libc++.dll and libunwind.dll, and the
# installer would have to carry two more files whose only purpose is to satisfy
# a toolchain choice. Static costs a few hundred kilobytes once.
if(MINGW)
    target_link_options(nibcore PRIVATE -static -static-libgcc -static-libstdc++)
endif()

# An absolute install name during development.
#
# SwiftPM builds the app and the test bundle at different depths, so no single
# @executable_path rpath reaches core/build from both -- the test bundle sits
# four directories deeper and fails to load. Pointing at the build directory
# absolutely makes every locally built binary find it, and bundle.sh rewrites
# the name with install_name_tool when it copies the dylib into nib.app, which
# is the only build whose location is fixed.
if(APPLE)
    # BUILD_WITH_INSTALL_NAME_DIR as well: on its own INSTALL_NAME_DIR applies
    # only to an installed copy, and nothing here is ever installed.
    set_target_properties(nibcore PROPERTIES
        INSTALL_NAME_DIR "${CMAKE_CURRENT_BINARY_DIR}"
        BUILD_WITH_INSTALL_NAME_DIR TRUE)
endif()

# Tests are host-native and never cross-compiled: they exist to check the
# logic, which is identical on every target.
option(NIB_CORE_TESTS "Build the core test suite" ON)
if(NIB_CORE_TESTS AND NOT CMAKE_CROSSCOMPILING)
    FetchContent_Declare(Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG        v3.7.1)
    FetchContent_Declare(nlohmann_json
        GIT_REPOSITORY https://github.com/nlohmann/json.git
        GIT_TAG        v3.11.3)
    FetchContent_MakeAvailable(Catch2 nlohmann_json)

    add_executable(nibcore_tests
        tests/test_abi_version.cpp
        tests/golden_loader.cpp
        tests/test_word_tokenize.cpp
        tests/test_sentence_split.cpp
        tests/test_abi_text.cpp
    )
    target_link_libraries(nibcore_tests
        PRIVATE nibcore_obj Catch2::Catch2WithMain nlohmann_json::nlohmann_json
                ICU::uc ICU::i18n ICU::data)
    target_include_directories(nibcore_tests
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
    # The goldens sit at the repository root. Passed in rather than discovered,
    # so the suite does not depend on where it was invoked from.
    target_compile_definitions(nibcore_tests
        PRIVATE NIB_GOLDEN_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../goldens")

    include(CTest)
    include(Catch)
    catch_discover_tests(nibcore_tests)
endif()
