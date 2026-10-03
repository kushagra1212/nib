// Port of RewriteCleanTests, TokenBudgetTests, ServerErrorTests,
// RewriteOutcomeTests, UnfinishedRewriteTests, ModelTrustTests, QuestionTests,
// DroppedContentTests, NativePromptTests, ModelRankingTests,
// LiveModelCostTests and ModelSetupTests -- plus ModelChecker against a fake
// model, which the Swift suite could not do without a server.
#include "test_support.hpp"
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <random>
#include <set>
#include "rewrite/model_catalog.hpp"
#include "rewrite/model_checker.hpp"
#include "rewrite/rewrite_mode.hpp"
#include "rewrite/rewrite_text.hpp"

using namespace nib;
namespace rt = nib::rewrite_text;
namespace fs = std::filesystem;

// --- RewriteCleanTests -------------------------------------------------------

TEST_CASE("RewriteClean") {
    CHECK(rt::clean(u"There are many errors.") == u"There are many errors.");
    CHECK(rt::clean(u"\n  Fixed text.  \n") == u"Fixed text.");
    CHECK(rt::clean(u"<think>The user wants grammar fixed. Their -> There.</think>\nThere are errors.")
          == u"There are errors.");
    CHECK(rt::clean(u"Here is the corrected text:\nThere are many errors.") == u"There are many errors.");
    CHECK(rt::clean(u"```\nThere are many errors.\n```") == u"There are many errors.");
    CHECK(rt::clean(u"\"There are many errors.\"") == u"There are many errors.");
    CHECK(rt::clean(u"“There are many errors.”") == u"There are many errors.");
    CHECK(rt::clean(u"She said \"hello\" to him.") == u"She said \"hello\" to him.");
    CHECK(rt::clean(u"\"Stop there, he said.") == u"\"Stop there, he said.");
    CHECK(rt::clean(u"Here is the plan\nWe ship on Friday.") == u"Here is the plan\nWe ship on Friday.");
    CHECK(rt::clean(u"First paragraph.\n\nSecond paragraph.") == u"First paragraph.\n\nSecond paragraph.");
}

// --- TokenBudgetTests --------------------------------------------------------

TEST_CASE("TokenBudget") {
    constexpr int32_t context = 2048;
    for (int n : {0, 40, 400, 1'000, 4'000, 20'000}) {
        const std::u16string text(static_cast<size_t>(n), u'a');
        const auto budget = rt::token_budget(text, 1024, context);
        INFO(n << " chars");
        CHECK(budget <= rt::headroom(text, context));
        CHECK(budget <= 1024);
        if (n / 4 + rt::prompt_overhead < context) {
            CHECK(n / 4 + rt::prompt_overhead + budget <= context);
        }
    }
    std::u16string words;
    for (int i = 0; i < 200; ++i) words += u"word ";
    CHECK(rt::token_budget(words, 1024, context) > static_cast<int32_t>(words.size()) / 4);
    CHECK(rt::token_budget(u"i has went there", 1024, context) >= 128);
    CHECK(rt::token_budget(std::u16string(100'000, u'a'), 1024, context) >= 128);
}

// --- ServerErrorTests --------------------------------------------------------

TEST_CASE("ServerError") {
    const std::string compute = R"({"error":{"code":500,"message":"Compute error.","type":"server_error"}})";
    const std::string metal =
        "0.02.088.285 E ggml_metal_synchronize: error: command buffer 0 failed with status 5\n"
        "0.02.088.288 E error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)";
    CHECK(rt::failure(500, compute, metal).kind == RewriteError::Kind::out_of_memory);

    auto alone = rt::failure(500, compute);
    CHECK(alone.kind == RewriteError::Kind::rejected);
    CHECK(alone.status == 500);
    CHECK(alone.detail == u"Compute error.");

    CHECK(contains(RewriteError{RewriteError::Kind::out_of_memory}.description(), u"smaller"));

    for (const char* text : {"Insufficient Memory", "out of memory", "OutOfMemory",
                             "kIOGPUCommandBufferCallbackErrorOutOfMemory"}) {
        INFO(text);
        CHECK(rt::failure(500, text).kind == RewriteError::Kind::out_of_memory);
        CHECK(rt::failure(500, "Compute error.", text).kind == RewriteError::Kind::out_of_memory);
    }

    auto structured = rt::failure(400, R"({"error":{"message":"context size exceeded"}})");
    CHECK(structured.kind == RewriteError::Kind::rejected);
    CHECK(structured.status == 400);
    CHECK(structured.detail == u"context size exceeded");

    CHECK(rt::failure(503, "server overloaded").detail == u"server overloaded");
    CHECK(grapheme_count(rt::failure(502, std::string(5000, 'x')).detail) <= 200);
    CHECK(contains(rt::failure(500, "").description(), u"500"));
    const auto slow = rt::failure(429, R"({"error":{"message":"slow down"}})").description();
    CHECK(contains(slow, u"429"));
    CHECK(contains(slow, u"slow down"));
}

// --- RewriteOutcomeTests -----------------------------------------------------

TEST_CASE("RewriteOutcome") {
    REQUIRE(RewriteOutcome::rewritten(u"better").applicable());
    CHECK(*RewriteOutcome::rewritten(u"better").applicable() == u"better");
    CHECK_FALSE(RewriteOutcome::unchanged().applicable());
    CHECK_FALSE(RewriteOutcome::refused(u"changed the meaning").applicable());
    CHECK_FALSE(RewriteOutcome::refused(u"cut off the ending") == RewriteOutcome::unchanged());
    CHECK_FALSE(RewriteOutcome::refused(u"dropped a clause").text.empty());
    CHECK_FALSE(RewriteOutcome::refused(u"cut off the ending")
                == RewriteOutcome::refused(u"dropped part of what you wrote"));
}

// --- UnfinishedRewriteTests --------------------------------------------------

TEST_CASE("UnfinishedRewrite") {
    for (auto ending : {u"It runs on a user's first login.", u"Does it run on first login?",
                        u"Run it now!", u"He said \"go\"", u"(as above)"}) {
        CHECK_FALSE(rt::looks_unfinished(ending));
    }
    for (auto ending : {u"Can you check the logs now, I am logging in again as",
                        u"It only runs for the first", u""}) {
        CHECK(rt::looks_unfinished(ending));
    }
    CHECK_FALSE(rt::looks_unfinished(u"All done.   \n"));

    const std::u16string original =
        u"can you check the logs now I am login again an existing user so that I can confirm it "
        u"only runs for first time login for a particular user";
    const std::u16string reordered =
        u"Can you check the logs now? I am logging in again as an existing user, so I can confirm "
        u"it only runs on a particular user's first login.";
    CHECK(rt::dropped_tail(original, reordered) >= 3);
    CHECK_FALSE(rt::looks_unfinished(reordered));
    const std::u16string cut = u"Can you check the logs now? I am logging in again as an";
    CHECK(rt::dropped_tail(original, cut) >= 3);
    CHECK(rt::looks_unfinished(cut));
}

// --- ModelTrustTests ---------------------------------------------------------

TEST_CASE("ModelTrust") {
    auto trusts = rt::is_trustworthy;
    CHECK(trusts(u"Nothing to fix here.", u"Nothing to fix here."));
    CHECK(trusts(u"Their is many erors here", u"There are many errors here"));
    CHECK(trusts(u"it could of worked", u"it could have worked"));
    const std::u16string tech = u"UTF-16 traps with NSString.length and ZWJ sequences";
    CHECK(trusts(tech, tech));
    CHECK_FALSE(trusts(u"Their is many erors in this sentance, and it are very long and wordy",
                       u"The sentence is too long and wordy."));
    CHECK_FALSE(trusts(u"What does this mean for the RN 86 upgrade and the tests",
                       u"It means you will test all the apps on both iOS and Android devices."));
    CHECK_FALSE(trusts(u"Fix this",
                       u"Certainly! Here is the corrected version of the text you provided to me today."));
    CHECK_FALSE(trusts(u"Their is many erors in this sentance and it are very long and wordy indeed",
                       u"There are errors."));
    CHECK_FALSE(trusts(u"Some real text here", u""));
    CHECK_FALSE(trusts(u"", u"Some output"));
    CHECK_FALSE(trusts(u"the cat sat on the mat", u"dogs run through open fields"));
    CHECK_FALSE(trusts(u"we should be able to solve this issue", u"we can solve this issue for you"));
    CHECK(trusts(u"the report was wrote by him", u"the report was written by him"));
    CHECK(trusts(u"the cat sat", u"The cat sat"));
}

// --- QuestionTests -----------------------------------------------------------

TEST_CASE("Question") {
    const std::u16string asked = u"The approach A which you have given, is this safe approach?";
    const std::u16string told = u"The approach you have given is this safe approach.";
    CHECK(rt::flips_question(asked, told));
    CHECK(rt::is_trustworthy(asked, told));
    CHECK(rt::flips_question(u"is this safe?  ", u"  This is safe."));
    CHECK_FALSE(rt::flips_question(u"is this safe aproach?", u"Is this a safe approach?"));
    CHECK_FALSE(rt::flips_question(u"is this safe", u"Is this safe?"));
    CHECK_FALSE(rt::flips_question(u"this is safe", u"This is safe."));
    CHECK_FALSE(rt::flips_question(u"this is safe!", u"This is safe."));
    CHECK_FALSE(rt::flips_question(u"he asked why? and left", u"He asked why and left."));
}

// --- DroppedContentTests -----------------------------------------------------

TEST_CASE("DroppedContent") {
    const std::u16string typed =
        u"can  also scroll to top of the catalog so that after navigation product can be shown "
        u"directly instead user has to scroll to top to see the product that they click on "
        u"product details 3 options";
    const std::u16string returned =
        u"Can also scroll to the top of the catalog so that after navigation, product details can "
        u"be shown directly instead of the user having to scroll to the top to see the product "
        u"that they click on.";
    CHECK(rt::drops_content(typed, returned));
    CHECK(rt::longest_dropped_run(typed, returned) == 4);
    CHECK(rt::is_trustworthy(typed, returned));
    CHECK_FALSE(rt::drops_content(u"Their is many erors in this sentance.",
                                  u"There are many errors in this sentence."));
    CHECK_FALSE(rt::drops_content(u"we was going to the store and buyed milk, it dont work",
                                  u"We were going to the store and bought milk. It doesn't work."));
    const std::u16string same = u"The quick brown fox jumps over the lazy dog.";
    CHECK_FALSE(rt::drops_content(same, same));
    CHECK(rt::longest_dropped_run(same, same) == 0);
    CHECK_FALSE(rt::drops_content(u"there is a bug, it is not exactly a bug",
                                  u"There is a bug. It is not exactly a bug."));
    CHECK(rt::longest_dropped_run(u"keep one two three four", u"keep three four") == 2);
    CHECK_FALSE(rt::drops_content(u"keep one two three four", u"keep three four"));
    CHECK(rt::drops_content(u"keep one two three four", u"keep four"));
    CHECK(rt::drops_content(u"the report covers March April and May figures", u"the report covers figures"));
    CHECK(rt::longest_dropped_run(u"one two three", u"") == 3);
    CHECK_FALSE(rt::drops_content(u"", u"anything"));
}

// --- NativePromptTests -------------------------------------------------------

TEST_CASE("NativePrompt") {
    const auto native = rewrite_mode::system_prompt(RewriteMode::native);
    CHECK(contains(native, u"verb and preposition it needs"));
    CHECK(contains(native, u"rather than dropping the clause"));
    const auto rule = native.find(u"verb and preposition it needs");
    CHECK(rule < native.find(u"Fix the grammar"));
    CHECK(rule < native.find(u"Keep every fact"));
    CHECK(contains(native, u"Do not introduce a new fact, name or number"));
    for (auto mode : all_rewrite_modes) {
        if (mode == RewriteMode::native) continue;
        CHECK_FALSE(contains(rewrite_mode::system_prompt(mode), u"verb and preposition it needs"));
    }
    CHECK(rewrite_mode::may_restructure(RewriteMode::native));
    CHECK_FALSE(rewrite_mode::may_restructure(RewriteMode::fix_grammar));
}

// --- ModelRankingTests -------------------------------------------------------

TEST_CASE("ModelRanking") {
    using S = std::vector<std::string>;
    CHECK(rank_models({"gemma-3-270m-it-Q8_0.gguf", "Qwen3-0.6B-Q8_0.gguf"}).front() == "Qwen3-0.6B-Q8_0.gguf");
    CHECK(rank_models({"Qwen3-0.6B-Q8_0.gguf", "Qwen3-1.7B-Q4_K_M.gguf"}).front() == "Qwen3-1.7B-Q4_K_M.gguf");
    CHECK(rank_models({"gemma-3-270m-it-Q8_0.gguf", "some-unknown-model.gguf"}).front() == "some-unknown-model.gguf");
    CHECK(rank_models({"gemma-3-270m-it-Q8_0.gguf"}) == S{"gemma-3-270m-it-Q8_0.gguf"});
    CHECK(rank_models({"b-model.gguf", "a-model.gguf"}) == S{"a-model.gguf", "b-model.gguf"});
    CHECK(rank_models({}).empty());
}

// --- LiveModelCostTests and ModelSetupTests ----------------------------------

namespace {

struct TempDir {
    fs::path path;
    TempDir() {
        std::random_device rd;
        path = fs::temp_directory_path() / ("nib-test-" + std::to_string(rd()) + std::to_string(rd()));
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

void write_bytes(const fs::path& p, size_t n, char fill = 'A') {
    std::ofstream(p, std::ios::binary) << std::string(n, fill);
}

}  // namespace

TEST_CASE("LiveModelCost") {
    TempDir dir;
    write_bytes(dir.path / "small.gguf", 4096);
    CHECK(ModelChecker::is_light_enough_for_live_use(dir.path / "small.gguf"));
    CHECK(model_catalog::compact().bytes < ModelChecker::live_model_size_limit);
    CHECK(model_catalog::recommended().bytes > ModelChecker::live_model_size_limit);
}

TEST_CASE("ModelCatalog") {
    TempDir dir;
    write_bytes(dir.path / "My-Model.gguf", 2048);
    const auto model = model_catalog::local(dir.path / "My-Model.gguf");
    CHECK(model.filename == "My-Model.gguf");
    CHECK(model.title == u"My-Model");
    CHECK(model.bytes == 2048);
    CHECK(model_catalog::local(dir.path / "nothing.gguf").bytes == 0);

    std::set<std::string> names;
    int64_t previous = 0;
    for (const auto& m : model_catalog::all()) {
        CHECK(m.filename.size() > 5);
        CHECK(m.filename.substr(m.filename.size() - 5) == ".gguf");
        CHECK(m.url.rfind("https://", 0) == 0);
        CHECK(m.url.substr(m.url.size() - m.filename.size()) == m.filename);
        CHECK(m.bytes >= previous);
        previous = m.bytes;
        names.insert(m.filename);
    }
    CHECK(names.size() == model_catalog::all().size());
    CHECK(model_catalog::recommended().filename == "Qwen3-4B-Instruct-2507-Q4_K_M.gguf");
    CHECK(model_catalog::compact().filename == "Qwen3-0.6B-Q8_0.gguf");

    std::vector<std::string> all;
    for (const auto& m : model_catalog::all()) all.push_back(m.filename);
    all.push_back("gemma-3-270m-it-Q8_0.gguf");
    CHECK(rank_models(all).back() == "gemma-3-270m-it-Q8_0.gguf");

    CHECK(CatalogModel{"a.gguf", u"a", u"", 804'753'632, ""}.size_label() == u"805 MB");
    CHECK(CatalogModel{"b.gguf", u"b", u"", 2'165'039'200, ""}.size_label() == u"2.2 GB");
    CHECK(model_catalog::all()[0].size_label() == u"805 MB");

    const auto install = model_catalog::install_directory().wstring();
    CHECK(install.find(L"nib\\models") != std::wstring::npos);
}

namespace {

ModelInstaller::Stage run(ModelInstaller& installer, const CatalogModel& model) {
    std::mutex m;
    std::condition_variable cv;
    ModelInstaller::Stage last;
    bool settled = false;
    installer.on_change = [&](const ModelInstaller::Stage& s) {
        std::lock_guard lock(m);
        last = s;
        using K = ModelInstaller::Stage::Kind;
        if (s.kind == K::done || s.kind == K::failed || s.kind == K::cancelled) {
            settled = true;
            cv.notify_all();
        }
    };
    installer.start(model);
    std::unique_lock lock(m);
    cv.wait_for(lock, std::chrono::seconds(20), [&] { return settled; });
    return last;
}

CatalogModel local_model(const fs::path& dir, size_t bytes, int64_t declared) {
    const auto source = dir / "source.gguf";
    write_bytes(source, bytes);
    return CatalogModel{"Test-Model.gguf", u"Test", u"", declared, source.string()};
}

}  // namespace

TEST_CASE("ModelInstaller") {
    using K = ModelInstaller::Stage::Kind;
    TempDir src, dest;
    const auto target = dest.path / "models";

    SECTION("installs into the given directory") {
        ModelInstaller installer(target, false);
        const auto stage = run(installer, local_model(src.path, 4096, 4096));
        REQUIRE(stage.kind == K::done);
        CHECK(stage.installed == target / "Test-Model.gguf");
        CHECK(fs::exists(stage.installed));
        // No staging file left behind.
        std::vector<std::string> left;
        for (const auto& e : fs::directory_iterator(target)) left.push_back(e.path().filename().string());
        CHECK(left == std::vector<std::string>{"Test-Model.gguf"});
    }
    SECTION("refuses a truncated download") {
        ModelInstaller installer(target, false);
        const auto stage = run(installer, local_model(src.path, 100, 800'000'000));
        REQUIRE(stage.kind == K::failed);
        CHECK(contains(stage.message, u"stopped early"));
        CHECK_FALSE(fs::exists(target / "Test-Model.gguf"));
        installer.reset();
        CHECK(installer.stage().kind == K::idle);
    }
    SECTION("tolerates a size that drifted slightly") {
        ModelInstaller installer(target, false);
        CHECK(run(installer, local_model(src.path, 1'000'000, 1'100'000)).kind == K::done);
    }
    SECTION("replaces an existing model of the same name") {
        fs::create_directories(target);
        write_bytes(target / "Test-Model.gguf", 10, '\0');
        ModelInstaller installer(target, false);
        run(installer, local_model(src.path, 4096, 4096));
        CHECK(fs::file_size(target / "Test-Model.gguf") == 4096);
    }
    SECTION("a missing source fails") {
        ModelInstaller installer(target, false);
        CHECK(run(installer, CatalogModel{"Test-Model.gguf", u"Test", u"", 4096,
                                          (src.path / "nothing-here.gguf").string()}).kind == K::failed);
    }
    SECTION("disk space") {
        const CatalogModel huge{"huge.gguf", u"Huge", u"", 900'000'000'000, "https://example.com/huge.gguf"};
        const auto problem = ModelInstaller::space_problem(huge, uint64_t{100'000'000'000});
        REQUIRE(problem);
        CHECK(contains(*problem, u"disk space"));
        CHECK_FALSE(ModelInstaller::space_problem(model_catalog::recommended(), uint64_t{100'000'000'000}));
        CHECK_FALSE(ModelInstaller::space_problem(huge, std::nullopt));
    }
    SECTION("idle until started; cancelling nothing changes nothing") {
        ModelInstaller installer(target, true);
        CHECK(installer.stage().kind == K::idle);
        CHECK_FALSE(installer.busy());
        installer.cancel();
        CHECK(installer.stage().kind == K::idle);
    }
}

// --- ModelChecker with a fake model -----------------------------------------

namespace {

class FakeRewriter : public Rewriter {
public:
    std::map<std::u16string, std::u16string> answers;
    int calls = 0;
    std::u16string rewrite(const std::u16string& text, RewriteMode) override {
        ++calls;
        const auto it = answers.find(text);
        if (it == answers.end()) throw RewriteException({RewriteError::Kind::bad_response, {}, 0});
        return it->second;
    }
};

}  // namespace

TEST_CASE("ModelChecker: inline corrections are diffed and cached") {
    FakeRewriter model;
    model.answers[u"Their is many erors"] = u"There are many errors";
    ModelChecker checker(model);
    const auto found = checker.check(u"Their is many erors");
    CHECK(found.size() >= 2);
    for (const auto& s : found) CHECK(s.source == SuggestionSource::model);
    checker.check(u"Their is many erors");
    CHECK(model.calls == 1);
}

TEST_CASE("ModelChecker: an untrustworthy rewrite produces nothing") {
    FakeRewriter model;
    model.answers[u"Fix this"] = u"Certainly! Here is the corrected version of the text you provided to me today.";
    ModelChecker checker(model);
    CHECK(checker.check(u"Fix this").empty());
}

TEST_CASE("ModelChecker: selection outcomes") {
    FakeRewriter model;
    const std::u16string question = u"The approach A which you have given, is this safe approach?";
    model.answers[question] = u"The approach you have given is this safe approach.";
    model.answers[u"keep one two three four"] = u"keep four";
    model.answers[u"fine as it is."] = u"fine as it is.";
    model.answers[u"she dont like it"] = u"She doesn't like it.";
    ModelChecker checker(model);

    auto o = checker.rewrite_selection(question, RewriteMode::native);
    CHECK(o.kind == RewriteOutcome::Kind::refused);
    o = checker.rewrite_selection(u"keep one two three four", RewriteMode::fix_grammar);
    CHECK(o.kind == RewriteOutcome::Kind::refused);
    // Shorter may drop words.
    o = checker.rewrite_selection(u"keep one two three four", RewriteMode::shorter);
    CHECK(o.kind == RewriteOutcome::Kind::rewritten);
    o = checker.rewrite_selection(u"fine as it is.", RewriteMode::fix_grammar);
    CHECK(o.kind == RewriteOutcome::Kind::unchanged);
    o = checker.rewrite_selection(u"she dont like it", RewriteMode::fix_grammar);
    REQUIRE(o.kind == RewriteOutcome::Kind::rewritten);
    CHECK(o.text == u"She doesn't like it.");
    CHECK_THROWS_AS(checker.rewrite_selection(u"unknown", RewriteMode::clearer), RewriteException);
}
