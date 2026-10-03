// Port of WordDiffTests.swift and PositionMapperTests.swift.
#include "test_support.hpp"
#include <nlohmann/json.hpp>
#include "lint/edit_planner.hpp"
#include "lint/word_diff.hpp"

using namespace nib;
using V = std::vector<std::u16string>;

namespace {
std::vector<TextEdit> edits(const std::u16string& a, const std::u16string& b) {
    return word_diff::edits(a, b);
}
V texts(const std::vector<Token>& tokens) {
    V out;
    for (const auto& t : tokens) out.push_back(t.text);
    return out;
}
}  // namespace

TEST_CASE("WordDiff: tokenizes words with ranges") {
    const auto tokens = word_diff::tokenize(u"Their is many");
    CHECK(texts(tokens) == V{u"Their", u"is", u"many"});
    CHECK(tokens[0].range == R(0, 5));
    CHECK(tokens[1].range == R(6, 2));
    CHECK(tokens[2].range == R(9, 4));
}

TEST_CASE("WordDiff: punctuation, apostrophes, hyphens, digits") {
    CHECK(texts(word_diff::tokenize(u"Hi, there!")) == V{u"Hi", u"there"});
    CHECK(texts(word_diff::tokenize(u"don't stop")) == V{u"don't", u"stop"});
    CHECK(texts(word_diff::tokenize(u"UTF-16 and snake_case")) == V{u"UTF-16", u"and", u"snake_case"});
    CHECK(texts(word_diff::tokenize(u"RN 86 build")) == V{u"RN", u"86", u"build"});
    CHECK(word_diff::tokenize(u"").empty());
    CHECK(word_diff::tokenize(u"   \n ").empty());
}

TEST_CASE("WordDiff: token ranges survive emoji") {
    const auto tokens = word_diff::tokenize(u"😀 bad");
    REQUIRE(texts(tokens) == V{u"bad"});
    CHECK(tokens[0].range == R(3, 3));
}

TEST_CASE("WordDiff: single-word edits") {
    CHECK(edits(u"There are many", u"There are many").empty());

    auto r = edits(u"Their is many", u"There is many");
    REQUIRE(r.size() == 1);
    CHECK(r[0].range == R(0, 5));
    CHECK(r[0].replacement == u"There");
    CHECK(r[0].expected == u"Their");

    r = edits(u"the cat sat", u"the dog sat");
    REQUIRE(r.size() == 1);
    CHECK(r[0].expected == u"cat");
    CHECK(r[0].replacement == u"dog");

    r = edits(u"the cat sat", u"the cat stood");
    REQUIRE(r.size() == 1);
    CHECK(r[0].expected == u"sat");

    r = edits(u"Their is many erors", u"There is many errors");
    REQUIRE(r.size() == 2);
    CHECK(r[0].expected == u"Their");
    CHECK(r[1].expected == u"erors");
}

TEST_CASE("WordDiff: multi-word edits") {
    auto r = edits(u"it could of worked", u"it could have worked");
    REQUIRE(r.size() == 1);
    CHECK(r[0].expected == u"of");
    CHECK(r[0].replacement == u"have");

    r = edits(u"work t he end", u"work the end");
    REQUIRE(r.size() == 1);
    CHECK(r[0].expected == u"t he");
    CHECK(r[0].replacement == u"the");

    r = edits(u"this kind of bugs", u"this kind of bug reports");
    REQUIRE(r.size() == 1);
    CHECK(r[0].expected == u"bugs");
    CHECK(r[0].replacement == u"bug reports");

    r = edits(u"this is very very long", u"this is very long");
    REQUIRE(r.size() == 1);
    CHECK(r[0].replacement == u"");

    // Nothing to anchor an underline to.
    CHECK(edits(u"cat sat", u"the cat sat").empty());
}

TEST_CASE("WordDiff: ranges stay usable") {
    const std::u16string original = u"Their is many erors here";
    const auto r = edits(original, u"There is many errors here");
    REQUIRE(r.size() == 2);
    for (const auto& e : r) CHECK(edit_planner::is_valid(e, original));

    std::u16string text = original;
    for (auto it = r.rbegin(); it != r.rend(); ++it) {
        text = edit_planner::apply(*it, text).value_or(text);
    }
    CHECK(text == u"There is many errors here");

    const std::u16string emoji = u"😀 Their is here";
    const auto e = edits(emoji, u"😀 There is here");
    REQUIRE(e.size() == 1);
    CHECK(e[0].range == R(3, 5));
    CHECK(edit_planner::is_valid(e[0], emoji));
}

TEST_CASE("WordDiff: technical text must survive") {
    const std::u16string original = u"UTF-16 traps with NSString.length here";
    CHECK(edits(original, original).empty());
    const auto r = edits(u"UTF-16 traps and NSString erors", u"UTF-16 traps and NSString errors");
    REQUIRE(r.size() == 1);
    CHECK(r[0].expected == u"erors");
}

TEST_CASE("WordDiff: suggestions") {
    const auto s = word_diff::suggestions(u"Their is", u"There is");
    REQUIRE(s.size() == 1);
    CHECK(s[0].replacements == V{u"There"});
    CHECK(s[0].range == R(0, 5));
    CHECK(word_diff::suggestions(u"fine text", u"fine text").empty());
}

TEST_CASE("WordDiff: LCS and edge cases") {
    CHECK(word_diff::longest_common_subsequence({u"a", u"b", u"c"}, {u"a", u"c"}) == V{u"a", u"c"});
    CHECK(word_diff::longest_common_subsequence({u"a"}, {u"b"}).empty());
    CHECK(word_diff::longest_common_subsequence({}, {u"a"}).empty());

    auto r = edits(u"the the the cat", u"the the the dog");
    REQUIRE(r.size() == 1);
    CHECK(r[0].expected == u"cat");

    r = edits(u"aaa bbb", u"xxx yyy");
    REQUIRE(r.size() == 1);
    CHECK(r[0].replacement == u"xxx yyy");

    r = edits(u"the cat", u"The cat");
    REQUIRE(r.size() == 1);
    CHECK(r[0].replacement == u"The");
}

// --- PositionMapperTests -----------------------------------------------------

namespace {
nlohmann::json lsp(int sl, int sc, int el, int ec) {
    return {{"start", {{"line", sl}, {"character", sc}}}, {"end", {{"line", el}, {"character", ec}}}};
}
}  // namespace

TEST_CASE("PositionMapper: lines and ranges") {
    CHECK(PositionMapper(u"Their is many").range(lsp(0, 0, 0, 5)) == R(0, 5));
    CHECK(PositionMapper(u"abc\ndef").range(lsp(1, 0, 1, 3)) == R(4, 3));
    CHECK(PositionMapper(u"a\nbb\nccc").range(lsp(2, 0, 2, 3)) == R(5, 3));
    CHECK(PositionMapper(u"abc\ndef").range(lsp(0, 1, 1, 2)) == R(1, 5));
    CHECK(PositionMapper(u"abc").range(lsp(0, 1, 0, 1)) == R(1, 0));
    CHECK(PositionMapper(u"😀 bad").range(lsp(0, 3, 0, 6)) == R(3, 3));
    CHECK(PositionMapper(u"😀\nbad").range(lsp(1, 0, 1, 3)) == R(3, 3));
}

TEST_CASE("PositionMapper: clamping") {
    const auto r = PositionMapper(u"ab\ncdef").range(lsp(0, 99, 0, 99));
    REQUIRE(r);
    CHECK(r->location == 2);
    CHECK(r->length == 0);
    CHECK(PositionMapper(u"abc").offset(99, 0) == 3);
    CHECK(PositionMapper(u"abc").offset(-1, 0) == 0);
    CHECK(PositionMapper(u"ab\ncd").offset(1, -5) == 3);
    CHECK_FALSE(PositionMapper(u"abcdef").range(lsp(0, 4, 0, 2)));
    CHECK_FALSE(PositionMapper(u"abc").range(nlohmann::json{{"start", {{"line", 0}}}}));
    CHECK_FALSE(PositionMapper(u"abc").range(nlohmann::json::object()));
    CHECK(PositionMapper(u"").range(lsp(0, 0, 0, 0)) == R(0, 0));
    CHECK(PositionMapper(u"abc\n").offset(1, 0) == 4);
    CHECK(PositionMapper(u"ab\r\ncd").offset(1, 0) == 4);
}
