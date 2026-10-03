#pragma once
#include <atomic>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

// WASAPI, shared mode: the microphone for dictation and practice, the speakers
// for read-aloud. Nothing here is open unless a feature is in use -- no
// device, no thread -- which is the whole design: dictation costs nothing
// until the key is pressed.

namespace nib::audio {

struct AudioError : std::runtime_error {
    enum class Kind { no_device, access_denied, other };
    Kind kind;
    AudioError(Kind k, const std::string& what) : std::runtime_error(what), kind(k) {}
};

// Records from the default microphone, as 16kHz mono for whisper.
class Recorder {
public:
    // A forgotten toggle stops itself after ten minutes, and what it heard is
    // transcribed rather than discarded.
    static constexpr double max_seconds = 600;

    Recorder();
    ~Recorder();

    // Called on the capture thread when max_seconds is reached.
    std::function<void()> on_reached_limit;

    // Throws AudioError; access_denied when Windows' microphone privacy
    // setting is off for desktop apps.
    void start();
    // Stops and returns everything captured, at 16kHz.
    std::vector<float> stop();
    void cancel();

    bool recording() const { return running_.load(); }
    // 0..1, the recent loudness, for the listening indicator.
    float level() const { return level_.load(); }
    double elapsed() const;

private:
    void run();
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> stopping_{false};
    std::atomic<float> level_{0};
    std::mutex lock_;
    std::vector<float> captured_;  // mono, at device_rate_
    int device_rate_ = 48'000;
    std::atomic<size_t> frames_{0};
    std::string start_error_;
    AudioError::Kind start_kind_ = AudioError::Kind::other;
    bool started_ok_ = false;
    std::mutex start_lock_;
    std::condition_variable_any started_;
    bool start_done_ = false;
};

// Plays 24kHz mono samples on the default output, batch by batch, as they are
// synthesised.
class Player {
public:
    Player();
    ~Player();

    // Throws AudioError. `finished` is called on the render thread when the
    // last batch has played out.
    void begin(std::function<void()> finished);
    void enqueue(const std::vector<float>& samples24k, bool last);
    void stop();
    bool playing() const { return running_.load(); }

private:
    void run();
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::mutex lock_;
    std::vector<float> queue_;  // mono at device rate
    size_t read_ = 0;
    bool last_seen_ = false;
    int device_rate_ = 48'000;
    int channels_ = 2;
    std::function<void()> finished_;
    std::string start_error_;
    bool started_ok_ = false;
    std::mutex start_lock_;
    std::condition_variable_any started_;
    bool start_done_ = false;
};

// Whether Windows lets desktop apps use the microphone at all, read from the
// privacy setting rather than discovered by failing.
bool microphone_allowed();
void open_microphone_settings();

}  // namespace nib::audio
