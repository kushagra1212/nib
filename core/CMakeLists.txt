cmake_minimum_required(VERSION 3.24)

# Set before project(), which is when the compiler is probed and the value is
# baked into every object. nib supports macOS 13 Ventura, and a core built
# against a newer SDK default would link fine here and refuse to load there.
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "macOS deployment target")
endif()

# A static CRT on Windows, so nib.exe needs no Visual C++ redistributable.
# Set before project() so it applies to every target, Catch2 included -- mixing
# /MT and /MD objects in one link is an error, not a warning.
if(NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

project(nibcore LANGUAGES CXX)

if(MSVC)
    # The sources are UTF-8 and contain literals such as U'’'. Without /utf-8,
    # MSVC reads them in the system code page and rejects the character
    # constant as "too many characters".
    add_compile_options(/utf-8 /permissive- /Zc:__cplusplus)
    # Not UNICODE/_UNICODE: Catch2's main switches to wmain under _UNICODE and
    # the console link then cannot find main. The Win32 code calls the W
    # functions by name instead.
    add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

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
#
# macOS vendors one too, for a different reason: Homebrew's icu4c@78 is built
# for macOS 15 and nib supports Ventura 13, so its dylibs link here and refuse
# to load there. Scripts/build-icu.sh produces the vendored copy; Homebrew's
# still works for a quick local build, with a deployment target that will not
# ship.
if(APPLE AND NOT DEFINED ICU_ROOT
   AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../macos/vendor/icu/lib/libicuuc.a")
    set(ICU_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../macos/vendor/icu")
    message(STATUS "Using the vendored ICU at ${ICU_ROOT}")
endif()

# Windows: Scripts/windows/fetch-engines.ps1 puts the official MSVC build of
# the same ICU version beside the other engines, per architecture.
if(WIN32 AND NOT DEFINED ICU_ROOT)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|arm64|aarch64" OR CMAKE_GENERATOR_PLATFORM MATCHES "ARM64")
        set(_nib_arch arm64)
    else()
        set(_nib_arch x64)
    endif()
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../windows/vendor/${_nib_arch}/icu/include")
        set(ICU_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../windows/vendor/${_nib_arch}/icu")
        message(STATUS "Using the vendored ICU at ${ICU_ROOT}")
    endif()
endif()

find_package(ICU 76 COMPONENTS uc i18n data QUIET)

# The ICU DLLs a Windows binary needs beside it. FindICU makes imported
# targets of unknown type, so CMake cannot work this out for itself.
if(WIN32 AND ICU_FOUND)
    get_filename_component(_icu_lib_dir "${ICU_UC_LIBRARY}" DIRECTORY)
    file(GLOB NIB_ICU_DLLS
        "${_icu_lib_dir}/../bin/icuuc[0-9]*.dll"
        "${_icu_lib_dir}/../bin/icuin[0-9]*.dll"
        "${_icu_lib_dir}/../bin/icudt[0-9]*.dll")
    set(NIB_ICU_DLLS "${NIB_ICU_DLLS}" CACHE INTERNAL "ICU runtime DLLs")
endif()
if(NOT ICU_FOUND)
    message(FATAL_ERROR
        "ICU 76+ not found. macOS: run Scripts/build-icu.sh, which builds it "
        "for the macOS version nib supports. Container: it is built into the "
        "image by docker/core-cross.Dockerfile.")
endif()

# The implementation is an object library, and the shared library is a thin
# wrapper around it.
#
# Not ceremony. nibcore exports only its extern "C" ABI -- everything else is
# hidden, which is the whole point of a versioned boundary. That leaves the
# tests unable to link nib::tokenize, because the shared library genuinely does
# not offer it. Linking the objects instead lets the suite reach the
# implementation while the DLL keeps its narrow surface.
# nlohmann/json is used by the core itself now -- LSP and llama-server both
# speak JSON -- not only by the tests. Header-only, so it costs nothing at
# runtime.
FetchContent_Declare(nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG        v3.11.3)
FetchContent_MakeAvailable(nlohmann_json)

add_library(nibcore_obj OBJECT
    src/abi/abi_version.cpp
    src/abi/abi_text.cpp
    src/text/word_tokenize.cpp
    src/text/sentence_split.cpp
    src/text/unicode.cpp
    src/lint/suggestion.cpp
    src/lint/edit_planner.cpp
    src/lint/word_diff.cpp
    src/lint/suggestion_filter.cpp
    src/lint/writing_score.cpp
    src/lint/message_framer.cpp
    src/rewrite/rewrite_mode.cpp
    src/rewrite/rewrite_text.cpp
    src/present/presentation.cpp
    src/speech/kokoro_vocab.cpp
    src/speech/speech_text.cpp
    src/speech/voice_pack.cpp
    src/speech/speech_state.cpp
    src/speech/practice.cpp
    src/speech/audio.cpp
)

# The engines are driven through processes, HTTP and the filesystem. Only the
# Windows implementations exist so far; macOS keeps its Swift engines until it
# adopts these.
if(WIN32)
    target_sources(nibcore_obj PRIVATE
        src/platform/win/process_win.cpp
        src/platform/win/http_win.cpp
        src/platform/win/net_win.cpp
        src/platform/win/paths_win.cpp
        src/support/log.cpp
        src/lint/lsp_client.cpp
        src/lint/harper_engine.cpp
        src/rewrite/rewrite_engine.cpp
        src/rewrite/model_checker.cpp
        src/rewrite/model_catalog.cpp
        src/speech/speech_catalog.cpp
        src/speech/dictation_text.cpp
        src/speech/engines.cpp
    )
    target_link_libraries(nibcore_obj PUBLIC winhttp ws2_32 shell32 ole32)
endif()

target_include_directories(nibcore_obj
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/src
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party
)
target_compile_definitions(nibcore_obj PRIVATE NIB_CORE_BUILDING)
target_link_libraries(nibcore_obj PUBLIC ICU::uc ICU::i18n ICU::data nlohmann_json::nlohmann_json)

# What nib.exe links on Windows: the same objects, statically, so the app is
# one executable plus ICU rather than an executable and a DLL of its own.
add_library(nibcore_static STATIC $<TARGET_OBJECTS:nibcore_obj>)
target_link_libraries(nibcore_static PUBLIC nibcore_obj)

add_library(nibcore SHARED $<TARGET_OBJECTS:nibcore_obj>)
target_include_directories(nibcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(nibcore PRIVATE ICU::uc ICU::i18n ICU::data)
if(WIN32)
    target_link_libraries(nibcore PRIVATE winhttp ws2_32 shell32 ole32)
endif()

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
    FetchContent_MakeAvailable(Catch2)

    add_executable(nibcore_tests
        tests/test_abi_version.cpp
        tests/golden_loader.cpp
        tests/test_word_tokenize.cpp
        tests/test_sentence_split.cpp
        tests/test_abi_text.cpp
        tests/test_word_diff.cpp
        tests/test_edit_planner.cpp
        tests/test_suggestion_filter.cpp
        tests/test_message_framer.cpp
        tests/test_presentation.cpp
    )
    # The speech suites read the same fixtures the Swift suite does.
    if(WIN32)
        target_sources(nibcore_tests PRIVATE tests/test_rewrite.cpp tests/test_engines.cpp
                                             tests/test_speech.cpp tests/test_speech_engines.cpp)
    endif()
    target_link_libraries(nibcore_tests
        PRIVATE nibcore_obj Catch2::Catch2WithMain nlohmann_json::nlohmann_json
                ICU::uc ICU::i18n ICU::data)
    target_include_directories(nibcore_tests
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
    # The goldens sit at the repository root. Passed in rather than discovered,
    # so the suite does not depend on where it was invoked from.
    target_compile_definitions(nibcore_tests
        PRIVATE NIB_GOLDEN_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../goldens")

    # ICU is DLLs on Windows. Copied beside the suite so it runs -- and so
    # test discovery, which runs it at build time, can.
    if(WIN32)
        add_custom_command(TARGET nibcore_tests POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    ${NIB_ICU_DLLS} $<TARGET_FILE_DIR:nibcore_tests>)
    endif()

    include(CTest)
    include(Catch)
    catch_discover_tests(nibcore_tests)
endif()
