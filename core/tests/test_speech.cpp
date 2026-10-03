// Port of PhonemizerTests, PhonemeChunkerTests, KokoroTokenizerTests,
// SpeechPipelineTests (the parts without a model), TranscriptCleaningTests,
// SilenceDetectionTests, DeliveryReportTests, DictationHistoryTests,
// SpeechVocabularyTests and DictationStateTests -- the first three against the
// same fixtures the Swift suite reads, captured from the Python engine.
#include "test_support.hpp"
#include <catch2/catch_approx.hpp>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <map>
#include <random>
#include <set>
#include <nlohmann/json.hpp>
#include "speech/audio.hpp"
#include "speech/dictation_text.hpp"
#include "speech/kokoro_vocab.hpp"
#include "speech/practice.hpp"
#include "speech/speech_state.hpp"
#include "speech/speech_text.hpp"

using namespace nib;
using namespace nib::speech;
using json = nlohmann::json;
namespace fs = std::filesystem;

namespace {

json fixture(const char* name) {
    std::ifstream in(fs::path(NIB_GOLDEN_DIR) / ".." / "macos" / "Tests" / "Fixtures" / name);
    REQUIRE(in);
    return json::parse(in);
}

std::u32string u32(const json& j) { return to_u32(j.get<std::string>()); }

PhonemeSource recorded(const json& entry) {
    auto answers = std::make_shared<std::map<std::u32string, std::u32string>>();
    auto add = [&](const char* chunks, const char* phonemes) {
        for (size_t i = 0; i < entry[chunks].size(); ++i) answers->emplace(u32(entry[chunks][i]), u32(entry[phonemes][i]));
    };
    add("preserved_chunks", "chunk_phonemes");
    add("nib_chunks", "nib_chunk_phonemes");
    return [answers](const std::u32string& chunk) -> std::u32string {
        const auto it = answers->find(chunk);
        if (it == answers->end()) FAIL("espeak was asked for a chunk the engine never produced: " << to_utf8(chunk));
        return it->second;
    };
}

const std::set<std::string> divergences = {"decimal-point"};

std::string p(const char* position) {
    return position;
}

const char* position_name(punctuation::Position pos) {
    switch (pos) {
    case punctuation::Position::begin:  return "B";
    case punctuation::Position::end:    return "E";
    case punctuation::Position::inside: return "I";
    case punctuation::Position::alone:  return "A";
    }
    return "?";
}

}  // namespace

TEST_CASE("Phonemizer matches the engine over the corpus") {
    const auto golden = fixture("phonemes-golden.json");
    for (const auto& entry : golden["entries"]) {
        const auto name = entry["name"].get<std::string>();
        INFO(name);
        const auto text = u32(entry["text"]);
        if (!divergences.count(name)) {
            CHECK(to_utf8(phonemizer::phonemes(text, recorded(entry))) == entry["phonemes"].get<std::string>());
            CHECK(to_utf8(phonemizer::phonemize(text, recorded(entry))) == entry["phonemizer"].get<std::string>());
        }
        const auto preserved = punctuation::preserve(text);
        std::vector<std::string> chunks;
        for (const auto& c : preserved.chunks) chunks.push_back(to_utf8(c));
        CHECK(chunks == entry["nib_chunks"].get<std::vector<std::string>>());
        REQUIRE(preserved.marks.size() == entry["marks"].size());
        for (size_t i = 0; i < preserved.marks.size(); ++i) {
            CHECK(to_utf8(preserved.marks[i].text) == entry["marks"][i]["mark"].get<std::string>());
            CHECK(std::string(position_name(preserved.marks[i].position)) == entry["marks"][i]["position"].get<std::string>());
        }
    }
}

TEST_CASE("A decimal is spoken as a decimal") {
    const auto golden = fixture("phonemes-golden.json");
    for (const auto& entry : golden["entries"]) {
        if (entry["name"] != "decimal-point") continue;
        const auto phonemes = to_utf8(phonemizer::phonemes(u32(entry["text"]), recorded(entry)));
        CHECK(phonemes.find("pɔɪnt") != std::string::npos);
        CHECK(phonemes != entry["phonemes"].get<std::string>());
    }
}

TEST_CASE("The mark set is phonemizer's own") {
    const auto golden = fixture("phonemes-golden.json");
    const auto expected = u32(golden["punctuation_marks"]);
    CHECK(std::set<char32_t>(expected.begin(), expected.end())
          == std::set<char32_t>(punctuation::default_marks().begin(), punctuation::default_marks().end()));
}

TEST_CASE("Punctuation rules") {
    auto pr = punctuation::preserve(U"It costs 19,99 euro.");
    REQUIRE(pr.chunks.size() == 1);
    CHECK(pr.chunks[0] == U"It costs 19,99 euro");
    REQUIRE(pr.marks.size() == 1);
    CHECK(pr.marks[0].text == U".");

    pr = punctuation::preserve(U"hello, my world!");
    REQUIRE(pr.marks.size() == 2);
    CHECK(pr.marks[0].text == U", ");
    CHECK(punctuation::preserve(U"a b c").marks.empty());

    pr = punctuation::preserve(U"...");
    CHECK(pr.chunks.empty());
    REQUIRE(pr.marks.size() == 1);
    CHECK(pr.marks[0].position == punctuation::Position::alone);
}

TEST_CASE("Tidying espeak output") {
    CHECK(phonemizer::tidy(U"ð_ə k_w_ˈɪ_k") == U"ðə kwˈɪk ");
    CHECK(phonemizer::tidy(U"h_ə__l_ˈoʊ") == U"həlˈoʊ ");
    CHECK(phonemizer::tidy(U"") == U"");
    CHECK(phonemizer::tidy(U"   ") == U"");
}

TEST_CASE("Chunker matches the engine") {
    const auto golden = fixture("phonemes-golden.json");
    bool split_seen = false, over_context = false;
    for (const auto& entry : golden["entries"]) {
        INFO(entry["name"].get<std::string>());
        const auto phonemes = u32(entry["phonemes"]);
        const auto batches = chunker::split(phonemes);
        REQUIRE(batches.size() == entry["batches"].size());
        for (size_t i = 0; i < batches.size(); ++i) {
            const auto& expected = entry["batches"][i];
            CHECK(to_utf8(batches[i]) == expected["phonemes"].get<std::string>());
            CHECK(batches[i].size() <= 510);
            CHECK(chunker::pause_after(u32(expected["phonemes"]), 0.25, 0.1)
                  == Catch::Approx(expected["pause_after"].get<double>()));
            // The tokenizer agrees with the engine batch by batch.
            CHECK(kokoro::tokenize(batches[i]) == expected["token_ids"].get<std::vector<int32_t>>());
        }
        if (batches.size() > 1) split_seen = true;
        if (entry["token_count"].get<int>() > kokoro::max_phonemes) over_context = true;
    }
    CHECK(split_seen);
    CHECK(over_context);
}

TEST_CASE("Chunker rules") {
    CHECK(chunker::split(U"").empty());
    CHECK(chunker::split(U"short text.").size() == 1);
    std::u32string word(1200, U'a');
    const auto sliced = chunker::split(word);
    size_t total = 0;
    for (const auto& b : sliced) total += b.size();
    CHECK(total == 1200);
    CHECK(chunker::pause_after(U"end. ", 0.25, 0.1) == 0.25);
    CHECK(chunker::pause_after(U"pause,", 0.25, 0.1) == 0.1);
    CHECK(chunker::pause_after(U"", 0.25, 0.1) == 0);

    std::u32string many;
    for (int i = 0; i < 120; ++i) many += U"wˈɜːd wˈɜːd. ";
    const auto streamed = chunker::streaming(many);
    REQUIRE(streamed.size() > 2);
    CHECK(streamed[0].size() <= static_cast<size_t>(chunker::lead_in));
    for (const auto& b : streamed) CHECK(b.size() <= 510);
}

TEST_CASE("Tokenizer against the engine") {
    const auto golden = fixture("kokoro-golden.json");
    CHECK(kokoro::tokenize(u32(golden["phonemes"])) == golden["token_ids"].get<std::vector<int32_t>>());
    CHECK(kokoro::tokenize(U"").empty());
    CHECK_THROWS(kokoro::tokenize(std::u32string(511, U'a')));
    CHECK_NOTHROW(kokoro::tokenize(std::u32string(510, U'a')));
    CHECK(kokoro::tokenize(U"a[b") == kokoro::tokenize(U"ab"));
    std::set<int32_t> ids;
    for (const auto& [c, id] : kokoro::vocab()) {
        CHECK(id != 0);
        ids.insert(id);
    }
    CHECK(ids.size() == kokoro::vocab().size());
}

TEST_CASE("Audio trim and level") {
    CHECK(trim::bounds(std::vector<float>(48'000, 0.f)).end == 0);
    CHECK(trim::bounds({0.5f}).end <= 1);
    std::vector<float> s(48'000, 0.f);
    for (size_t i = 20'000; i < 28'000; ++i) s[i] = 0.5f * std::sin(i * 0.05f);
    const auto r = trim::bounds(s);
    CHECK(r.start > 15'000);
    CHECK(r.end < 33'000);
    CHECK(r.start < 20'000);
    CHECK(r.end > 28'000);
    const auto loud = leveled({0.9f, -0.9f}, 2.f);
    CHECK(loud[0] == 1.f);
    CHECK(loud[1] == -1.f);
    CHECK(leveled({0.5f}, 0.5f)[0] == Catch::Approx(0.25f));
}

TEST_CASE("Speech state machine") {
    using K = SpeechState::Kind;
    using E = SpeechState::Event;
    SpeechState idle{};
    CHECK(idle.next(E::toggled)->kind == K::preparing);
    for (auto k : {K::preparing, K::synthesising, K::speaking}) {
        CHECK(SpeechState{k}.next(E::toggled)->kind == K::idle);
        CHECK(SpeechState{k}.next(E::hushed)->kind == K::idle);
    }
    CHECK_FALSE(idle.next(E::hushed));
    CHECK_FALSE(SpeechState{K::failed, u"x"}.next(E::hushed));
    CHECK(SpeechState{K::preparing}.next(E::loaded)->kind == K::synthesising);
    CHECK(SpeechState{K::synthesising}.next(E::synthesised)->kind == K::speaking);
    CHECK(SpeechState{K::speaking}.next(E::finished)->kind == K::idle);
    CHECK_FALSE(SpeechState{K::synthesising}.next(E::finished));
    CHECK(SpeechState{K::failed, u"x"}.next(E::toggled)->kind == K::preparing);
}

TEST_CASE("Dictation state machine") {
    using K = DictationState::Kind;
    using E = DictationState::Event;
    DictationState s{};
    const std::pair<E, DictationState> journey[] = {
        {E::toggled, {K::requesting_access}}, {E::access_granted, {K::recording}}, {E::toggled, {K::transcribing}},
        {E::transcribed, {K::inserting, u"hello there"}}, {E::inserted, {K::idle}}};
    for (const auto& [event, expected] : journey) {
        const auto next = s.next(event, u"hello there");
        REQUIRE(next);
        CHECK(*next == expected);
        s = *next;
    }
    CHECK_FALSE(DictationState{K::transcribing}.next(E::toggled));
    CHECK(DictationState{K::transcribing}.next(E::transcribed, u"")->kind == K::idle);
    CHECK(DictationState{K::recording}.next(E::reached_limit)->kind == K::transcribing);
    CHECK(contains(DictationState{K::requesting_access}.next(E::access_denied)->text, u"microphone"));
    CHECK_FALSE(DictationState{}.next(E::failed, u"late"));

    int allowed = 0;
    for (auto k : {K::idle, K::requesting_access, K::recording, K::transcribing, K::inserting, K::failed}) {
        for (auto e : {E::toggled, E::access_granted, E::access_denied, E::reached_limit, E::transcribed, E::inserted,
                       E::cancelled, E::failed}) {
            if (DictationState{k, u"t"}.next(e, u"t")) ++allowed;
        }
    }
    CHECK(allowed == 16);
}

TEST_CASE("Transcript cleaning") {
    CHECK(clean_transcript(u"[BLANK_AUDIO]") == u"");
    CHECK(clean_transcript(u"[BLANK_AUDIO][BLANK_AUDIO]") == u"");
    CHECK(clean_transcript(u" [BLANK_AUDIO] \n") == u"");
    CHECK(clean_transcript(u"[SILENCE] [MUSIC] [INAUDIBLE]").empty());
    for (auto marker : {u"[SILENCE]", u"[MUSIC]", u"[NOISE]", u"[INAUDIBLE]", u"[ Silence ]", u"[BLANK _AUDIO]"}) {
        CHECK(clean_transcript(std::u16string(u"hello ") + marker + u" there") == u"hello there");
    }
    CHECK(clean_transcript(u"well *coughs* anyway") == u"well anyway");
    CHECK(clean_transcript(u"(upbeat music) hello") == u"hello");
    CHECK(clean_transcript(u"hello (laughs)") == u"hello");
    CHECK(clean_transcript(u"(wind blowing) start now") == u"start now");
    const std::u16string aside = u"the total (which we agreed last week, remember) was wrong";
    CHECK(clean_transcript(aside) == aside);
    CHECK(clean_transcript(u"call me (555) later") == u"call me (555) later");
    CHECK(clean_transcript(u"Hello [BLANK_AUDIO], there") == u"Hello, there");
    CHECK(clean_transcript(u"Right [SILENCE]. Next.") == u"Right. Next.");
    CHECK(clean_transcript(u"one   two\n\nthree") == u"one two three");
    CHECK(clean_transcript(u"  hello there  ") == u"hello there");
    CHECK(clean_transcript(u"   ").empty());
}

TEST_CASE("Silence detection") {
    auto tone = [](float amplitude) {
        std::vector<float> out(16'000);
        for (size_t i = 0; i < out.size(); ++i) out[i] = amplitude * std::sin(i * 0.1f);
        return out;
    };
    CHECK(audio::silent(std::vector<float>(16'000, 0.f)));
    CHECK(audio::silent(tone(0.00003f)));
    CHECK_FALSE(audio::silent(tone(0.8f)));
    CHECK_FALSE(audio::silent(tone(0.02f)));
    std::vector<float> blip(16'000, 0.f);
    std::fill(blip.begin() + 8'000, blip.begin() + 8'100, 0.5f);
    CHECK_FALSE(audio::silent(blip));
    CHECK(audio::peak({-0.7f, 0.2f, -0.1f}) == Catch::Approx(0.7f));
    CHECK(audio::peak({}) == 0);
}

TEST_CASE("Resampling keeps the tone and drops the alias") {
    // A 1kHz tone at 48kHz comes out as a 1kHz tone at 16kHz at the same level.
    std::vector<float> in(48'000);
    for (size_t i = 0; i < in.size(); ++i) in[i] = 0.5f * std::sin(2 * 3.14159265f * 1000 * i / 48'000.f);
    const auto out = audio::resample(in, 48'000, 16'000);
    REQUIRE(out.size() == 16'000);
    float peak = 0;
    for (size_t i = 100; i < out.size() - 100; ++i) peak = std::max(peak, std::abs(out[i]));
    CHECK(peak == Catch::Approx(0.5f).margin(0.03));
    // 12kHz is above the new Nyquist (8kHz) and must not fold back in.
    for (size_t i = 0; i < in.size(); ++i) in[i] = 0.5f * std::sin(2 * 3.14159265f * 12'000 * i / 48'000.f);
    const auto alias = audio::resample(in, 48'000, 16'000);
    float leak = 0;
    for (size_t i = 100; i < alias.size() - 100; ++i) leak = std::max(leak, std::abs(alias[i]));
    CHECK(leak < 0.05f);
}

TEST_CASE("WAV round trip") {
    std::random_device rd;
    const auto file = fs::temp_directory_path() / ("nib-wav-" + std::to_string(rd()) + ".wav");
    audio::write_wav(file, {0, 0.5f, -0.5f, 1, -1, 2, -2});
    CHECK(fs::file_size(file) == 44 + 7 * 2);
    const auto back = audio::load_wav(file);
    REQUIRE(back.size() == 7);
    CHECK(back[1] == Catch::Approx(0.5f).margin(0.001));
    CHECK(back[5] == Catch::Approx(1.f).margin(0.001));  // clamped, not wrapped
    CHECK(back[6] < 0);
    fs::remove(file);
}

TEST_CASE("Delivery report") {
    auto seg = [](const char16_t* t, double a, double b) { return SpokenSegment{t, a, b}; };
    auto r = DeliveryReport({seg(u"Um, so basically um the answer is yes.", 0, 10)}, 10);
    CHECK(r.filler_total == 4);
    REQUIRE_FALSE(r.fillers.empty());
    CHECK(r.fillers[0].first == u"um");
    CHECK(r.fillers[0].second == 2);

    r = DeliveryReport({seg(u"It was, you know, the right call.", 0, 10)}, 10);
    CHECK(r.filler_total == 1);
    CHECK(r.fillers[0].first == u"you know");

    CHECK(DeliveryReport({seg(u"um the fix", 0, 5)}, 5).filler_total
          == DeliveryReport({seg(u"Um. The fix", 0, 5)}, 5).filler_total);
    CHECK(DeliveryReport({seg(u"um um", 0, 30)}, 30).filler_rate() == Catch::Approx(4));
    CHECK(DeliveryReport({seg(u"um um", 0, 60)}, 60).filler_rate() == Catch::Approx(2));

    std::u16string words;
    for (int i = 0; i < 60; ++i) words += u"word ";
    CHECK(DeliveryReport({{words, 0, 30}}, 30).pace == Catch::Approx(120).margin(0.5));
    CHECK(DeliveryReport({{words, 0, 30}}, 60).pace == Catch::Approx(60).margin(0.5));

    const DeliveryReport empty({}, 0);
    CHECK(empty.pace == 0);
    CHECK(empty.filler_rate() == 0);
    CHECK(empty.word_count == 0);

    r = DeliveryReport({seg(u"So the first thing", 0, 4), seg(u"was the index", 7.5, 10)}, 10);
    REQUIRE(r.long_pauses.size() == 1);
    CHECK(r.long_pauses[0].first == Catch::Approx(4));
    CHECK(r.long_pauses[0].second == Catch::Approx(3.5));
    CHECK(DeliveryReport({seg(u"one", 0, 2), seg(u"two", 2.4, 4), seg(u"three", 4.9, 6)}, 6).long_pauses.empty());

    std::u16string forty;
    for (int i = 0; i < 40; ++i) forty += (i ? u" word" : u"word");
    CHECK(DeliveryReport({{u"Short one. " + forty + u". Also short.", 0, 30}}, 30).longest_sentence == 40);
    CHECK(DeliveryReport({seg(u"We fixed the query, so yeah", 0, 10)}, 10).trails_off);
    CHECK_FALSE(DeliveryReport({seg(u"Restoring the limit dropped CPU to normal.", 0, 10)}, 10).trails_off);

    const auto advice = practice::advice(DeliveryReport({seg(u"um um um um um um so yeah", 0, 10)}, 10));
    REQUIRE_FALSE(advice.empty());
    CHECK(contains(advice[0], u"full stop"));
    std::u16string points;
    for (int i = 0; i < 25; ++i) points += (i ? u" point" : u"point");
    CHECK(practice::advice(DeliveryReport({{points + u".", 0, 10}}, 10)).empty());

    const std::vector<SpokenSegment> take{seg(u"So we shipped it.", 0, 3)};
    const auto md = practice::markdown(take, DeliveryReport(take, 3), u"take.wav", 1'700'000'000);
    CHECK(contains(md, u"take.wav"));
    CHECK(contains(md, u"## Delivery"));
    CHECK(contains(md, u"## Transcript"));
    CHECK(contains(md, u"So we shipped it."));
    CHECK(practice::time(0) == u"0:00");
    CHECK(practice::time(9) == u"0:09");
    CHECK(practice::time(75) == u"1:15");
    CHECK(practice::time(600) == u"10:00");
}

TEST_CASE("Dictation history") {
    DictationHistory h;
    h.add(u"first");
    h.add(u"second");
    REQUIRE(h.entries().size() == 2);
    CHECK(h.entries()[0].text == u"second");

    DictationHistory many;
    for (int i = 1; i <= 120; ++i) many.add(u"line " + to_u16(i));
    CHECK(many.entries().size() == DictationHistory::limit);
    CHECK(many.entries().front().text == u"line 120");
    CHECK(many.entries().back().text == u"line 21");

    DictationHistory twice;
    twice.add(u"hello there");
    twice.add(u"hello there");
    CHECK(twice.entries().size() == 1);
    twice.add(u"something else");
    twice.add(u"hello there");
    CHECK(twice.entries().size() == 3);

    DictationHistory blank;
    blank.add(u"");
    blank.add(u"   \n  ");
    CHECK(blank.entries().empty());
    blank.add(u"  spoken words  ");
    CHECK(blank.entries()[0].text == u"spoken words");

    const DictationHistory::Entry long_entry{
        u"the beginning of a long dictation that goes on for a while before finally reaching its own distinctive ending", 0};
    CHECK(starts_with(long_entry.label(), u"the beginning"));
    CHECK(ends_with(long_entry.label(), u"distinctive ending"));
    CHECK(contains(long_entry.label(), u"…"));
    CHECK(DictationHistory::Entry{u"a short one", 0}.label() == u"a short one");
    CHECK(DictationHistory::Entry{u"line one\nline two", 0}.label() == u"line one line two");

    std::random_device rd;
    const auto file = fs::temp_directory_path() / ("nib-history-" + std::to_string(rd()) + ".json");
    DictationHistory saved;
    saved.add(u"something worth keeping");
    saved.save(file);
    CHECK(DictationHistory::load(file).entries().at(0).text == u"something worth keeping");
    CHECK(DictationHistory::load(fs::temp_directory_path() / "nib-no-such-history.json").entries().empty());
    json big = json::array();
    for (int i = 1; i <= 250; ++i) big.push_back({{"text", "line " + std::to_string(i)}, {"date", 0}});
    std::ofstream(file) << big.dump();
    CHECK(DictationHistory::load(file).entries().size() == DictationHistory::limit);
    fs::remove(file);
}

TEST_CASE("Speech vocabulary") {
    CHECK(vocabulary::prompt({u"Hasura", u"useMemo"}) == u"Terms used: Hasura, useMemo.");
    CHECK_FALSE(vocabulary::prompt({}));
    std::vector<std::u16string> many;
    for (int i = 1; i <= 500; ++i) many.push_back(u"term" + to_u16(i));
    CHECK(vocabulary::prompt(many)->size() < 1'000);
    for (const auto& t : vocabulary::defaults()) {
        CHECK_FALSE(t.empty());
        CHECK(t.find(u',') == std::u16string::npos);
    }
    CHECK(vocabulary::parse(u"# a comment\nHasura\n  useMemo\n# another\nGraphQL\n")
          == std::vector<std::u16string>{u"Hasura", u"useMemo", u"GraphQL"});
    CHECK(vocabulary::file().filename() == L"vocabulary.txt");
}
