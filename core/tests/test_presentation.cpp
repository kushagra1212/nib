// Port of MergeTests, DiffTextTests, DiffTextRenderTests,
// ProposalAttributionTests, RewriteFailureMessageTests and MarkPlacementTests.
#include "test_support.hpp"
#include <algorithm>
#include <set>
#include "present/presentation.hpp"

using namespace nib;
using namespace nib::present;
using V = std::vector<std::u16string>;

namespace {
Suggestion at(const std::u16string& text, const std::u16string& word,
              SuggestionKind kind = SuggestionKind::correction) {
    Suggestion s;
    s.kind = kind;
    const auto p = text.find(word);
    s.range = R(static_cast<int32_t>(p), static_cast<int32_t>(word.size()));
    s.message = u"m";
    s.replacements = {u"x"};
    return s;
}
V excerpts(const std::vector<Suggestion>& list, const std::u16string& text) {
    V out;
    for (const auto& s : list) out.push_back(*s.excerpt(text));
    return out;
}
Suggestion range(int32_t location, int32_t length) {
    Suggestion s;
    s.range = R(location, length);
    s.message = u"m";
    return s;
}
std::u16string card(const Suggestion& s, const std::u16string& replacement, const std::u16string& context) {
    return plain_text(fix_card(s, replacement, context));
}
V styled(const std::u16string& a, const std::u16string& b, Style style) {
    V out;
    for (const auto& r : diff(a, b)) {
        if (r.style == style) out.push_back(r.text);
    }
    return out;
}
}  // namespace

TEST_CASE("Merge") {
    std::u16string t = u"Their is many erors here";
    CHECK(excerpts(merge({at(t, u"Their"), at(t, u"erors")}, {at(t, u"Their is many erors")}, t), t)
          == V{u"Their", u"erors"});
    t = u"one two three four five six";
    CHECK(merge({}, {at(t, u"one two three four five")}, t).empty());
    t = u"it could of worked";
    CHECK(merge({}, {at(t, u"could of")}, t).size() == 1);
    t = u"Their is many erors here";
    CHECK(excerpts(merge({at(t, u"Their")}, {at(t, u"erors")}, t), t) == V{u"Their", u"erors"});
    t = u"Their is many here";
    const auto m = merge({at(t, u"Their")}, {at(t, u"Their is")}, t);
    REQUIRE(m.size() == 1);
    CHECK(*m[0].excerpt(t) == u"Their");
    t = u"alpha beta gamma delta";
    CHECK(excerpts(merge({at(t, u"gamma")}, {at(t, u"alpha"), at(t, u"delta")}, t), t)
          == V{u"alpha", u"gamma", u"delta"});
    t = u"Their is here";
    CHECK(merge({at(t, u"Their")}, {}, t).size() == 1);
    CHECK(merge({}, {}, u"text").empty());
    t = u"one two three four five";
    CHECK(merge({}, {at(t, u"one two three four")}, t).size() == 1);
}

TEST_CASE("Clarity waits for corrections in its sentence") {
    const std::u16string t = u"Their is a bug. The rest reads fine enough here.";
    auto clean = at(t, u"The rest reads fine enough here.", SuggestionKind::clarity);
    auto dirty = at(t, u"Their is a bug.", SuggestionKind::clarity);
    const auto out = settle_clarity({at(t, u"Their")}, {dirty, clean});
    REQUIRE(out.size() == 2);
    CHECK(out[0].kind == SuggestionKind::correction);
    CHECK(out[1].range == clean.range);
}

TEST_CASE("FixCard diff text") {
    auto out = card(range(0, 5), u"There", u"Their is many");
    CHECK(contains(out, u"Their"));
    CHECK(contains(out, u"There"));
    CHECK(contains(out, u"is many"));
    CHECK(contains(card(range(13, 5), u"There", u"Honest state Their"), u"Honest state"));
    CHECK(card(range(500, 5), u"There", u"short") == u"There");
    CHECK(card(range(3, 99), u"There", u"short") == u"There");
    out = card(range(3, 3), u"good", u"😀 bad ending");
    CHECK(contains(out, u"good"));
    CHECK(contains(out, u"bad"));

    std::u16string long_lead;
    for (int i = 0; i < 40; ++i) long_lead += u"word ";
    CHECK(contains(card(range(static_cast<int32_t>(long_lead.size()), 3), u"XYZ", long_lead + u"abc"), u"…"));
    std::u16string tail;
    for (int i = 0; i < 40; ++i) tail += u" word";
    CHECK(contains(card(range(0, 3), u"XYZ", u"abc" + tail), u"…"));
    CHECK_FALSE(contains(card(range(0, 5), u"There", u"Their is"), u"…"));
    CHECK(card(range(0, 0), u"x", u"") == u" x");

    const auto runs = fix_card(range(0, 5), u"There", u"Their is many");
    std::vector<Run> struck;
    for (const auto& r : runs) {
        if (r.style == Style::removed) struck.push_back(r);
    }
    REQUIRE(struck.size() == 1);
    CHECK(struck[0].text == u"Their");
}

TEST_CASE("DiffText render") {
    const std::u16string same = u"the cart is empty";
    CHECK(plain_text(diff(same, same)) == same);
    CHECK(styled(same, same, Style::removed).empty());
    CHECK(styled(same, same, Style::added).empty());

    CHECK(styled(u"their is a bug", u"there is a bug", Style::removed).front() == u"their");
    CHECK(styled(u"their is a bug", u"there is a bug", Style::added).front() == u"there");
    CHECK(styled(u"fix the bug", u"fix the small bug", Style::added) == V{u"small"});
    CHECK(styled(u"fix the bug", u"fix the small bug", Style::removed).empty());
    CHECK(styled(u"fix the small bug", u"fix the bug", Style::removed) == V{u"small"});
    CHECK(styled(u"fix the small bug", u"fix the bug", Style::added).empty());

    const std::u16string before = u"can also scroll to top of the catalog so that after navigation";
    const std::u16string after = u"Can also scroll to the top of the catalogue after navigating";
    const auto shown = lowercased(plain_text(diff(before, after)));
    for (const auto& w : split_whitespace(before + u" " + after)) CHECK(contains(shown, lowercased(w)));

    CHECK(styled(u"i use chatgpt daily", u"I use ChatGPT daily", Style::removed) == V{u"i", u"chatgpt"});
    CHECK(styled(u"i use chatgpt daily", u"I use ChatGPT daily", Style::added) == V{u"I", u"ChatGPT"});
    CHECK(plain_text(diff(u"", u"")).empty());
    CHECK(plain_text(diff(u"", u"hello")) == u"hello");
    CHECK(plain_text(diff(u"hello", u"")) == u"hello");
    CHECK(styled(u"one two three", u"four five six", Style::removed) == V{u"one", u"two", u"three"});
    CHECK(styled(u"one two three", u"four five six", Style::added) == V{u"four", u"five", u"six"});
}

TEST_CASE("Proposal attribution") {
    CHECK(starts_with(rewrite_mode::badge(RewriteMode::native), u"NATIVE"));
    CHECK(starts_with(rewrite_mode::badge(RewriteMode::fix_grammar), u"FIX"));
    std::set<std::u16string> names;
    for (auto mode : all_rewrite_modes) {
        const std::u16string name = rewrite_mode::short_title(mode);
        CHECK_FALSE(name.empty());
        names.insert(name);
    }
    CHECK(names.size() == all_rewrite_modes.size());
    CHECK(auto_order[0] == RewriteMode::fix_grammar);
    CHECK(auto_order[1] == RewriteMode::clearer);
    CHECK(auto_order[2] == RewriteMode::native);
    CHECK(std::find(auto_order.begin(), auto_order.end(), RewriteMode::shorter) == auto_order.end());
}

TEST_CASE("Rewrite failure messages") {
    using K = RewriteError::Kind;
    const auto oom = failure_message({K::out_of_memory});
    CHECK(contains(oom, u"memory"));
    CHECK(contains(oom, u"again"));
    CHECK_FALSE(contains(oom, u"unavailable"));
    CHECK(contains(failure_message({K::rejected, u"overloaded", 503}), u"503"));

    std::set<std::u16string> messages;
    for (auto k : {K::model_missing, K::server_failed, K::bad_response, K::out_of_memory, K::rejected,
                   K::truncated, K::timed_out, K::connection_lost}) {
        const auto m = failure_message({k, std::u16string(200, u'x'), 500});
        CHECK_FALSE(contains(m, u"unavailable"));
        CHECK(grapheme_count(m) <= 60);
        messages.insert(m);
    }
    CHECK(messages.size() == 8);
    CHECK(contains(failure_message({K::timed_out}), u"again"));
    CHECK(contains(failure_message({K::truncated}), u"long"));
}

TEST_CASE("Mark placement") {
    const Rect field{100, 200, 400, 300};
    Mark inside{range(0, 3), {{110, 210, 150, 230}}};
    Mark outside{range(5, 3), {{110, 400, 150, 420}}};
    Mark half{range(9, 3), {{90, 290, 130, 310}}};
    const auto placed = place({inside, outside, half}, field);
    REQUIRE(placed.size() == 2);
    CHECK(placed[0].rects[0] == Rect{10, 10, 50, 30});
    CHECK(placed[1].rects[0] == Rect{0, 90, 30, 100});
}

TEST_CASE("Selections worth rewriting") {
    CHECK_FALSE(worth_rewriting(u"word"));
    CHECK_FALSE(worth_rewriting(u"two words"));
    CHECK(worth_rewriting(u"three whole words"));
    CHECK_FALSE(worth_rewriting(u"a b c"));
}
