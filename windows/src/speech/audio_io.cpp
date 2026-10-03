#include "speech/audio_io.hpp"

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <shellapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include "speech/audio.hpp"
#include "support/log.hpp"

namespace nib::audio {
namespace {

using Microsoft::WRL::ComPtr;

struct Com {
    bool ok;
    Com() : ok(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {}
    ~Com() {
        if (ok) CoUninitialize();
    }
};

struct Format {
    int rate = 48'000;
    int channels = 2;
    bool is_float = true;
    int bits = 32;
};

Format describe(const WAVEFORMATEX* f) {
    Format out;
    out.rate = static_cast<int>(f->nSamplesPerSec);
    out.channels = f->nChannels;
    out.bits = f->wBitsPerSample;
    out.is_float = f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(f);
        out.is_float = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != FALSE;
    }
    return out;
}

ComPtr<IAudioClient> client_for(EDataFlow flow, AudioError::Kind& kind, std::string& error) {
    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
        error = "audio devices are unavailable";
        return nullptr;
    }
    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(flow, eConsole, &device)) || !device) {
        kind = AudioError::Kind::no_device;
        error = flow == eCapture ? "no microphone is connected" : "no speakers or headphones are connected";
        return nullptr;
    }
    ComPtr<IAudioClient> client;
    const HRESULT hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
    if (hr == E_ACCESSDENIED) {
        kind = AudioError::Kind::access_denied;
        error = "Windows is not letting apps use the microphone";
        return nullptr;
    }
    if (FAILED(hr)) {
        error = "could not open the audio device";
        return nullptr;
    }
    return client;
}

}  // namespace

bool microphone_allowed() {
    // The consent store records "Allow" or "Deny" for the global switch and
    // for desktop apps; either at "Deny" means no capture will work.
    auto read = [](const wchar_t* key) -> std::wstring {
        wchar_t value[32]{};
        DWORD size = sizeof value;
        if (RegGetValueW(HKEY_CURRENT_USER, key, L"Value", RRF_RT_REG_SZ, nullptr, value, &size) != ERROR_SUCCESS) {
            return L"";
        }
        return value;
    };
    const auto global = read(L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone");
    const auto desktop = read(
        L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone\\NonPackaged");
    return global != L"Deny" && desktop != L"Deny";
}

void open_microphone_settings() {
    ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-microphone", nullptr, nullptr, SW_SHOWNORMAL);
}

// --- Recorder ----------------------------------------------------------------------

Recorder::Recorder() = default;

Recorder::~Recorder() { cancel(); }

double Recorder::elapsed() const { return static_cast<double>(frames_.load()) / device_rate_; }

void Recorder::start() {
    if (running_) return;
    {
        std::lock_guard lock(lock_);
        captured_.clear();
    }
    frames_ = 0;
    level_ = 0;
    stopping_ = false;
    start_done_ = false;
    started_ok_ = false;
    thread_ = std::thread([this] { run(); });

    std::unique_lock lock(start_lock_);
    started_.wait(lock, [&] { return start_done_; });
    if (!started_ok_) {
        if (thread_.joinable()) thread_.join();
        throw AudioError(start_kind_, start_error_);
    }
}

void Recorder::run() {
    Com com;
    auto report = [&](bool ok) {
        std::lock_guard lock(start_lock_);
        started_ok_ = ok;
        start_done_ = true;
        started_.notify_all();
    };

    start_kind_ = AudioError::Kind::other;
    auto client = client_for(eCapture, start_kind_, start_error_);
    if (!client) return report(false);

    WAVEFORMATEX* mix = nullptr;
    if (FAILED(client->GetMixFormat(&mix))) {
        start_error_ = "the microphone reports no format";
        return report(false);
    }
    const Format fmt = describe(mix);
    device_rate_ = fmt.rate;
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HRESULT hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 2'000'000, 0, mix,
                                    nullptr);
    CoTaskMemFree(mix);
    if (hr == E_ACCESSDENIED) {
        start_kind_ = AudioError::Kind::access_denied;
        start_error_ = "Windows is not letting apps use the microphone";
        CloseHandle(event);
        return report(false);
    }
    ComPtr<IAudioCaptureClient> capture;
    if (FAILED(hr) || FAILED(client->SetEventHandle(event)) || FAILED(client->GetService(IID_PPV_ARGS(&capture)))
        || FAILED(client->Start())) {
        start_error_ = "could not start recording";
        CloseHandle(event);
        return report(false);
    }
    running_ = true;
    report(true);

    bool limit_fired = false;
    while (!stopping_) {
        WaitForSingleObject(event, 100);
        UINT32 packet = 0;
        while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
            std::vector<float> mono(frames, 0.f);
            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
                for (UINT32 i = 0; i < frames; ++i) {
                    float sum = 0;
                    for (int c = 0; c < fmt.channels; ++c) {
                        const size_t at = (static_cast<size_t>(i) * fmt.channels + c);
                        if (fmt.is_float && fmt.bits == 32) {
                            float v;
                            std::memcpy(&v, data + at * 4, 4);
                            sum += v;
                        } else if (fmt.bits == 16) {
                            int16_t v;
                            std::memcpy(&v, data + at * 2, 2);
                            sum += v / 32768.f;
                        } else if (fmt.bits == 32) {
                            int32_t v;
                            std::memcpy(&v, data + at * 4, 4);
                            sum += static_cast<float>(v / 2147483648.0);
                        }
                    }
                    mono[i] = sum / fmt.channels;
                }
            }
            capture->ReleaseBuffer(frames);

            float peak = 0;
            for (float s : mono) peak = std::max(peak, std::abs(s));
            // Perceptual: the square root lifts quiet speech into view.
            level_ = std::min(1.f, std::sqrt(peak) * 1.2f);
            {
                std::lock_guard lock(lock_);
                captured_.insert(captured_.end(), mono.begin(), mono.end());
            }
            frames_ += frames;
        }
        if (!limit_fired && elapsed() >= max_seconds) {
            limit_fired = true;
            if (on_reached_limit) on_reached_limit();
        }
    }
    client->Stop();
    CloseHandle(event);
    running_ = false;
}

std::vector<float> Recorder::stop() {
    stopping_ = true;
    if (thread_.joinable()) thread_.join();
    std::vector<float> raw;
    {
        std::lock_guard lock(lock_);
        raw.swap(captured_);
    }
    return nib::speech::audio::resample(raw, device_rate_, nib::speech::audio::whisper_rate);
}

void Recorder::cancel() {
    stopping_ = true;
    if (thread_.joinable()) thread_.join();
    std::lock_guard lock(lock_);
    captured_.clear();
}

// --- Player ------------------------------------------------------------------------

Player::Player() = default;

Player::~Player() { stop(); }

void Player::begin(std::function<void()> finished) {
    stop();
    {
        std::lock_guard lock(lock_);
        queue_.clear();
        read_ = 0;
        last_seen_ = false;
        finished_ = std::move(finished);
    }
    start_done_ = false;
    started_ok_ = false;
    running_ = true;
    thread_ = std::thread([this] { run(); });
    std::unique_lock lock(start_lock_);
    started_.wait(lock, [&] { return start_done_; });
    if (!started_ok_) {
        running_ = false;
        if (thread_.joinable()) thread_.join();
        throw AudioError(AudioError::Kind::other, start_error_);
    }
}

void Player::enqueue(const std::vector<float>& samples, bool last) {
    const auto converted = nib::speech::audio::resample(samples, nib::speech::audio::kokoro_rate, device_rate_);
    std::lock_guard lock(lock_);
    queue_.insert(queue_.end(), converted.begin(), converted.end());
    if (last) last_seen_ = true;
}

void Player::run() {
    Com com;
    auto report = [&](bool ok) {
        std::lock_guard lock(start_lock_);
        started_ok_ = ok;
        start_done_ = true;
        started_.notify_all();
    };
    AudioError::Kind kind = AudioError::Kind::other;
    auto client = client_for(eRender, kind, start_error_);
    if (!client) return report(false);
    WAVEFORMATEX* mix = nullptr;
    if (FAILED(client->GetMixFormat(&mix))) {
        start_error_ = "the output device reports no format";
        return report(false);
    }
    const Format fmt = describe(mix);
    device_rate_ = fmt.rate;
    channels_ = fmt.channels;
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HRESULT hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 2'000'000, 0, mix,
                                    nullptr);
    CoTaskMemFree(mix);
    ComPtr<IAudioRenderClient> render;
    UINT32 buffer_frames = 0;
    if (FAILED(hr) || FAILED(client->SetEventHandle(event)) || FAILED(client->GetBufferSize(&buffer_frames))
        || FAILED(client->GetService(IID_PPV_ARGS(&render))) || FAILED(client->Start())) {
        start_error_ = "could not open the speakers";
        CloseHandle(event);
        return report(false);
    }
    report(true);

    bool done = false;
    while (running_ && !done) {
        WaitForSingleObject(event, 100);
        UINT32 padding = 0;
        if (FAILED(client->GetCurrentPadding(&padding))) break;
        const UINT32 room = buffer_frames - padding;
        bool drained = false, last = false;
        {
            std::lock_guard lock(lock_);
            drained = read_ >= queue_.size();
            last = last_seen_;
        }
        if (drained && last) {
            // Everything handed over; wait for the device to play it out.
            if (padding == 0) done = true;
            continue;
        }
        if (room == 0) continue;
        BYTE* data = nullptr;
        if (FAILED(render->GetBuffer(room, &data))) break;
        UINT32 written = 0;
        {
            std::lock_guard lock(lock_);
            for (; written < room && read_ < queue_.size(); ++written, ++read_) {
                const float s = queue_[read_];
                for (int c = 0; c < channels_; ++c) {
                    const size_t at = static_cast<size_t>(written) * channels_ + c;
                    if (fmt.is_float && fmt.bits == 32) {
                        std::memcpy(data + at * 4, &s, 4);
                    } else if (fmt.bits == 16) {
                        const auto v = static_cast<int16_t>(std::clamp(s, -1.f, 1.f) * 32767.f);
                        std::memcpy(data + at * 2, &v, 2);
                    } else {
                        const auto v = static_cast<int32_t>(std::clamp(s, -1.f, 1.f) * 2147483647.0);
                        std::memcpy(data + at * 4, &v, 4);
                    }
                }
            }
            // Played samples are dropped from the front now and then, so a
            // long passage does not hold its whole history.
            if (read_ > 48'000 * 10) {
                queue_.erase(queue_.begin(), queue_.begin() + static_cast<std::ptrdiff_t>(read_));
                read_ = 0;
            }
        }
        // Starved while synthesis catches up: silence rather than a glitch.
        render->ReleaseBuffer(written ? written : room, written ? 0 : AUDCLNT_BUFFERFLAGS_SILENT);
    }
    client->Stop();
    CloseHandle(event);
    const bool natural = running_ && done;
    running_ = false;
    if (natural) {
        std::function<void()> finished;
        {
            std::lock_guard lock(lock_);
            finished = finished_;
        }
        if (finished) finished();
    }
}

void Player::stop() {
    running_ = false;
    if (thread_.joinable()) {
        if (thread_.get_id() == std::this_thread::get_id()) thread_.detach();
        else thread_.join();
    }
}

}  // namespace nib::audio
