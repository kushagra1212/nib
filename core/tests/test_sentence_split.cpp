#include <catch2/catch_test_macros.hpp>
#include <string>
#include "golden_loader.hpp"
#include "text/sentence_split.hpp"

namespace {

nib::u16view view_of(const std::u16string& s) {
    return nib::u16view(reinterpret_cast<const uint16_t*>(s.data()),
                        static_cast<int32_t>(s.size()));
}

}  // namespace

// The locale comes out of the golden rather than from the environment. The
// recording was made on a machine set to en_IN; a CI container defaults to
// something else, and ICU would then segment differently and fail this test
// for a reason that has nothing to do with the port.
TEST_CASE("sentence splitting matches the Swift goldens") {
    const auto golden = load_golden("sentence-split.json");
    const std::string locale = golden.at("locale").get<std::string>();
    const auto& cases = golden.at("cases");
    REQUIRE(cases.size() > 0);

    INFO("golden locale: " << locale);

    for (const auto& c : cases) {
        const std::u16string input = utf8_to_utf16(c.at("input").get<std::string>());
        const int32_t minimum = c.at("minimumWords").get<int32_t>();

        const auto found = nib::sentences(view_of(input), minimum, locale.c_str());

        INFO("input: " << c.at("input").get<std::string>()
             << "  minimumWords: " << minimum);
        REQUIRE(found.size() == c.at("sentences").size());

        for (size_t i = 0; i < found.size(); ++i) {
            INFO("sentence " << i);
            CHECK(found[i].range.location
                  == c.at("sentences")[i].at("location").get<int32_t>());
            CHECK(found[i].range.length
                  == c.at("sentences")[i].at("length").get<int32_t>());
            CHECK(found[i].text
                  == utf8_to_utf16(c.at("sentences")[i].at("text").get<std::string>()));
        }
    }
}

// Called out separately because splitting on "." alone breaks all three, and
// the text nib checks is often technical.
TEST_CASE("abbreviations, decimals and dotted identifiers do not split") {
    const std::string locale = load_golden("sentence-split.json")
                                   .at("locale").get<std::string>();

    const std::u16string abbreviation =
        utf8_to_utf16("We tested e.g. the login flow and it worked well.");
    CHECK(nib::sentences(view_of(abbreviation), 5, locale.c_str()).size() == 1);

    const std::u16string decimal =
        utf8_to_utf16("The build takes 3.5 minutes on this machine now.");
    CHECK(nib::sentences(view_of(decimal), 5, locale.c_str()).size() == 1);

    const std::u16string identifier =
        utf8_to_utf16("We should check NSString.length before we index into it.");
    CHECK(nib::sentences(view_of(identifier), 5, locale.c_str()).size() == 1);
}

// A clarity mark spans a whole sentence, so a range carrying the blank space
// after it underlines past the full stop.
TEST_CASE("ranges exclude surrounding whitespace and map back to the source") {
    const std::string locale = load_golden("sentence-split.json")
                                   .at("locale").get<std::string>();
    const std::u16string text = utf8_to_utf16(
        "The quick brown fox jumps here.    Second long sentence goes here.");

    const auto found = nib::sentences(view_of(text), 5, locale.c_str());
    REQUIRE(found.size() == 2);

    for (const auto& s : found) {
        CHECK(s.text == text.substr(static_cast<size_t>(s.range.location),
                                    static_cast<size_t>(s.range.length)));
        REQUIRE(s.range.length > 0);
        CHECK(s.text.front() != u' ');
        CHECK(s.text.back() != u' ');
    }
}

// The exception list is inconsistent because CLDR's is, and the inconsistency
// is load-bearing: tidying it would move nib's behaviour away from what macOS
// ships. These pairs are the ones most likely to look like typos.
TEST_CASE("abbreviation suppressions match Foundation, gaps included") {
    auto count = [](const char* abbrev) {
        const std::u16string text = utf8_to_utf16(
            std::string("We saw ") + abbrev
            + " Smith arrive here today and then leave again.");
        return nib::sentences(view_of(text), 3, "en_IN").size();
    };

    SECTION("suppressed") {
        CHECK(count("Dr.") == 1);
        CHECK(count("Mar.") == 1);
        CHECK(count("a.m.") == 1);
        CHECK(count("e.g.") == 1);
        CHECK(count("Ph.D.") == 1);
    }

    // Not oversights. Foundation splits after each of these, so the core must
    // too, or a clarity mark covers a different span on the two platforms.
    SECTION("deliberately absent") {
        CHECK(count("Apr.") == 2);
        CHECK(count("p.m.") == 2);
        CHECK(count("etc.") == 2);
        CHECK(count("Inc.") == 2);
        CHECK(count("Jr.") == 2);
    }
}

TEST_CASE("empty and whitespace-only input produce no sentences") {
    CHECK(nib::sentences(nib::u16view(), 5, "en_IN").empty());
    const std::u16string blank = u"    \n  ";
    CHECK(nib::sentences(view_of(blank), 5, "en_IN").empty());
}
