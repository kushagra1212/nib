#pragma once
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>
#include "speech/practice.hpp"
#include "speech/speech_text.hpp"
#include "speech/voice_pack.hpp"

// The three engines behind speech, each loaded from its DLL at runtime rather
// than linked: a library is a file that is either there or not, and its
// absence is a message instead of nib failing to start.

namespace nib::speech {

// Port of EspeakLibrary: espeak-ng asked for phonemes.
//
// espeak keeps its state in process globals, so every call holds one lock --
// what phonemizer does, for the same reason -- and the library is initialised
// once and never unloaded.
class Espeak {
public:
    // The one instance, loaded on first use. Throws SpeechError.
    static Espeak& shared(const std::string& voice = "en-us");
    static std::optional<std::filesystem::path> installed_directory();

    std::u32string phonemes(const std::u32string& chunk);
    int32_t sample_rate() const { return sample_rate_; }

private:
    Espeak(const std::filesystem::path& directory, const std::string& voice);
    void* handle_ = nullptr;
    void* text_to_phonemes_ = nullptr;
    int32_t sample_rate_ = 0;
};

// Port of KokoroEngine and the C shim: one ONNX Runtime session, one call.
class Kokoro {
public:
    static constexpr int sample_rate = 24'000;
    // Two, measured: the second thread nearly doubles speed, the third adds
    // little, and nib leaves the rest of the machine alone. It also decides
    // the exact samples, which the audio fixture records.
    static constexpr int threads = 2;

    static std::optional<std::filesystem::path> runtime();

    // Throws SpeechError.
    Kokoro(const std::filesystem::path& model, const std::filesystem::path& runtime, int threads = threads);
    ~Kokoro();

    // Samples at 24kHz for one batch of tokens. The padding zeros the model
    // expects are added here.
    std::vector<float> synthesise(const std::vector<int32_t>& tokens, const std::vector<float>& style,
                                  float speed = 1.0f);
    const std::string& runtime_version() const { return version_; }
    const std::string& token_input() const { return token_input_; }

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::string version_;
    std::string token_input_;
    std::mutex lock_;
};

// Port of SpeechSynthesizer: text in, levelled samples out, batch by batch.
struct Synthesizer {
    Kokoro& engine;
    const VoicePack& voices;
    PhonemeSource phonemes;

    std::string voice = "af_heart";
    float speed = 1.0f;
    float volume = 0.45f;
    double sentence_pause = 0.25;
    double clause_pause = 0.1;

    // Hands over each batch the moment it is ready, so a long selection starts
    // speaking after the first batch rather than after all of them. Throws
    // SpeechError when there is nothing speakable.
    void synthesise(const std::u16string& text, const std::function<bool()>& cancelled,
                    const std::function<void(std::vector<float>, bool last)>& on_batch);
};

// Port of WhisperEngine: speech to text from whisper.dll. The model is loaded
// only while transcribing and freed after; an idle nib holds no weights.
class Whisper {
public:
    static std::optional<std::filesystem::path> library();
    static constexpr float no_speech_limit = 0.6f;

    explicit Whisper(std::filesystem::path model);
    ~Whisper();

    // Segments with timings; empty for silence, which is refused before the
    // model loads. Throws SpeechError.
    std::vector<SpokenSegment> transcribe_segments(const std::vector<float>& samples16k,
                                                   const std::optional<std::u16string>& prompt);
    std::u16string transcribe(const std::vector<float>& samples16k, const std::optional<std::u16string>& prompt);
    void release();
    static std::string system_info();

    struct Impl;  // the library's entry points and this model's context

private:
    std::unique_ptr<Impl> impl_;
    std::filesystem::path model_;
    std::mutex lock_;
};

}  // namespace nib::speech
