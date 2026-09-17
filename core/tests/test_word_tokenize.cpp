#include <catch2/catch_test_macros.hpp>
#include "golden_loader.hpp"
#include "text/word_tokenize.hpp"

namespace {

nib::u16view view_of(const std::u16string& s) {
    return nib::u16view(reinterpret_cast<const uint16_t*>(s.data()),
                        static_cast<int32_t>(s.size()));
}

}  // namespace

// Every case in the golden was produced by the shipped Swift. A failure here
// means the C++ disagrees with what nib does today -- which is the only
// question this test asks. It does not ask whether the behaviour is good.
TEST_CASE("tokenize matches the Swift goldens") {
    const auto golden = load_golden("word-tokenize.json");
    const auto& cases = golden.at("cases");
    REQUIRE(cases.size() > 0);

    for (const auto& c : cases) {
        const std::u16string input = utf8_to_utf16(c.at("input").get<std::string>());
        const auto tokens = nib::tokenize(view_of(input));

        INFO("input: " << c.at("input").get<std::string>());
        REQUIRE(tokens.size() == c.at("tokens").size());

        for (size_t i = 0; i < tokens.size(); ++i) {
            INFO("token " << i);
            CHECK(tokens[i].range.location == c.at("tokens")[i].at("location").get<int32_t>());
            CHECK(tokens[i].range.length == c.at("tokens")[i].at("length").get<int32_t>());
            CHECK(tokens[i].text
                  == utf8_to_utf16(c.at("tokens")[i].at("text").get<std::string>()));
        }
    }
}

// Stated separately from the goldens because it is the single behaviour most
// likely to be "fixed" by someone reading the tokenizer in isolation. The
// Swift builds a UnicodeScalar from one UTF-16 unit, which is nil for a lone
// surrogate, so an emoji contributes no tokens at all.
TEST_CASE("surrogates are separators, so emoji contribute no tokens") {
    const std::u16string input = utf8_to_utf16("emoji 👨‍👩‍👧‍👦 family");
    const auto tokens = nib::tokenize(view_of(input));

    REQUIRE(tokens.size() == 2);
    CHECK(tokens[0].text == u"emoji");
    CHECK(tokens[1].text == u"family");
}

TEST_CASE("empty input produces no tokens") {
    CHECK(nib::tokenize(nib::u16view()).empty());
    const std::u16string blank = u"   \n  ";
    CHECK(nib::tokenize(view_of(blank)).empty());
}
