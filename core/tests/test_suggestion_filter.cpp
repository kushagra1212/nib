// Port of SuggestionFilterTests, BadFixTests, BadFixRankingTests,
// BadContextTests and WritingScoreTests.
#include "test_support.hpp"
#include <algorithm>
#include <catch2/catch_approx.hpp>
#include "lint/suggestion_filter.hpp"
#include "lint/writing_score.hpp"

using namespace nib;
namespace sf = nib::suggestion_filter;
using V = std::vector<std::u16string>;

namespace {
nib_range find(const std::u16string& text, const std::u16string& token) {
    const auto at = text.find(token);
    return at == std::u16string::npos ? R(-1, 0)
                                      : R(static_cast<int32_t>(at), static_cast<int32_t>(token.size()));
}
Suggestion make(const std::u16string& text, const std::u16string& token,
                const std::u16string& message, V replacements) {
    Suggestion s;
    s.range = find(text, token);
    s.message = message;
    s.replacements = std::move(replacements);
    return s;
}
Suggestion spelling(const std::u16string& text, const std::u16string& token,
                    const std::u16string& replacement) {
    return make(text, token, u"Did you mean to spell `" + token + u"` this way?", {replacement});
}
bool kept(const std::u16string& text, const std::u16string& token, const std::u16string& replacement) {
    return sf::keep(spelling(text, token, replacement), text);
}
bool plausible(const std::u16string& a, const std::u16string& b) {
    return sf::is_plausible_correction(a, b);
}
}  // namespace

TEST_CASE("SuggestionFilter: harper's damage is refused") {
    CHECK_FALSE(kept(u"UTF-16 traps are covered", u"UTF", u"Uhf"));
    CHECK_FALSE(kept(u"NSString length vs Swift", u"NSString", u"Nesting"));
    CHECK_FALSE(kept(u"how the chat gpt corrects", u"gpt", u"get"));
    const std::u16string text = u"this kind of bugs and how";
    CHECK_FALSE(sf::keep(make(text, u"bugs", u"Consider a more precise word.", {u"thing"}), text));
    CHECK_FALSE(kept(u"looking for bugs (RN 86)", u"RN", u"RUN"));
    CHECK_FALSE(kept(u"ZWJ family sequences", u"ZWJ", u"ZW"));
}

TEST_CASE("SuggestionFilter: unknown word keeps its mark when every fix is rejected") {
    const std::u16string text = u"the undlesing of it";
    const auto refined = sf::refine(spelling(text, u"undlesing", u"understanding"), text);
    REQUIRE(refined);
    CHECK(refined->replacements.empty());
}

TEST_CASE("SuggestionFilter: a good second choice survives a bad first") {
    const std::u16string text = u"click on optioaa now";
    const auto refined = sf::refine(make(text, u"optioaa", u"Did you mean to spell `optioaa` this way?",
                                         {u"operational", u"optical", u"optimal"}), text);
    REQUIRE(refined);
    CHECK(refined->replacements == V{u"optical", u"optimal"});
}

TEST_CASE("SuggestionFilter: real mistakes are kept") {
    CHECK(kept(u"Their is many errors", u"Their", u"There"));
    CHECK(kept(u"many erors here", u"erors", u"errors"));
    CHECK(kept(u"this sentance is wrong", u"sentance", u"sentence"));
    CHECK(kept(u"a erors here", u"a", u"an"));
    CHECK(kept(u"could of been shorter", u"could of", u"could have"));
    CHECK(kept(u"Recieve the parcel", u"Recieve", u"Receive"));
}

TEST_CASE("SuggestionFilter: looksLikeCode") {
    const char16_t* code[] = {u"UTF16", u"h264", u"rn86", u"snake_case", u"NSString.length", u"a/b",
                              u"NSString", u"didApply", u"iOS", u"TextEdit", u"API", u"AX", u"", u"   ",
                              u"gpt", u"npm", u"ssh", u"jwt"};
    for (auto t : code) {
        INFO(utf16_to_utf8(t));
        CHECK(sf::looks_like_code(t));
    }
    const char16_t* words[] = {u"I", u"their", u"Their", u"sentance", u"a", u"myth", u"try"};
    for (auto t : words) {
        INFO(utf16_to_utf8(t));
        CHECK_FALSE(sf::looks_like_code(t));
    }
}

TEST_CASE("SuggestionFilter: surrounding code") {
    CHECK_FALSE(kept(u"NSString.length vs Swift", u"length", u"lengths"));
    CHECK_FALSE(kept(u"teh.property here", u"teh", u"the"));
    CHECK_FALSE(kept(u"the `erors` constant", u"erors", u"errors"));
    CHECK(kept(u"`code` and erors here", u"erors", u"errors"));
    CHECK_FALSE(kept(u"Done.teh cat", u"teh", u"the"));
}

TEST_CASE("SuggestionFilter: plausibility") {
    CHECK(plausible(u"erors", u"errors"));
    CHECK(plausible(u"their", u"there"));
    CHECK(plausible(u"a", u"an"));
    CHECK_FALSE(plausible(u"bugs", u"thing"));
    CHECK_FALSE(plausible(u"cat", u"house"));
    CHECK(plausible(u"gpt", u"get"));
    CHECK_FALSE(plausible(u"word", u"word"));
    CHECK(plausible(u"Word", u"word"));
    CHECK(plausible(u"chatgpt", u"ChatGPT"));
}

TEST_CASE("SuggestionFilter: edit distance") {
    CHECK(sf::edit_distance(u"", u"") == 0);
    CHECK(sf::edit_distance(u"abc", u"") == 3);
    CHECK(sf::edit_distance(u"", u"abc") == 3);
    CHECK(sf::edit_distance(u"kitten", u"sitting") == 3);
    CHECK(sf::edit_distance(u"erors", u"errors") == 1);
    CHECK(sf::edit_distance(u"their", u"there") == 2);
}

TEST_CASE("SuggestionFilter: advisory lints, apply, bounds") {
    const std::u16string a = u"This sentence is long.";
    CHECK(sf::keep(make(a, u"sentence", u"Consider rewording.", {}), a));
    const std::u16string b = u"The NSString is long.";
    CHECK_FALSE(sf::keep(make(b, u"NSString", u"Consider rewording.", {}), b));

    const std::u16string text = u"Their erors and UTF-16";
    const auto kept_all = sf::apply({spelling(text, u"UTF", u"Uhf"), spelling(text, u"Their", u"There"),
                                     spelling(text, u"erors", u"errors")}, text);
    REQUIRE(kept_all.size() == 2);
    V excerpts;
    for (const auto& s : kept_all) excerpts.push_back(*s.excerpt(text));
    std::sort(excerpts.begin(), excerpts.end());
    CHECK(excerpts == V{u"Their", u"erors"});

    const std::u16string g = u"I think Their is a problem";
    CHECK(sf::keep(make(g, u"Their", u"Use `There` to refer to a place.", {u"There"}), g));

    Suggestion bogus;
    bogus.range = R(500, 3);
    bogus.message = u"m";
    bogus.replacements = {u"x"};
    CHECK_FALSE(sf::keep(bogus, u"short"));
}

// --- BadFixTests -------------------------------------------------------------

TEST_CASE("BadFix: possessives and contractions") {
    CHECK_FALSE(plausible(u"Frontmost", u"Front's"));
    CHECK_FALSE(plausible(u"cannot", u"can't"));
    CHECK(plausible(u"wells", u"well's"));
    CHECK(plausible(u"its", u"it's"));
    CHECK(plausible(u"dont", u"don't"));
    CHECK(plausible(u"wont", u"won't"));
    CHECK(plausible(u"theyre", u"they're"));
    (void)plausible(u"it's", u"its'");  // must not crash
    CHECK(sf::invents_possessive(u"frontmost", u"front's"));
    CHECK_FALSE(sf::invents_possessive(u"its", u"it's"));
    CHECK_FALSE(sf::invents_possessive(u"cat", u"hat"));
}

TEST_CASE("BadFix: expansions and joins") {
    CHECK_FALSE(plausible(u"both needing", u"both pieces of needing"));
    CHECK_FALSE(plausible(u"data", u"pieces of data information"));
    CHECK(plausible(u"cannotbe", u"cannot be"));
    CHECK(plausible(u"t he", u"the"));
    CHECK(plausible(u"along side", u"alongside"));
    CHECK(plausible(u"could of", u"could have"));
    CHECK(plausible(u"would of", u"would have"));
    CHECK(sf::adds_words(u"both needing", u"both pieces of needing"));
    CHECK_FALSE(sf::adds_words(u"could of", u"could have"));
    CHECK_FALSE(sf::adds_words(u"teh", u"the"));
    CHECK_FALSE(sf::adds_words(u"cannotbe", u"cannot be"));
    CHECK(plausible(u"erors", u"errors"));
    CHECK(plausible(u"sentance", u"sentence"));
    CHECK(plausible(u"recieve", u"receive"));
    CHECK(plausible(u"their", u"there"));
    CHECK(plausible(u"a", u"an"));
}

TEST_CASE("BadFix: filtering whole suggestions") {
    const std::u16string text = u"Diagnose Frontmost App and both needing you";
    CHECK(sf::apply({make(text, u"Frontmost", u"spelling", {u"Front's"}),
                     make(text, u"both needing", u"mass noun", {u"both pieces of needing"})}, text)
              .empty());
    const std::u16string good = u"many erors here";
    CHECK(sf::apply({make(good, u"erors", u"spelling", {u"errors"})}, good).size() == 1);
}

// --- BadFixRankingTests ------------------------------------------------------

TEST_CASE("BadFixRanking") {
    CHECK(plausible(u"chatgpt", u"ChatGPT"));
    CHECK(plausible(u"i", u"I"));
    CHECK(plausible(u"iphone", u"iPhone"));
    CHECK_FALSE(plausible(u"ChatGPT", u"ChatGPT"));

    const std::u16string text = u"I found the chatgpt issue";
    const auto refined = sf::refine(make(text, u"chatgpt", u"The canonical dictionary spelling is `ChatGPT`.",
                                         {u"ChatGPT", u"catgut"}), text);
    REQUIRE(refined);
    REQUIRE_FALSE(refined->replacements.empty());
    CHECK(refined->replacements.front() == u"ChatGPT");

    CHECK(sf::rank({u"wheat her", u"weather", u"whether"}, u"wheather") == V{u"weather", u"whether", u"wheat her"});
    CHECK(sf::rank({u"cannot be"}, u"cannotbe") == V{u"cannot be"});
    CHECK(sf::rank({u"optical", u"optimal"}, u"optioaa") == V{u"optical", u"optimal"});
    CHECK(sf::rank({u"alongside", u"along sides"}, u"along side") == V{u"along sides", u"alongside"});
}

// --- BadContextTests ---------------------------------------------------------

TEST_CASE("BadContext: names and sentence starts") {
    const std::u16string label = u"label: Message to Kushagra Rathore eligible: yes";
    CHECK_FALSE(sf::keep(make(label, u"Kushagra", u"spelling", {u"Bukhara"}), label));
    CHECK_FALSE(sf::keep(make(label, u"Rathore", u"spelling", {u"Rather"}), label));

    const std::u16string a = u"Recieve the parcel tomorrow.";
    CHECK(sf::keep(make(a, u"Recieve", u"spelling", {u"Receive"}), a));
    const std::u16string b = u"sounds good\nRecieve it tomorrow";
    CHECK(sf::keep(make(b, u"Recieve", u"spelling", {u"Receive"}), b));
    const std::u16string c = u"Thanks. Seperate them please.";
    CHECK(sf::keep(make(c, u"Seperate", u"spelling", {u"Separate"}), c));
    const std::u16string d = u"please seperate them";
    CHECK(sf::keep(make(d, u"seperate", u"spelling", {u"separate"}), d));
}

TEST_CASE("BadContext: repeated words") {
    const std::u16string a = u"lint returned: 1 rects resolved: 0 rects visible: 0";
    CHECK_FALSE(sf::keep(make(a, u"rects", u"spelling", {u"rests"}), a));
    const std::u16string b = u"the sentance is wrong";
    CHECK(sf::keep(make(b, u"sentance", u"spelling", {u"sentence"}), b));
    const std::u16string c = u"recieve teh parcel and teh invoice";
    CHECK(sf::keep(make(c, u"teh", u"spelling", {u"the"}), c));
    CHECK(sf::occurrences(u"rect", u"rects rects") == 0);
    CHECK(sf::occurrences(u"rects", u"rects rects") == 2);
    CHECK(sf::occurrences(u"rects", u"Rects rects") == 2);
}

TEST_CASE("BadContext: transpositions and distance") {
    CHECK(plausible(u"teh", u"the"));
    CHECK(plausible(u"adn", u"and"));
    CHECK(plausible(u"recieve", u"receive"));
    CHECK(plausible(u"freind", u"friend"));
    CHECK_FALSE(sf::is_transposition(u"abc", u"cba"));
    CHECK_FALSE(sf::is_transposition(u"rects", u"rests"));
    CHECK(sf::is_transposition(u"form", u"from"));
    CHECK(sf::is_transposition(u"fro", u"for"));
    CHECK_FALSE(sf::is_transposition(u"the", u"there"));
    CHECK_FALSE(sf::is_transposition(u"the", u"the"));
    CHECK_FALSE(plausible(u"subrole", u"sublime"));
    CHECK_FALSE(plausible(u"Kushagra", u"Bukhara"));
    CHECK(plausible(u"sentance", u"sentence"));
    CHECK(plausible(u"erors", u"errors"));
    CHECK(plausible(u"definately", u"definitely"));
    CHECK(plausible(u"occured", u"occurred"));
    CHECK(plausible(u"seperate", u"separate"));
    CHECK(plausible(u"accomodate", u"accommodate"));
    CHECK(plausible(u"a", u"an"));
    CHECK(plausible(u"i", u"in"));
}

TEST_CASE("BadContext: code and advisory notes") {
    const std::u16string a = u"the AXTextArea element";
    CHECK_FALSE(sf::keep(make(a, u"AXTextArea", u"spelling", {u"Attracted"}), a));
    const std::u16string b = u"label: Message to Kushagra Rathore";
    CHECK(sf::keep(make(b, u"Kushagra", u"Consider rephrasing", {}), b));
}

// --- WritingScoreTests -------------------------------------------------------

TEST_CASE("WritingScore") {
    const WritingScore clean(0, 40);
    CHECK(clean.summary() == u"no mistakes in 40 words");
    CHECK(clean.standing() == WritingScore::Standing::clean);

    CHECK(WritingScore(5, 100).rate() == Catch::Approx(5));
    CHECK(WritingScore(5, 50).rate() == Catch::Approx(10));
    CHECK(WritingScore(3, 200).rate() == Catch::Approx(1.5));

    const WritingScore shorter(3, 30), longer(3, 300);
    CHECK(shorter.rate() > longer.rate());
    CHECK(shorter.standing() == WritingScore::Standing::many);
    CHECK(longer.standing() == WritingScore::Standing::few);

    CHECK(WritingScore(1, 6).summary() == u"1 mistake");
    const auto two = WritingScore(2, 40).summary();
    CHECK(contains(two, u"2 mistakes"));
    CHECK(contains(two, u"per 100 words"));
    CHECK(starts_with(WritingScore(1, 50).summary(), u"1 mistake ·"));
    CHECK(starts_with(WritingScore(2, 50).summary(), u"2 mistakes"));

    CHECK(WritingScore(0, 0).summary().empty());
    CHECK(WritingScore(0, 0).compact().empty());
    CHECK(WritingScore(0, 0).rate() == 0);

    CHECK(WritingScore::word_count(u"the quick brown fox") == 4);
    CHECK(WritingScore::word_count(u"  spaced   out  ") == 2);
    CHECK(WritingScore::word_count(u"line one\nline two") == 4);
    CHECK(WritingScore::word_count(u"") == 0);

    std::vector<Suggestion> found(2);
    const WritingScore built(found, u"the quick brown fox");
    CHECK(built.issues == 2);
    CHECK(built.words == 4);

    CHECK(WritingScore(-3, -9).issues == 0);
    CHECK(WritingScore(-3, -9).words == 0);
}
