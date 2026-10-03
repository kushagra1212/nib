#include "app/cli.hpp"

#include <windows.h>

#include <chrono>
#include <cstdio>
#include <iostream>
#include <string>
#include <thread>
#include <vector>
#include "app/diagnostics.hpp"
#include "app/dispatch.hpp"
#include "lint/harper_engine.hpp"
#include "rewrite/model_catalog.hpp"
#include "speech/audio.hpp"
#include "speech/audio_io.hpp"
#include "speech/dictation_text.hpp"
#include "speech/practice.hpp"
#include "text/word_tokenize.hpp"
#include "speech/engines.hpp"
#include "speech/kokoro_vocab.hpp"
#include "speech/speech_catalog.hpp"
#include "text/uia.hpp"
#include "text/unicode.hpp"

namespace nib::app {
namespace {

using clock_type = std::chrono::steady_clock;

// nib.exe is a GUI program. Its output reaches a terminal by attaching to the
// one it was started from -- or, when redirected to a file or pipe, through
// the handles it was given.
void attach_console() {
    const HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (out && out != INVALID_HANDLE_VALUE && GetFileType(out) != FILE_TYPE_UNKNOWN) return;
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
        FILE* f = nullptr;
        freopen_s(&f, "CONOUT$", "w", stdout);
        freopen_s(&f, "CONOUT$", "w", stderr);
        freopen_s(&f, "CONIN$", "r", stdin);
        std::printf("\n");
    }
}

void say(const std::string& line) {
    std::fwrite(line.data(), 1, line.size(), stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
}
void say(const std::u16string& line) { say(utf16_to_utf8(line)); }

// Reports built for the control panel use CRLF; the console adds its own CR.
std::string lf(std::wstring_view s) {
    std::string out = narrow(s);
    std::string clean;
    for (char c : out) {
        if (c != '') clean.push_back(c);
    }
    return clean;
}

std::string ms(clock_type::duration d) {
    return std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(d).count()) + "ms";
}

std::u16string arg(int argc, wchar_t** argv, int i) {
    return i < argc ? u16(argv[i]) : std::u16string();
}

std::u16string read_stdin() {
    std::string all, line;
    while (std::getline(std::cin, line)) all += line + "\n";
    return utf8_to_utf16(all);
}

int lint(const std::u16string& text) {
    const auto harper = locate_harper();
    if (!harper) {
        say("harper-ls not found. Run Scripts/windows/fetch-engines.ps1");
        return 1;
    }
    HarperEngine engine(harper->u16string());
    try {
        const auto start = clock_type::now();
        const auto found = engine.lint(text);
        const auto elapsed = clock_type::now() - start;
        if (found.empty()) {
            say("clean (" + ms(elapsed) + ")");
            return 0;
        }
        say(std::to_string(found.size()) + " suggestion(s) in " + ms(elapsed) + ":");
        // Replacements are fetched only for what gets shown.
        std::vector<Suggestion> first(found.begin(), found.begin() + std::min<size_t>(20, found.size()));
        for (const auto& s : engine.with_replacements(first, text)) {
            std::string word = utf16_to_utf8(s.excerpt(text).value_or(u"?"));
            word.resize(std::max<size_t>(word.size(), 14), ' ');
            say("  " + word + " " + utf16_to_utf8(s.message));
            std::string fixes;
            for (size_t i = 0; i < s.replacements.size() && i < 3; ++i) {
                fixes += (i ? " | " : "") + utf16_to_utf8(s.replacements[i]);
            }
            say("      -> " + (fixes.empty() ? std::string("(no automatic fix)") : fixes));
        }
        return 0;
    } catch (const std::exception& e) {
        say(std::string("lint failed: ") + e.what());
        return 1;
    }
}

int bench(int words, int iterations) {
    const auto harper = locate_harper();
    if (!harper) {
        say("harper-ls not found");
        return 1;
    }
    const std::u16string sample = u"The quick brown fox jumps over the lazy dog. Their is a erors here. ";
    std::u16string text;
    while (static_cast<int>(split_whitespace(text).size()) < words) text += sample;
    HarperEngine engine(harper->u16string());
    try {
        auto start = clock_type::now();
        const auto first = engine.lint(text);
        say("words: " + std::to_string(split_whitespace(text).size()) + ", suggestions: " + std::to_string(first.size()));
        say("cold (spawn + handshake + lint): " + ms(clock_type::now() - start));
        std::vector<long long> t;
        for (int i = 0; i < iterations; ++i) {
            start = clock_type::now();
            engine.lint(text);
            t.push_back(std::chrono::duration_cast<std::chrono::milliseconds>(clock_type::now() - start).count());
        }
        std::sort(t.begin(), t.end());
        long long total = 0;
        for (auto v : t) total += v;
        say("warm x" + std::to_string(iterations) + ": min " + std::to_string(t.front()) + "ms, median "
            + std::to_string(t[t.size() / 2]) + "ms, max " + std::to_string(t.back()) + "ms, mean "
            + std::to_string(total / iterations) + "ms");
        return 0;
    } catch (const std::exception& e) {
        say(std::string("bench failed: ") + e.what());
        return 1;
    }
}

int rewrite(const std::u16string& text, const std::string& model) {
    const auto config = rewrite_config(model);
    if (!config) {
        say("no model: put a .gguf in " + model_catalog::install_directory().string() + ", or install one from nib");
        return 1;
    }
    say("model: " + config->model_path.filename().string());
    // Which llama-server, in full: "it worked" is no report when the answer
    // came from a copy nobody meant to test.
    say("server: " + config->server_binary.string());
    RewriteEngine engine(*config);
    for (auto mode : all_rewrite_modes) {
        try {
            const auto start = clock_type::now();
            const auto out = engine.rewrite(text, mode);
            say("\n[" + utf16_to_utf8(rewrite_mode::raw_value(mode)) + "] " + ms(clock_type::now() - start));
            say("  " + utf16_to_utf8(out));
        } catch (const RewriteException& e) {
            say("\n[" + utf16_to_utf8(rewrite_mode::raw_value(mode)) + "] failed: " + utf16_to_utf8(e.error.description()));
            return 1;
        }
    }
    return 0;
}

int model_bench(const std::string& model, int iterations) {
    const auto config = rewrite_config(model);
    if (!config) {
        say("no .gguf model found");
        return 1;
    }
    const std::u16string sample =
        u"Their is many erors in this sentance, and it are very long and wordy in a way that could of been much more shorter.";
    say("model:  " + config->model_path.filename().string());
    say("threads: " + std::to_string(config->threads) + "  ctx: " + std::to_string(config->context_size));
    say("token budget for this input: " + std::to_string(rewrite_text::token_budget(sample, config->max_tokens)));
    RewriteEngine engine(*config);
    try {
        auto start = clock_type::now();
        const auto first = engine.rewrite(sample, RewriteMode::fix_grammar);
        say("\ncold (spawn + load + generate): " + ms(clock_type::now() - start));
        say("  " + utf16_to_utf8(first));
        std::vector<long long> t;
        for (int i = 0; i < iterations; ++i) {
            // Varied, so no cache answers for the model.
            const auto varied = sample + std::u16string(static_cast<size_t>(i), u' ');
            start = clock_type::now();
            engine.rewrite(varied, RewriteMode::fix_grammar);
            t.push_back(std::chrono::duration_cast<std::chrono::milliseconds>(clock_type::now() - start).count());
        }
        std::sort(t.begin(), t.end());
        say("\nwarm x" + std::to_string(iterations) + ": min " + std::to_string(t.front()) + "ms, median "
            + std::to_string(t[t.size() / 2]) + "ms, max " + std::to_string(t.back()) + "ms");
        return 0;
    } catch (const RewriteException& e) {
        say("bench failed: " + utf16_to_utf8(e.error.description()));
        return 1;
    }
}

// Every stage printed: where espeak was found, which runtime loaded, the
// phonemes, the tokens, the samples and the peak.
int speak(const std::u16string& text, const std::string& voice_in, bool play) {
    try {
        const auto espeak_dir = speech::Espeak::installed_directory();
        say("espeak:   " + (espeak_dir ? espeak_dir->string() : std::string("NOT FOUND")));
        auto& espeak = speech::Espeak::shared();
        say("          sample rate " + std::to_string(espeak.sample_rate()));
        const auto runtime = speech::Kokoro::runtime();
        say("runtime:  " + (runtime ? runtime->string() : std::string("NOT FOUND")));
        const auto model = speech::voice_catalog::installed_model();
        const auto pack_path = speech::voice_catalog::installed_voice_pack();
        say("model:    " + (model ? model->string() : std::string("NOT INSTALLED")));
        say("voices:   " + (pack_path ? pack_path->string() : std::string("NOT INSTALLED")));
        if (!runtime || !model || !pack_path) return 1;

        const auto start = clock_type::now();
        speech::Kokoro engine(*model, *runtime);
        say("loaded:   onnxruntime " + engine.runtime_version() + ", input '" + engine.token_input() + "' in "
            + ms(clock_type::now() - start));
        const speech::VoicePack pack(*pack_path);
        const std::string voice = voice_in.empty() ? speech::voice_catalog::default_voice : voice_in;
        say("voice:    " + voice + " (" + std::to_string(pack.names().size()) + " in the pack)");

        const auto phonemes = speech::phonemizer::phonemes(speech::to_u32(text),
                                                           [&](const std::u32string& c) { return espeak.phonemes(c); });
        say("phonemes: " + speech::to_utf8(phonemes));
        const auto unknown = kokoro::unknown_symbols(phonemes);
        if (!unknown.empty()) say("unknown:  " + speech::to_utf8(unknown));

        speech::Synthesizer synth{engine, pack, [&](const std::u32string& c) { return espeak.phonemes(c); }};
        synth.voice = voice;
        std::vector<float> all;
        int batches = 0;
        audio::Player player;
        bool started = false;
        std::atomic<bool> finished{false};
        const auto synth_start = clock_type::now();
        synth.synthesise(text, [] { return false; }, [&](std::vector<float> batch, bool last) {
            ++batches;
            all.insert(all.end(), batch.begin(), batch.end());
            if (play) {
                if (!started) {
                    started = true;
                    player.begin([&] { finished = true; });
                }
                player.enqueue(batch, last);
            }
        });
        const double seconds = static_cast<double>(all.size()) / speech::Kokoro::sample_rate;
        const auto took = std::chrono::duration<double>(clock_type::now() - synth_start).count();
        char line[160];
        std::snprintf(line, sizeof line, "audio:    %d batch(es), %zu samples, %.2fs, peak %.3f, %.1fx real time",
                      batches, all.size(), seconds, speech::audio::peak(all), took > 0 ? seconds / took : 0);
        say(line);
        if (play) {
            say("playing...");
            while (!finished) std::this_thread::sleep_for(std::chrono::milliseconds(50));
            say("done");
        }
        return 0;
    } catch (const std::exception& e) {
        say(std::string("speak failed: ") + e.what());
        return 1;
    }
}

int whisper_probe(const std::string& model_arg, const std::string& audio_arg) {
    const auto lib = speech::Whisper::library();
    say("library:  " + (lib ? lib->string() : std::string("NOT FOUND")));
    if (!lib) return 1;
    try {
        say("system:   " + speech::Whisper::system_info());
    } catch (const std::exception& e) {
        say(std::string("could not load whisper: ") + e.what());
        return 1;
    }
    const auto model = model_arg.empty() ? speech::whisper_catalog::installed()
                                         : std::optional<std::filesystem::path>(std::filesystem::u8path(model_arg));
    say("model:    " + (model ? model->string() : std::string("NOT INSTALLED")));
    if (!model || audio_arg.empty()) return model ? 0 : 1;
    try {
        const auto samples = speech::audio::load_wav(std::filesystem::u8path(audio_arg));
        say("audio:    " + std::to_string(samples.size()) + " samples, "
            + std::to_string(speech::audio::duration(samples)).substr(0, 5) + "s, peak "
            + std::to_string(speech::audio::peak(samples)).substr(0, 5));
        speech::Whisper w(*model);
        const auto start = clock_type::now();
        const auto text = w.transcribe(samples, speech::vocabulary::prompt(speech::vocabulary::terms()));
        say("text:     " + utf16_to_utf8(text));
        say("took:     " + ms(clock_type::now() - start));
        return 0;
    } catch (const std::exception& e) {
        say(std::string("failed: ") + e.what());
        return 1;
    }
}

int rehearse(const std::u16string& option) {
    const auto model = speech::whisper_catalog::installed();
    if (!model) {
        say("no speech model installed");
        return 1;
    }
    std::vector<float> samples;
    const bool is_file = option.size() > 4 && lowercased(option).substr(option.size() - 4) == u".wav";
    try {
        if (is_file) {
            samples = speech::audio::load_wav(std::filesystem::path(wide(option)));
        } else {
            const int limit = option.empty() ? 0 : std::stoi(utf16_to_utf8(option));
            audio::Recorder recorder;
            recorder.start();
            say(limit ? "recording for " + std::to_string(limit) + "s..." : "recording -- press Enter to stop");
            if (limit) std::this_thread::sleep_for(std::chrono::seconds(limit));
            else std::getchar();
            samples = recorder.stop();
        }
        const double duration = speech::audio::duration(samples);
        speech::Whisper w(*model);
        const auto segments = w.transcribe_segments(samples, speech::vocabulary::prompt(speech::vocabulary::terms()));
        const speech::DeliveryReport report(segments, duration);
        say(speech::practice::markdown(segments, report, u"(this take)", std::time(nullptr)));
        return 0;
    } catch (const std::exception& e) {
        say(std::string("rehearse failed: ") + e.what());
        return 1;
    }
}

int field_probe(int delay) {
    say("Click into a text field in the app you want to test.");
    for (int i = delay; i > 0; --i) {
        say("  probing in " + std::to_string(i) + "...");
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    text::Uia uia;
    say(lf(probe_field(uia)));
    return 0;
}

// Where marks would go for the focused field: the bounds of every word.
int marker_probe(int delay) {
    for (int i = delay; i > 0; --i) {
        say("  probing in " + std::to_string(i) + "...");
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    text::Uia uia;
    auto field = uia.focused();
    if (!field || !text::may_read(*field)) {
        say("no readable field has focus");
        return 1;
    }
    const auto text = uia.text(*field).value_or(u"");
    const auto frame = uia.frame(*field);
    say("app " + narrow(field->app) + ", " + std::to_string(text.size()) + " characters");
    if (frame) say("frame " + std::to_string(frame->left) + "," + std::to_string(frame->top) + " "
                   + std::to_string(frame->right - frame->left) + "x" + std::to_string(frame->bottom - frame->top));
    int drawn = 0, missing = 0;
    for (const auto& t : nib::tokenize(u16view(reinterpret_cast<const uint16_t*>(text.data()), static_cast<int32_t>(text.size())))) {
        const auto rects = uia.bounds(*field, t.range);
        if (rects.empty()) ++missing;
        else ++drawn;
        if (drawn + missing <= 12) {
            say("  " + std::to_string(t.range.location) + "+" + std::to_string(t.range.length) + " -> "
                + (rects.empty() ? std::string("no bounds")
                                 : std::to_string(rects[0].left) + "," + std::to_string(rects[0].top) + " "
                                       + std::to_string(rects[0].right - rects[0].left) + "x"
                                       + std::to_string(rects[0].bottom - rects[0].top)));
        }
    }
    say(std::to_string(drawn) + " words placeable, " + std::to_string(missing) + " without bounds");
    return 0;
}

// The live pipeline without the overlay: focus, text, lint, bounds -- printed
// as it happens, so the stage that stops is visible.
int live_probe(int seconds) {
    const auto harper = locate_harper();
    if (!harper) {
        say("harper-ls not found");
        return 1;
    }
    HarperEngine engine(harper->u16string());
    text::Uia uia;
    std::u16string last;
    const auto until = clock_type::now() + std::chrono::seconds(seconds);
    say("watching for " + std::to_string(seconds) + "s -- click into a field and type");
    while (clock_type::now() < until) {
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        auto field = uia.focused();
        if (!field || !text::may_read(*field)) continue;
        const auto text = uia.text(*field).value_or(u"");
        if (text == last) continue;
        last = text;
        try {
            const auto found = engine.lint(text);
            int placed = 0;
            for (const auto& s : found) placed += uia.bounds(*field, s.range).empty() ? 0 : 1;
            say(narrow(field->app) + " " + narrow(field->role) + ": " + std::to_string(text.size()) + " chars, "
                + std::to_string(found.size()) + " suggestions, " + std::to_string(placed) + " placeable");
        } catch (const std::exception& e) {
            say(std::string("lint failed: ") + e.what());
        }
    }
    return 0;
}

void help() {
    say("nib -- offline writing assistant\n");
    say("usage:");
    say("  nib                              run in the notification area");
    say("  nib --lint \"text\"                check text and print suggestions");
    say("  nib --rewrite \"text\" [model]     run all four rewrite modes, with timings");
    say("  nib --speak \"text\" [voice]       read aloud, printing every stage");
    say("  nib --speak-silent \"text\"        the same, without playing it");
    say("  nib --whisper-probe [model] [wav] report the speech engine; transcribe a file");
    say("  nib --rehearse [seconds|take.wav] record yourself, report how you spoke");
    say("  nib --model-bench [n]            time model load, first call, warm calls");
    say("  nib --bench [words]              measure lint latency");
    say("  nib --field-probe [seconds]      report what the focused field exposes");
    say("  nib --live-probe [seconds]       trace the inline pipeline");
    say("  nib --marker-probe [seconds]     check where underlines would be placed");
}

int number(int argc, wchar_t** argv, int i, int fallback) {
    if (i >= argc) return fallback;
    try {
        return std::stoi(narrow(argv[i]));
    } catch (...) {
        return fallback;
    }
}

}  // namespace

int run_cli(int argc, wchar_t** argv) {
    if (argc < 2) return -1;
    const std::wstring cmd = argv[1];
    static const wchar_t* commands[] = {L"--lint",       L"--rewrite",     L"--speak",       L"--speak-silent",
                                        L"--whisper-probe", L"--rehearse", L"--model-bench", L"--bench",
                                        L"--field-probe", L"--ax-probe",   L"--live-probe",  L"--marker-probe",
                                        L"--help",       L"-h",            L"--version"};
    bool known = false;
    for (auto c : commands) known |= cmd == c;
    if (!known) return -1;

    attach_console();
    if (cmd == L"--help" || cmd == L"-h") {
        help();
        return 0;
    }
    if (cmd == L"--version") {
        say("nib " NIB_VERSION);
        return 0;
    }
    if (cmd == L"--lint") return lint(argc > 2 ? arg(argc, argv, 2) : read_stdin());
    if (cmd == L"--bench") return bench(number(argc, argv, 2, 2000), 10);
    if (cmd == L"--rewrite") {
        const auto text = argc > 2 ? arg(argc, argv, 2)
                                   : u"Their is many erors in this sentance, and it are very long and wordy in a way that "
                                     u"could of been much more shorter.";
        return rewrite(text, argc > 3 ? narrow(argv[3]) : std::string());
    }
    if (cmd == L"--model-bench") return model_bench({}, number(argc, argv, 2, 5));
    if (cmd == L"--speak") return speak(argc > 2 ? arg(argc, argv, 2) : read_stdin(), argc > 3 ? narrow(argv[3]) : "", true);
    if (cmd == L"--speak-silent") {
        return speak(argc > 2 ? arg(argc, argv, 2) : u"The quick brown fox jumps over the lazy dog.",
                     argc > 3 ? narrow(argv[3]) : "", false);
    }
    if (cmd == L"--whisper-probe") return whisper_probe(argc > 2 ? narrow(argv[2]) : "", argc > 3 ? narrow(argv[3]) : "");
    if (cmd == L"--rehearse") return rehearse(arg(argc, argv, 2));
    if (cmd == L"--field-probe" || cmd == L"--ax-probe") return field_probe(number(argc, argv, 2, 5));
    if (cmd == L"--live-probe") return live_probe(number(argc, argv, 2, 20));
    if (cmd == L"--marker-probe") return marker_probe(number(argc, argv, 2, 5));
    return -1;
}

}  // namespace nib::app
