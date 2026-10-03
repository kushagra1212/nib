// The speech engines against the real libraries and models. Skipped when the
// engines or models are absent, so a bare checkout still runs everything else.
#include "test_support.hpp"
#include <catch2/catch_approx.hpp>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include "speech/audio.hpp"
#include "speech/engines.hpp"
#include "speech/kokoro_vocab.hpp"
#include "speech/speech_catalog.hpp"

using namespace nib;
using namespace nib::speech;
namespace fs = std::filesystem;

namespace {

nlohmann::json fixture(const char* name) {
    std::ifstream in(fs::path(NIB_GOLDEN_DIR) / ".." / "macos" / "Tests" / "Fixtures" / name);
    return nlohmann::json::parse(in);
}

}  // namespace

TEST_CASE("espeak-ng phonemises as the engine does", "[engine][speech]") {
    if (!Espeak::installed_directory()) SKIP("espeak-ng not fetched");
    auto& espeak = Espeak::shared();
    CHECK(espeak.sample_rate() > 0);
    // The whole path with live espeak, against what the Python engine said.
    const auto golden = fixture("phonemes-golden.json");
    int matched = 0, total = 0;
    for (const auto& entry : golden["entries"]) {
        if (entry["name"] == "decimal-point") continue;
        ++total;
        const auto ours = to_utf8(phonemizer::phonemes(to_u32(entry["text"].get<std::string>()),
                                                       [&](const std::u32string& c) { return espeak.phonemes(c); }));
        if (ours == entry["phonemes"].get<std::string>()) ++matched;
        else UNSCOPED_INFO(entry["name"].get<std::string>() << ": " << ours);
    }
    // espeak's data ships inside the loader wheel and is the same 1.52 the
    // fixture was captured with; every entry should agree.
    CHECK(matched == total);
}

TEST_CASE("the voice pack reads the rows the engine reads", "[engine][speech]") {
    const auto pack_path = voice_catalog::installed_voice_pack();
    if (!pack_path) SKIP("voice pack not installed");
    const VoicePack pack(*pack_path);
    const auto golden = fixture("voices-golden.json");
    CHECK(pack.names().size() == golden["voice_count"].get<size_t>());
    CHECK(pack.stored());
    for (const auto& sample : golden["samples"]) {
        const auto style = pack.style(sample["voice"].get<std::string>(), sample["row"].get<int32_t>() + 1);
        REQUIRE(style.size() == sample["count"].get<size_t>());
        for (int i = 0; i < 4; ++i) {
            CHECK(style[static_cast<size_t>(i)] == Catch::Approx(sample["first_4"][i].get<float>()));
            CHECK(style[style.size() - 4 + static_cast<size_t>(i)] == Catch::Approx(sample["last_4"][i].get<float>()));
        }
    }
}

TEST_CASE("Kokoro speaks the golden sentence, and whisper hears it", "[engine][speech][model]") {
    const auto model = voice_catalog::installed_model();
    const auto pack_path = voice_catalog::installed_voice_pack();
    const auto runtime = Kokoro::runtime();
    if (!model || !pack_path || !runtime) SKIP("Kokoro model, voice pack or ONNX Runtime missing");

    // Two threads, as the fixture was captured: the thread count decides the
    // exact samples.
    Kokoro engine(*model, *runtime, Kokoro::threads);
    CHECK(engine.runtime_version() == "1.29.0");
    CHECK(engine.token_input() == "tokens");
    const VoicePack pack(*pack_path);
    const auto golden = fixture("audio-golden.json");
    const auto tokens = golden["token_ids"].get<std::vector<int32_t>>();
    const auto raw = engine.synthesise(tokens, pack.style("af_heart", golden["style_row"].get<int32_t>() + 1));

    // Same runtime, same threads, same inputs: the same length and the same
    // trimmed range as the Python engine.
    CHECK(raw.size() == golden["sample_count"].get<size_t>());
    const auto r = trim::bounds(raw);
    CHECK(r.start == golden["trimmed"]["start"].get<size_t>());
    CHECK(r.end == golden["trimmed"]["end"].get<size_t>());
    float peak = 0;
    for (float s : raw) peak = std::max(peak, std::abs(s));
    CHECK(peak == Catch::Approx(golden["peak"].get<float>()).margin(0.02));

    // Round trip: whisper transcribes what Kokoro said.
    const auto speech_model = whisper_catalog::installed();
    if (!speech_model || !Whisper::library()) SKIP("whisper model or library missing");
    Whisper whisper(*speech_model);
    const auto heard = lowercased(whisper.transcribe(audio::resample(trim::trimmed(raw), Kokoro::sample_rate, 16'000),
                                                     std::nullopt));
    INFO(utf16_to_utf8(heard));
    for (auto word : {u"quick", u"brown", u"fox", u"lazy", u"dog"}) CHECK(contains(heard, word));
    whisper.release();
}

TEST_CASE("the synthesizer streams a whole paragraph", "[engine][speech][model]") {
    const auto model = voice_catalog::installed_model();
    const auto pack_path = voice_catalog::installed_voice_pack();
    const auto runtime = Kokoro::runtime();
    if (!model || !pack_path || !runtime || !Espeak::installed_directory()) SKIP("speech engines not installed");
    Kokoro engine(*model, *runtime);
    const VoicePack pack(*pack_path);
    auto& espeak = Espeak::shared();
    Synthesizer synth{engine, pack, [&](const std::u32string& c) { return espeak.phonemes(c); }};
    int batches = 0;
    bool last_seen = false;
    size_t samples = 0;
    synth.synthesise(u"Hello there. This is nib, reading aloud on Windows; it should sound the same as on a Mac.",
                     [] { return false; },
                     [&](std::vector<float> batch, bool last) {
                         ++batches;
                         samples += batch.size();
                         last_seen = last;
                         for (float s : batch) REQUIRE(std::abs(s) <= 1.f);
                     });
    CHECK(batches >= 1);
    CHECK(last_seen);
    CHECK(samples > Kokoro::sample_rate * 2);
}
