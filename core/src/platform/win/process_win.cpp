#include "platform/process.hpp"

#include <windows.h>

#include <mutex>
#include <thread>

namespace nib::platform {
namespace {

std::wstring wide(const std::u16string& s) { return std::wstring(s.begin(), s.end()); }

// One job for every child nib starts. Created on first use and never closed:
// the handle closes when nib's process does, and that is what kills them.
HANDLE nib_job() {
    static HANDLE job = [] {
        HANDLE h = CreateJobObjectW(nullptr, nullptr);
        if (h) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(h, JobObjectExtendedLimitInformation, &info, sizeof info);
        }
        return h;
    }();
    return job;
}

struct Pipe {
    HANDLE read = nullptr;
    HANDLE write = nullptr;
};

// The child's end inheritable, nib's end not -- otherwise a second child
// inherits the first one's pipe and EOF never arrives.
Pipe make_pipe(bool child_reads) {
    SECURITY_ATTRIBUTES sa{sizeof sa, nullptr, TRUE};
    Pipe p;
    if (!CreatePipe(&p.read, &p.write, &sa, 0)) throw ProcessError("CreatePipe failed");
    SetHandleInformation(child_reads ? p.write : p.read, HANDLE_FLAG_INHERIT, 0);
    return p;
}

void close(HANDLE& h) {
    if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h);
    h = nullptr;
}

}  // namespace

uint32_t current_pid() { return GetCurrentProcessId(); }

std::u16string quote_argument(const std::u16string& arg) {
    if (!arg.empty() && arg.find_first_of(u" \t\n\v\"") == std::u16string::npos) return arg;
    std::u16string out = u"\"";
    for (size_t i = 0;; ++i) {
        size_t backslashes = 0;
        while (i < arg.size() && arg[i] == u'\\') { ++i; ++backslashes; }
        if (i == arg.size()) {
            out.append(backslashes * 2, u'\\');
            break;
        }
        if (arg[i] == u'"') {
            out.append(backslashes * 2 + 1, u'\\');
            out.push_back(u'"');
        } else {
            out.append(backslashes, u'\\');
            out.push_back(arg[i]);
        }
    }
    out.push_back(u'"');
    return out;
}

struct ChildProcess::Impl {
    PROCESS_INFORMATION info{};
    HANDLE stdin_write = nullptr;
    HANDLE stdout_read = nullptr;
    HANDLE stderr_read = nullptr;
    std::thread out_thread, err_thread, exit_thread;
    std::mutex write_lock;
    std::atomic<bool> terminating{false};
    std::function<void(uint32_t)> on_exit;

    static void pump(HANDLE h, std::function<void(std::string_view)> sink) {
        char buffer[16 * 1024];
        DWORD n = 0;
        while (ReadFile(h, buffer, sizeof buffer, &n, nullptr) && n > 0) {
            if (sink) sink(std::string_view(buffer, n));
        }
    }

    ~Impl() {
        terminating = true;
        if (info.hProcess) {
            DWORD code = 0;
            if (GetExitCodeProcess(info.hProcess, &code) && code == STILL_ACTIVE) {
                TerminateProcess(info.hProcess, 1);
            }
        }
        {
            // A reader thread may be mid-write, answering a server request.
            std::lock_guard lock(write_lock);
            close(stdin_write);
        }
        // The readers finish when the child's ends close, which happens when
        // it exits. Joined before the handles they read go away.
        if (out_thread.joinable()) out_thread.join();
        if (err_thread.joinable()) err_thread.join();
        if (exit_thread.joinable()) {
            if (exit_thread.get_id() == std::this_thread::get_id()) exit_thread.detach();
            else exit_thread.join();
        }
        close(stdout_read);
        close(stderr_read);
        close(info.hThread);
        close(info.hProcess);
    }
};

ChildProcess::ChildProcess(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
ChildProcess::~ChildProcess() = default;

std::unique_ptr<ChildProcess> ChildProcess::start(Options o) {
    auto impl = std::make_unique<Impl>();
    impl->on_exit = std::move(o.on_exit);

    Pipe in{}, out{}, err{};
    if (o.pipe_stdin) in = make_pipe(true);
    out = make_pipe(false);
    err = make_pipe(false);

    std::u16string command = quote_argument(o.executable);
    for (const auto& a : o.arguments) command += u" " + quote_argument(a);
    std::wstring cmd = wide(command);

    STARTUPINFOW si{};
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = o.pipe_stdin ? in.read : GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = out.write;
    si.hStdError = err.write;

    // Suspended, so it is inside the job before it can run anything -- a
    // child that spawned its own child first would leave that one outside.
    const DWORD flags = CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
    const std::wstring exe = wide(o.executable);
    const BOOL ok = CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, TRUE, flags,
                                   nullptr, nullptr, &si, &impl->info);
    const DWORD error = GetLastError();

    close(in.read);
    close(out.write);
    close(err.write);
    if (!ok) {
        close(in.write);
        close(out.read);
        close(err.read);
        throw ProcessError("could not start " + std::string(exe.begin(), exe.end())
                           + " (Windows error " + std::to_string(error) + ")");
    }
    if (HANDLE job = nib_job()) AssignProcessToJobObject(job, impl->info.hProcess);
    ResumeThread(impl->info.hThread);

    impl->stdin_write = in.write;
    impl->stdout_read = out.read;
    impl->stderr_read = err.read;
    impl->out_thread = std::thread(Impl::pump, out.read, std::move(o.on_stdout));
    impl->err_thread = std::thread(Impl::pump, err.read, std::move(o.on_stderr));

    Impl* raw = impl.get();
    impl->exit_thread = std::thread([raw] {
        WaitForSingleObject(raw->info.hProcess, INFINITE);
        if (raw->terminating) return;
        DWORD code = 0;
        GetExitCodeProcess(raw->info.hProcess, &code);
        if (raw->on_exit) raw->on_exit(code);
    });
    return std::unique_ptr<ChildProcess>(new ChildProcess(std::move(impl)));
}

bool ChildProcess::running() const {
    if (!impl_ || !impl_->info.hProcess) return false;
    return WaitForSingleObject(impl_->info.hProcess, 0) == WAIT_TIMEOUT;
}

uint32_t ChildProcess::pid() const { return impl_ ? impl_->info.dwProcessId : 0; }

bool ChildProcess::write(std::string_view bytes) {
    if (!impl_) return false;
    std::lock_guard lock(impl_->write_lock);
    if (!impl_->stdin_write) return false;
    while (!bytes.empty()) {
        DWORD n = 0;
        if (!WriteFile(impl_->stdin_write, bytes.data(), static_cast<DWORD>(bytes.size()), &n,
                       nullptr)) {
            return false;
        }
        bytes.remove_prefix(n);
    }
    return true;
}

void ChildProcess::terminate() {
    if (!impl_) return;
    impl_.reset();  // Impl's destructor kills, closes and joins
}

}  // namespace nib::platform
