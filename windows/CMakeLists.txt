cmake_minimum_required(VERSION 3.24)

# nib for Windows: one native executable over the shared C++ core.
#
#   . Scripts/windows/vsenv.ps1
#   pwsh Scripts/windows/fetch-engines.ps1
#   cmake -S windows -B windows/build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build windows/build
#
# Win32, Direct2D and DirectWrite only: no .NET, no framework, no runtime to
# install. A static CRT, so no Visual C++ redistributable either.

if(NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

project(nib VERSION 1.1.0 LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|arm64|aarch64" OR CMAKE_GENERATOR_PLATFORM MATCHES "ARM64")
    set(NIB_ARCH arm64)
else()
    set(NIB_ARCH x64)
endif()
set(NIB_VENDOR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/${NIB_ARCH}")

# The core's own tests are built and run from core/; here only the library.
set(NIB_CORE_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../core core)

add_executable(nib WIN32
    src/main.cpp
    src/app/app.cpp
    src/app/cli.cpp
    src/app/dispatch.cpp
    src/app/hotkeys.cpp
    src/app/settings.cpp
    src/app/startup.cpp
    src/app/tray.cpp
    src/app/health.cpp
    src/app/diagnostics.cpp
    src/text/clipboard.cpp
    src/text/keystroke.cpp
    src/text/uia.cpp
    src/text/text_target.cpp
    src/ui/gfx.cpp
    src/ui/surface.cpp
    src/ui/widgets.cpp
    src/ui/dialogs.cpp
    src/ui/suggestion_panel.cpp
    src/ui/control_panel.cpp
    src/inline/live_checker.cpp
    src/inline/overlay.cpp
    src/inline/fix_card.cpp
    src/inline/selection_bar.cpp
    src/inline/issue_badge.cpp
    src/inline/uia_watcher.cpp
    src/speech/audio_io.cpp
    src/speech/controllers.cpp
    src/speech/dictation_overlay.cpp
    resources/nib.rc
)
target_include_directories(nib PRIVATE src)
target_link_libraries(nib PRIVATE nibcore_static
    d2d1 dwrite windowscodecs dwmapi uxtheme comctl32 shcore
    uiautomationcore oleaut32 ole32 shell32 shlwapi user32 gdi32 advapi32
    winmm version wtsapi32 psapi)
target_compile_definitions(nib PRIVATE UNICODE _UNICODE NOMINMAX
    NIB_VERSION="${PROJECT_VERSION}" NIB_VERSION_W=L"${PROJECT_VERSION}")
if(MSVC)
    target_compile_options(nib PRIVATE /utf-8 /permissive- /W3)
    # The manifest in the .rc declares DPI awareness and common controls v6;
    # the linker's own would conflict with it.
    target_link_options(nib PRIVATE /MANIFEST:NO)
endif()

# Beside nib.exe, the layout an install has: ICU next to the executable, the
# engines under engines\. A build directory then runs exactly as installed.
file(GLOB NIB_ICU_RUNTIME "${NIB_VENDOR}/icu/bin/icu*.dll")
add_custom_command(TARGET nib POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${NIB_ICU_RUNTIME} $<TARGET_FILE_DIR:nib>
    COMMAND_EXPAND_LISTS)
