// The engines themselves, against the real binaries. Skipped when they have
// not been fetched (Scripts/windows/fetch-engines.ps1), so a checkout without
// them still runs the rest of the suite.
#include "test_support.hpp"
#include <catch2/catch_test_macros.hpp>
#include <chrono>
#include "lint/harper_engine.hpp"
#include "rewrite/model_catalog.hpp"
#include "rewrite/model_checker.hpp"

using namespace nib;

TEST_CASE("harper-ls lints, fills replacements, and filters", "[engine]") {
    const auto harper = locate_harper();
    if (!harper) SKIP("harper-ls not fetched");

    HarperEngine engine(harper->u16string());
    const std::u16string text = u"Their is many erors in this sentance, and NSString is fine.";
    const auto found = engine.lint(text);
    REQUIRE_FALSE(found.empty());

    bool saw_erors = false;
    for (const auto& s : found) {
        const auto word = s.excerpt(text).value_or(u"");
        CHECK(word != u"NSString");  // the filter's whole reason to exist
        if (word == u"erors") saw_erors = true;
    }
    CHECK(saw_erors);

    const auto filled = engine.with_replacements(found, text);
    bool fixed = false;
    for (const auto& s : filled) {
        if (s.excerpt(text) == std::optional<std::u16string>(u"erors")) {
            fixed = std::find(s.replacements.begin(), s.replacements.end(), u"errors") != s.replacements.end();
        }
    }
    CHECK(fixed);

    // A second lint answers for the new text, not the old -- the stale
    // publishDiagnostics bug.
    const auto clean = engine.lint(u"This sentence is fine.");
    CHECK(clean.empty());

    // Warm lints are fast; the macOS figure is ~30ms.
    const auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < 5; ++i) engine.lint(text);
    const auto each = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - start).count() / 5;
    INFO("warm lint " << each << "ms");
    CHECK(each < 500);
}

TEST_CASE("harper-ls restarts after being stopped", "[engine]") {
    const auto harper = locate_harper();
    if (!harper) SKIP("harper-ls not fetched");
    HarperEngine engine(harper->u16string());
    CHECK_FALSE(engine.lint(u"Their is a eror.").empty());
    engine.stop();
    CHECK_FALSE(engine.running());
    CHECK_FALSE(engine.lint(u"Their is a eror.").empty());
}

TEST_CASE("llama-server rewrites with an installed model", "[engine][model]") {
    const auto config = rewrite_config();
    if (!config) SKIP("no llama-server or no model installed");

    RewriteEngine engine(*config);
    const auto answer = engine.rewrite(u"she dont like it", RewriteMode::fix_grammar);
    INFO(utf16_to_utf8(answer));
    CHECK_FALSE(trimmed(answer).empty());
    CHECK(engine.loaded());

    ModelChecker checker(engine);
    const auto outcome = checker.rewrite_selection(u"Their is many erors in this sentance.",
                                                   RewriteMode::fix_grammar);
    CHECK(outcome.kind != RewriteOutcome::Kind::refused);
    engine.shutdown();
    CHECK_FALSE(engine.loaded());
}
