// Port of EditPlannerTests.swift: the edit path end to end, including the two
// bugs that shipped -- applying a stale edit after the text moved, and
// mis-shifting the remaining suggestions afterwards.
#include "test_support.hpp"
#include "lint/edit_planner.hpp"

using namespace nib;
namespace ep = nib::edit_planner;

namespace {
TextEdit edit(int32_t location, int32_t length, std::u16string replacement,
              std::u16string expected = {}) {
    return TextEdit{R(location, length), std::move(replacement), std::move(expected)};
}
Suggestion suggestion(int32_t location, int32_t length, std::u16string message = u"m") {
    Suggestion s;
    s.range = R(location, length);
    s.message = std::move(message);
    return s;
}
std::u16string applied(const TextEdit& e, const std::u16string& text) {
    return ep::apply(e, text).value_or(u"<nil>");
}
}  // namespace

TEST_CASE("EditPlanner: apply") {
    CHECK(applied(edit(6, 2, u"was"), u"Their is many") == u"Their was many");
    CHECK(applied(edit(0, 5, u"There"), u"Their is many") == u"There is many");
    CHECK(applied(edit(9, 4, u"much"), u"Their is many") == u"Their is much");
    CHECK(applied(edit(0, 1, u"aaa"), u"abc") == u"aaabc");
    CHECK(applied(edit(0, 3, u"x"), u"abc") == u"x");
    CHECK(applied(edit(3, 4, u""), u"one two three") == u"one three");
    CHECK(applied(edit(0, 4, u""), u"abcdefg") == u"efg");
    CHECK(applied(edit(3, 0, u"-"), u"abcdef") == u"abc-def");
    CHECK(applied(edit(3, 0, u"!"), u"abc") == u"abc!");
    CHECK(applied(edit(0, 3, u"xyz"), u"abc") == u"xyz");
    CHECK(applied(edit(0, 0, u"hi"), u"") == u"hi");
}

TEST_CASE("EditPlanner: bounds") {
    CHECK_FALSE(ep::apply(edit(10, 5, u"x"), u"short"));
    CHECK_FALSE(ep::apply(edit(3, 10, u"x"), u"short"));
    CHECK_FALSE(ep::apply(edit(-1, 2, u"x"), u"abc"));
    CHECK_FALSE(ep::apply(edit(1, -2, u"x"), u"abc"));
    CHECK(ep::is_in_bounds(R(3, 0), u"abc"));
    CHECK(ep::is_in_bounds(R(0, 3), u"abc"));
}

TEST_CASE("EditPlanner: UTF-16 offsets") {
    CHECK(applied(edit(3, 3, u"good"), u"😀 bad") == u"😀 good");
    CHECK(applied(edit(1, 2, u"X"), u"a😀b") == u"aXb");
    CHECK(applied(edit(6, 4, u"hour"), u"café time") == u"café hour");
    const std::u16string family = u"👨‍👩‍👧";
    const auto len = static_cast<int32_t>(family.size());
    CHECK(applied(edit(len + 1, 4, u"there"), family + u" here") == family + u" there");
}

TEST_CASE("EditPlanner: isValid") {
    CHECK(ep::is_valid(edit(0, 5, u"There", u"Their"), u"Their is"));
    CHECK_FALSE(ep::is_valid(edit(0, 5, u"There", u"Their"), u"Oh Their is"));
    CHECK_FALSE(ep::is_valid(edit(50, 5, u"There", u"Their"), u"Their is"));
    CHECK(ep::is_valid(edit(0, 5, u"There"), u"Their is"));
}

TEST_CASE("EditPlanner: relocate") {
    auto moved = ep::relocate(edit(0, 5, u"There", u"Their"), u"Oh Their is");
    REQUIRE(moved);
    CHECK(moved->range == R(3, 5));
    CHECK(moved->replacement == u"There");

    moved = ep::relocate(edit(10, 5, u"There", u"Their"), u"Their is here");
    REQUIRE(moved);
    CHECK(moved->range == R(0, 5));

    const auto good = edit(0, 5, u"There", u"Their");
    CHECK(ep::relocate(good, u"Their is") == good);

    moved = ep::relocate(TextEdit{R(12, 3), u"THE", u"the"}, u"the cat and the dog and the bird");
    REQUIRE(moved);
    CHECK(moved->range.location == 12);

    CHECK_FALSE(ep::relocate(edit(0, 5, u"There", u"Their"), u"completely different"));
    CHECK_FALSE(ep::relocate(edit(0, 5, u"There", u"Their"), std::u16string(500, u'x') + u"Their"));
    CHECK_FALSE(ep::relocate(edit(99, 5, u"x"), u"short"));
}

TEST_CASE("EditPlanner: reanchor") {
    auto first_range = [](const std::vector<Suggestion>& v) { return v.empty() ? R(-1, -1) : v[0].range; };
    CHECK(first_range(ep::reanchor({suggestion(20, 6)}, edit(13, 4, u"the"))) == R(19, 6));
    CHECK(first_range(ep::reanchor({suggestion(20, 6)}, edit(13, 3, u"these"))) == R(22, 6));
    CHECK(first_range(ep::reanchor({suggestion(0, 5)}, edit(13, 4, u"the"))) == R(0, 5));
    CHECK(first_range(ep::reanchor({suggestion(8, 5)}, edit(13, 4, u"the"))) == R(8, 5));
    CHECK(first_range(ep::reanchor({suggestion(17, 3)}, edit(13, 4, u"the"))) == R(16, 3));
    CHECK(ep::reanchor({suggestion(15, 5)}, edit(13, 4, u"the")).empty());
    CHECK(ep::reanchor({suggestion(10, 20)}, edit(13, 4, u"the")).empty());
    CHECK(ep::reanchor({suggestion(13, 4)}, edit(13, 4, u"the")).empty());
    CHECK(ep::reanchor({suggestion(13, 9)}, edit(13, 4, u"the")).empty());
    CHECK(ep::reanchor({suggestion(15, 0)}, edit(13, 4, u"the")).empty());

    const auto same = ep::reanchor({suggestion(0, 3), suggestion(13, 4), suggestion(20, 6)},
                                   edit(13, 4, u"thee"));
    REQUIRE(same.size() == 2);
    CHECK(same[0].range == R(0, 3));
    CHECK(same[1].range == R(20, 6));

    CHECK(first_range(ep::reanchor({suggestion(11, 2)}, edit(0, 10, u""))) == R(1, 2));
    CHECK(first_range(ep::reanchor({suggestion(5, 2)}, TextEdit{R(0, 5), u"", u""})) == R(0, 2));

    const auto original = suggestion(20, 6, u"keep me");
    const auto kept = ep::reanchor({original}, edit(0, 2, u"x"));
    REQUIRE(kept.size() == 1);
    CHECK(kept[0].id == original.id);
    CHECK(kept[0].message == u"keep me");

    const auto ordered = ep::reanchor({suggestion(0, 2), suggestion(20, 2), suggestion(30, 2)},
                                      edit(10, 4, u"x"));
    REQUIRE(ordered.size() == 3);
    CHECK(ordered[0].range.location == 0);
    CHECK(ordered[1].range.location == 17);
    CHECK(ordered[2].range.location == 27);
    CHECK(ep::reanchor({}, edit(0, 1, u"x")).empty());
}

TEST_CASE("EditPlanner: prune and sequences") {
    const auto kept = ep::prune_out_of_bounds({suggestion(0, 3), suggestion(90, 5)}, u"short text");
    REQUIRE(kept.size() == 1);
    CHECK(kept[0].range.location == 0);

    std::u16string text = u"Their is many erors here";
    auto pending = std::vector<Suggestion>{suggestion(0, 5, u"Their"), suggestion(14, 5, u"erors")};
    const TextEdit first{pending[0].range, u"There", u"Their"};
    text = *ep::apply(first, text);
    pending = ep::reanchor(pending, first);
    CHECK(text == u"There is many erors here");
    REQUIRE(pending.size() == 1);
    const TextEdit second{pending[0].range, u"errors", u"erors"};
    CHECK(ep::is_valid(second, text));
    CHECK(*ep::apply(second, text) == u"There is many errors here");

    std::u16string rtl = u"Their is many erors here";
    rtl = *ep::apply(TextEdit{R(14, 5), u"errors", u"erors"}, rtl);
    const TextEdit earlier{R(0, 5), u"There", u"Their"};
    CHECK(ep::is_valid(earlier, rtl));
    CHECK(*ep::apply(earlier, rtl) == u"There is many errors here");

    const std::u16string moved = u"Oh, Their is many";
    const TextEdit stale{R(0, 5), u"There", u"Their"};
    CHECK_FALSE(ep::is_valid(stale, moved));
    const auto fixed = ep::relocate(stale, moved);
    REQUIRE(fixed);
    CHECK(*ep::apply(*fixed, moved) == u"Oh, There is many");

    CHECK(*ep::apply(TextEdit{R(4, 3), u"THE", u"the"}, u"the the the") == u"the THE the");
}
