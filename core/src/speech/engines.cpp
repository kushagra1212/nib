#include "speech/engines.hpp"

#include <windows.h>

#include <algorithm>
#include <cstring>
#include "onnxruntime/onnxruntime_c_api.h"
#include "platform/paths.hpp"
#include "platform/process.hpp"
#include "speech/kokoro_vocab.hpp"
#include "speech/dictation_text.hpp"
#include "speech/audio.hpp"
#include "support/log.hpp"
#include "text/unicode.hpp"
#include "whisper/whisper.h"

namespace nib::speech {
namespace fs = std::filesystem;

namespace {

// Loaded with its own folder on the search path, so its dependencies resolve
// beside it -- whisper's ggml.dll, not anything else's.
HMODULE load(const fs::path& dll) {
    return LoadLibraryExW(dll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
}

std::string last_error() {
    const DWORD code = GetLastError();
    wchar_t* text = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, code, 0, reinterpret_cast<LPWSTR>(&text), 0, nullptr);
    std::wstring w = text ? text : L"";
    if (text) LocalFree(text);
    while (!w.empty() && (w.back() == L'\n' || w.back() == L'\r' || w.back() == L'.')) w.pop_back();
    return utf16_to_utf8(std::u16string(w.begin(), w.end())) + " (" + std::to_string(code) + ")";
}

// The 8.3 form of a path, which is ASCII whatever the user's name is: espeak
// and whisper take char* paths in the ANSI code page.
std::string ansi_path(const fs::path& p) {
    wchar_t buffer[MAX_PATH * 2];
    const DWORD n = GetShortPathNameW(p.c_str(), buffer, MAX_PATH * 2);
    std::wstring w = n && n < MAX_PATH * 2 ? std::wstring(buffer, n) : p.wstring();
    std::string out;
    for (wchar_t c : w) out.push_back(c < 128 ? static_cast<char>(c) : '?');
    return out;
}

}  // namespace

// --- espeak-ng ------------------------------------------------------------------

namespace {
using InitializeFn = int(__cdecl*)(int, int, const char*, int);
using SetVoiceFn = int(__cdecl*)(const char*);
using TextToPhonemesFn = const char*(__cdecl*)(const void**, int, int);
std::mutex espeak_lock;
}  // namespace

std::optional<fs::path> Espeak::installed_directory() {
    if (const char* over = std::getenv("NIB_ESPEAK_DIR"); over && *over) return fs::u8path(over);
    if (auto dll = platform::paths::locate_engine(fs::path(L"espeak") / L"espeak-ng.dll")) return dll->parent_path();
    return std::nullopt;
}

Espeak& Espeak::shared(const std::string& voice) {
    std::lock_guard lock(espeak_lock);
    static std::unique_ptr<Espeak> instance;
    if (!instance) {
        const auto dir = installed_directory();
        if (!dir) throw SpeechError("espeak-ng is not installed. Run Scripts/windows/fetch-engines.ps1");
        instance.reset(new Espeak(*dir, voice));
    }
    return *instance;
}

Espeak::Espeak(const fs::path& directory, const std::string& voice) {
    HMODULE lib = load(directory / L"espeak-ng.dll");
    if (!lib) throw SpeechError("cannot load espeak-ng.dll: " + last_error());
    auto init = reinterpret_cast<InitializeFn>(GetProcAddress(lib, "espeak_Initialize"));
    auto set_voice = reinterpret_cast<SetVoiceFn>(GetProcAddress(lib, "espeak_SetVoiceByName"));
    text_to_phonemes_ = reinterpret_cast<void*>(GetProcAddress(lib, "espeak_TextToPhonemes"));
    if (!init || !set_voice || !text_to_phonemes_) throw SpeechError("espeak-ng.dll is missing functions; it may be too old");

    // Synchronous output, no buffer; returns the sample rate, or <= 0 when the
    // dictionaries were not found -- which otherwise shows up much later as
    // English phonemised as nothing.
    const auto data = ansi_path(directory / L"espeak-ng-data");
    sample_rate_ = init(0x02, 0, data.c_str(), 0);
    if (sample_rate_ <= 0) {
        throw SpeechError("espeak-ng would not start (" + std::to_string(sample_rate_) + ") with data at " + data);
    }
    if (set_voice(voice.c_str()) != 0) throw SpeechError("espeak-ng has no voice called " + voice);
    handle_ = lib;
    // Never unloaded: espeak's globals outlive any handle to it.
}

std::u32string Espeak::phonemes(const std::u32string& chunk) {
    std::lock_guard lock(espeak_lock);
    const std::string text = to_utf8(chunk);
    const void* cursor = text.c_str();
    std::string joined;
    bool first = true;
    // IPA, with '_' between the phonemes of a word -- exactly as phonemizer
    // asks. espeak advances the pointer a clause at a time and nulls it at the
    // end.
    const int mode = ('_' << 8) | 0x02;
    auto fn = reinterpret_cast<TextToPhonemesFn>(text_to_phonemes_);
    while (cursor) {
        const char* piece = fn(&cursor, 1 /* UTF-8 */, mode);
        if (piece) {
            if (!first) joined.push_back(' ');
            joined += piece;
            first = false;
        }
    }
    return to_u32(joined);
}

// --- Kokoro ---------------------------------------------------------------------

struct Kokoro::Impl {
    const OrtApi* api = nullptr;
    OrtEnv* env = nullptr;
    OrtSession* session = nullptr;
    OrtMemoryInfo* memory = nullptr;
    std::string output;

    void check(OrtStatus* status, const char* what) {
        if (!status) return;
        const std::string message = std::string(what) + ": " + api->GetErrorMessage(status);
        api->ReleaseStatus(status);
        throw SpeechError(message);
    }
    ~Impl() {
        if (!api) return;
        if (memory) api->ReleaseMemoryInfo(memory);
        if (session) api->ReleaseSession(session);
        if (env) api->ReleaseEnv(env);
        // The library stays loaded: unloading it while ORT's threads wind down
        // unmaps code they are still running.
    }
};

int Kokoro::default_threads() {
    if (const char* over = std::getenv("NIB_KOKORO_THREADS"); over && std::atoi(over) > 0) return std::atoi(over);
    return std::clamp(static_cast<int>(platform::processor_count() / 4), 2, 4);
}

std::optional<fs::path> Kokoro::runtime() {
    if (const char* over = std::getenv("NIB_ONNX_RUNTIME"); over && *over) return fs::u8path(over);
    return platform::paths::locate_engine(fs::path(L"onnx") / L"onnxruntime.dll");
}

Kokoro::Kokoro(const fs::path& model, const fs::path& runtime, int intra_threads) : impl_(std::make_unique<Impl>()) {
    std::error_code ec;
    if (!fs::is_regular_file(model, ec)) {
        throw SpeechError("no model at " + model.string() + "; download it from the Voices section");
    }
    HMODULE lib = load(runtime);
    if (!lib) throw SpeechError("cannot load " + runtime.string() + ": " + last_error());
    auto get_base = reinterpret_cast<const OrtApiBase*(ORT_API_CALL*)()>(GetProcAddress(lib, "OrtGetApiBase"));
    if (!get_base) throw SpeechError("OrtGetApiBase is not in " + runtime.string());
    const OrtApiBase* base = get_base();
    impl_->api = base->GetApi(ORT_API_VERSION);
    if (!impl_->api) {
        throw SpeechError(std::string("onnxruntime ") + base->GetVersionString() + " is too old for this build");
    }
    version_ = base->GetVersionString();
    auto& api = *impl_->api;

    impl_->check(api.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "nib", &impl_->env), "creating the onnx environment");
    OrtSessionOptions* options = nullptr;
    impl_->check(api.CreateSessionOptions(&options), "creating session options");
    struct Release {
        const OrtApi& api;
        OrtSessionOptions* o;
        ~Release() { api.ReleaseSessionOptions(o); }
    } release{api, options};
    impl_->check(api.SetIntraOpNumThreads(options, intra_threads), "limiting threads");
    impl_->check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), "setting the optimisation level");
    impl_->check(api.CreateSession(impl_->env, model.c_str(), options, &impl_->session), "opening the model");
    impl_->check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &impl_->memory), "describing memory");

    OrtAllocator* allocator = nullptr;
    impl_->check(api.GetAllocatorWithDefaultOptions(&allocator), "getting an allocator");
    size_t inputs = 0;
    impl_->check(api.SessionGetInputCount(impl_->session, &inputs), "counting model inputs");
    for (size_t i = 0; i < inputs; ++i) {
        char* name = nullptr;
        impl_->check(api.SessionGetInputName(impl_->session, i, allocator, &name), "reading an input name");
        // Older exports say "tokens", newer "input_ids": read, not guessed.
        if (std::strcmp(name, "input_ids") == 0 || std::strcmp(name, "tokens") == 0) token_input_ = name;
        allocator->Free(allocator, name);
    }
    if (token_input_.empty()) {
        throw SpeechError("the model has no input called input_ids or tokens; it may not be a Kokoro export");
    }
    char* out = nullptr;
    impl_->check(api.SessionGetOutputName(impl_->session, 0, allocator, &out), "reading the output name");
    impl_->output = out;
    allocator->Free(allocator, out);
}

Kokoro::~Kokoro() = default;

std::vector<float> Kokoro::synthesise(const std::vector<int32_t>& tokens, const std::vector<float>& style, float speed) {
    if (tokens.empty()) throw SpeechError("nothing to speak");
    std::lock_guard lock(lock_);
    auto& api = *impl_->api;

    // A zero at each end: trained with them, and without them every utterance
    // loses its first and last phoneme.
    std::vector<int64_t> padded(tokens.size() + 2, 0);
    std::copy(tokens.begin(), tokens.end(), padded.begin() + 1);
    std::vector<float> style_copy = style;

    OrtValue* token_value = nullptr;
    OrtValue* style_value = nullptr;
    OrtValue* speed_value = nullptr;
    OrtValue* output = nullptr;
    struct Values {
        const OrtApi& api;
        OrtValue** list[4];
        ~Values() {
            for (auto** v : list) {
                if (*v) api.ReleaseValue(*v);
            }
        }
    } guard{api, {&token_value, &style_value, &speed_value, &output}};

    const int64_t token_shape[2] = {1, static_cast<int64_t>(padded.size())};
    impl_->check(api.CreateTensorWithDataAsOrtValue(impl_->memory, padded.data(), padded.size() * sizeof(int64_t),
                                                    token_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &token_value),
                 "building the token tensor");
    const int64_t style_shape[2] = {1, static_cast<int64_t>(style_copy.size())};
    impl_->check(api.CreateTensorWithDataAsOrtValue(impl_->memory, style_copy.data(), style_copy.size() * sizeof(float),
                                                    style_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &style_value),
                 "building the style tensor");
    const int64_t speed_shape[1] = {1};
    impl_->check(api.CreateTensorWithDataAsOrtValue(impl_->memory, &speed, sizeof(float), speed_shape, 1,
                                                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &speed_value),
                 "building the speed tensor");

    const char* input_names[3] = {token_input_.c_str(), "style", "speed"};
    const OrtValue* input_values[3] = {token_value, style_value, speed_value};
    const char* output_names[1] = {impl_->output.c_str()};
    impl_->check(api.Run(impl_->session, nullptr, input_names, input_values, 3, output_names, 1, &output),
                 "running the model");

    float* data = nullptr;
    impl_->check(api.GetTensorMutableData(output, reinterpret_cast<void**>(&data)), "reading the samples");
    OrtTensorTypeAndShapeInfo* info = nullptr;
    impl_->check(api.GetTensorTypeAndShape(output, &info), "reading the output shape");
    size_t total = 0;
    OrtStatus* counted = api.GetTensorShapeElementCount(info, &total);
    api.ReleaseTensorTypeAndShapeInfo(info);
    impl_->check(counted, "counting the samples");
    return std::vector<float>(data, data + total);
}

// --- Synthesizer ------------------------------------------------------------------

void Synthesizer::synthesise(const std::u16string& text, const std::function<bool()>& cancelled,
                             const std::function<void(std::vector<float>, bool)>& on_batch) {
    const auto spoken = phonemizer::phonemes(to_u32(text), phonemes);
    const auto batches = chunker::streaming(spoken);
    if (batches.empty()) {
        throw SpeechError(trimmed(text).empty() ? "nothing selected to speak" : "nothing speakable in that text");
    }
    bool spoke = false;
    for (size_t i = 0; i < batches.size(); ++i) {
        if (cancelled && cancelled()) return;
        const auto tokens = kokoro::tokenize(batches[i]);
        if (tokens.empty()) continue;
        const auto style = voices.style(voice, static_cast<int32_t>(tokens.size()));
        auto audio = trim::trimmed(engine.synthesise(tokens, style, speed));
        const bool last = i + 1 == batches.size();
        // Trimming removes the model's gap after a full stop, so the pause the
        // punctuation asked for is added back between batches.
        if (!last) {
            const double pause = chunker::pause_after(batches[i], sentence_pause, clause_pause);
            if (pause > 0) audio.insert(audio.end(), static_cast<size_t>(pause * Kokoro::sample_rate), 0.f);
        }
        spoke = true;
        on_batch(leveled(audio, volume), last);
    }
    if (!spoke) throw SpeechError("nothing speakable in that text");
}

// --- whisper --------------------------------------------------------------------

struct Whisper::Impl {
    HMODULE lib = nullptr;
    whisper_context* context = nullptr;
    decltype(&whisper_init_from_file_with_params) init = nullptr;
    decltype(&whisper_context_default_params) context_defaults = nullptr;
    decltype(&whisper_full_default_params) full_defaults = nullptr;
    decltype(&whisper_full) full = nullptr;
    decltype(&whisper_full_n_segments) n_segments = nullptr;
    decltype(&whisper_full_get_segment_text) segment_text = nullptr;
    decltype(&whisper_full_get_segment_t0) t0 = nullptr;
    decltype(&whisper_full_get_segment_t1) t1 = nullptr;
    decltype(&whisper_full_get_segment_no_speech_prob) no_speech = nullptr;
    decltype(&whisper_free) free = nullptr;
    decltype(&whisper_print_system_info) system_info = nullptr;
};

std::optional<fs::path> Whisper::library() {
    return platform::paths::locate_engine(fs::path(L"whisper") / L"whisper.dll");
}

Whisper::Whisper(fs::path model) : model_(std::move(model)) {}

Whisper::~Whisper() { release(); }

namespace {

template <typename T>
void bind(HMODULE lib, T& slot, const char* name) {
    slot = reinterpret_cast<T>(GetProcAddress(lib, name));
    if (!slot) throw SpeechError(std::string(name) + " is not in whisper.dll; it is a different build");
}

// Loaded once per process: the library, not the model.
std::unique_ptr<Whisper::Impl> load_whisper() {
    const auto path = Whisper::library();
    if (!path) throw SpeechError("whisper.dll is not installed. Run Scripts/windows/fetch-engines.ps1");
    auto impl = std::make_unique<Whisper::Impl>();
    impl->lib = load(*path);
    if (!impl->lib) throw SpeechError("cannot load whisper.dll: " + last_error());

    // ggml finds its CPU backends beside the executable by default, and the
    // executable is nib.exe, not whisper.dll. Pointed at whisper's own folder
    // it loads the variant matching this processor.
    if (HMODULE ggml = GetModuleHandleW(L"ggml.dll")) {
        using LoadAll = void (*)(const char*);
        if (auto load_all = reinterpret_cast<LoadAll>(GetProcAddress(ggml, "ggml_backend_load_all_from_path"))) {
            load_all(ansi_path(path->parent_path()).c_str());
        }
    }
    bind(impl->lib, impl->init, "whisper_init_from_file_with_params");
    bind(impl->lib, impl->context_defaults, "whisper_context_default_params");
    bind(impl->lib, impl->full_defaults, "whisper_full_default_params");
    bind(impl->lib, impl->full, "whisper_full");
    bind(impl->lib, impl->n_segments, "whisper_full_n_segments");
    bind(impl->lib, impl->segment_text, "whisper_full_get_segment_text");
    bind(impl->lib, impl->t0, "whisper_full_get_segment_t0");
    bind(impl->lib, impl->t1, "whisper_full_get_segment_t1");
    bind(impl->lib, impl->no_speech, "whisper_full_get_segment_no_speech_prob");
    bind(impl->lib, impl->free, "whisper_free");
    bind(impl->lib, impl->system_info, "whisper_print_system_info");
    return impl;
}

Whisper::Impl& shared_whisper() {
    static std::mutex lock;
    static std::unique_ptr<Whisper::Impl> impl;
    std::lock_guard guard(lock);
    if (!impl) impl = load_whisper();
    return *impl;
}

}  // namespace

std::string Whisper::system_info() {
    auto& lib = shared_whisper();
    return lib.system_info();
}

void Whisper::release() {
    std::lock_guard lock(lock_);
    if (impl_ && impl_->context) {
        impl_->free(impl_->context);
        impl_->context = nullptr;
        log::write("whisper: model released");
    }
}

std::vector<SpokenSegment> Whisper::transcribe_segments(const std::vector<float>& samples,
                                                        const std::optional<std::u16string>& prompt) {
    if (samples.empty()) throw SpeechError("nothing was recorded");
    // Asked before the model loads: an accidental toggle costs nothing rather
    // than a model load and an invented sentence.
    if (audio::silent(samples)) return {};

    std::lock_guard lock(lock_);
    auto& lib = shared_whisper();
    if (!impl_) impl_ = std::make_unique<Impl>(lib);
    if (!impl_->context) {
        std::error_code ec;
        if (!fs::is_regular_file(model_, ec)) throw SpeechError("no speech model at " + model_.string());
        auto params = lib.context_defaults();
        params.use_gpu = false;  // the CPU build; there is no GPU backend to use
        impl_->context = lib.init(ansi_path(model_).c_str(), params);
        if (!impl_->context) {
            throw SpeechError(model_.filename().string()
                              + " could not be loaded -- it may be the wrong format, or too large for this "
                                "machine's memory");
        }
    }

    const char* greedy = std::getenv("NIB_WHISPER_GREEDY");
    auto params = lib.full_defaults(greedy ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH);
    if (!greedy) {
        const char* beam = std::getenv("NIB_WHISPER_BEAM");
        params.beam_search.beam_size = beam ? std::max(1, std::atoi(beam)) : 5;
    }
    // Told the language rather than left to guess: a short accented clip
    // decoded as Hindi comes back as confident nonsense.
    const char* lang_env = std::getenv("NIB_WHISPER_LANG");
    const std::string language = lang_env ? lang_env : "en";
    params.language = language.c_str();
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_context = true;
    params.single_segment = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.n_threads = static_cast<int>(std::max<uint32_t>(2, platform::processor_count() / 2));
    std::string prompt_utf8;
    if (prompt && !prompt->empty()) {
        prompt_utf8 = utf16_to_utf8(*prompt);
        params.initial_prompt = prompt_utf8.c_str();
    }

    const int status = lib.full(impl_->context, params, samples.data(), static_cast<int>(samples.size()));
    if (status != 0) throw SpeechError("whisper failed with code " + std::to_string(status));

    std::vector<SpokenSegment> out;
    const int n = lib.n_segments(impl_->context);
    for (int i = 0; i < n; ++i) {
        // whisper invents "you" and "Thank you." for silence; its own estimate
        // that a segment holds no speech is what separates those from real ones.
        if (lib.no_speech(impl_->context, i) >= no_speech_limit) continue;
        const char* text = lib.segment_text(impl_->context, i);
        // Centiseconds.
        out.push_back({utf8_to_utf16(text ? text : ""), lib.t0(impl_->context, i) / 100.0,
                       lib.t1(impl_->context, i) / 100.0});
    }
    return out;
}

std::u16string Whisper::transcribe(const std::vector<float>& samples, const std::optional<std::u16string>& prompt) {
    std::u16string joined;
    for (const auto& s : transcribe_segments(samples, prompt)) joined += s.text;
    return clean_transcript(joined);
}

}  // namespace nib::speech
