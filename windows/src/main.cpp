// nib for Windows.
//
// One executable: run with an argument it is a command-line probe, run without
// one it lives in the notification area. A second launch hands over to the
// first -- it opens the control panel there -- rather than starting a second
// set of engines.
#include <windows.h>
#include <shellapi.h>

#include "app/app.hpp"
#include "app/cli.hpp"

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    // Apartment-threaded on the UI thread: the shell dialogs need it. The UI
    // Automation and audio threads initialise COM for themselves.
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    const int cli = nib::app::run_cli(argc, argv);
    if (cli >= 0) {
        LocalFree(argv);
        return cli;
    }

    bool background = false;
    bool after_restart = false;
    for (int i = 1; i < argc; ++i) {
        background |= std::wstring(argv[i]) == L"--background";
        after_restart |= std::wstring(argv[i]) == L"--after-restart";
    }
    LocalFree(argv);

    // One nib per user session.
    HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\nib.single-instance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        // A restart races the old instance on its way out; give it a moment.
        if (after_restart) {
            for (int i = 0; i < 50 && WaitForSingleObject(single, 100) == WAIT_TIMEOUT; ++i) {
            }
        } else {
            if (HWND running = FindWindowW(nib::app::App::window_class, nullptr)) {
                AllowSetForegroundWindow(ASFW_ANY);
                PostMessageW(running, nib::app::App::open_message, 0, 0);
            }
            return 0;
        }
    }

    int code = 0;
    {
        nib::app::App app;
        code = app.run(background);
    }
    if (single) {
        ReleaseMutex(single);
        CloseHandle(single);
    }
    CoUninitialize();
    return code;
}
