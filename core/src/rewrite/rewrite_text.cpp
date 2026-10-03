#include "rewrite/rewrite_text.hpp"

#include <algorithm>
#include <nlohmann/json.hpp>
#include "lint/suggestion_filter.hpp"
#include "lint/word_diff.hpp"
#include "text/unicode.hpp"

namespace nib {

std::u16string RewriteError::description() const {
    switch (kind) {
    case Kind::model_missing: return u"no model at " + detail;
    case Kind::server_failed: return u"llama-server: " + detail;
    case Kind::bad_response:  return u"could not parse the model's response";
    case Kind::rejected:
        return detail.empty() ? u"llama-server answered " + to_u16(status)
                              : u"llama-server answered " + to_u16(status) + u": " + detail;
    case Kind::out_of_memory:
        return u"not enough memory to run this model -- try a smaller one, "
               u"or close some apps";
    case Kind::truncated:
        return u"the selection is too long to rewrite in one pass";
    }
    return {};
}

namespace rewrite_text {
namespace {

std::vector<std::u16string> lowered_words(const std::u16string& text) {
    std::vector<std::u16string> out;
    for (const auto& t : word_diff::tokenize(text)) out.push_back(lowercased(t.text));
    return out;
}

std::vector<std::u16string> split_lines(const std::u16string& text) {
    std::vector<std::u16string> out;
    size_t start = 0;
    for (;;) {
        const size_t nl = text.find(u'\n', start);
        if (nl == std::u16string::npos) {
            out.push_back(text.substr(start));
            return out;
        }
        out.push_back(text.substr(start, nl - start));
        start = nl + 1;
    }
}

std::u16string join_lines(const std::vector<std::u16string>& lines, size_t from, size_t to) {
    std::u16string out;
    for (size_t i = from; i < to; ++i) {
        if (i > from) out.push_back(u'\n');
        out += lines[i];
    }
    return out;
}

// Trims spaces and tabs only, as .whitespaces did on a single line.
std::u16string trim_spaces(const std::u16string& s) {
    size_t a = 0, b = s.size();
    while (a < b && is_whitespace(s[a]) && !is_newline(s[a])) ++a;
    while (b > a && is_whitespace(s[b - 1]) && !is_newline(s[b - 1])) --b;
    return s.substr(a, b - a);
}

}  // namespace

int32_t headroom(const std::u16string& text, int32_t context) {
    return std::max(128, context - grapheme_count(text) / 4 - prompt_overhead);
}

int32_t token_budget(const std::u16string& text, int32_t limit, int32_t context) {
    const int32_t estimated = grapheme_count(text) / 4;
    // 2.0 rather than 1.8: Native legitimately expands, and a budget sized for
    // a correction clips a translation.
    const int32_t wanted = std::max(128, static_cast<int32_t>(estimated * 2.0) + 96);
    return std::min({limit, headroom(text, context), wanted});
}

std::u16string clean(const std::u16string& raw) {
    std::u16string text = trimmed(raw);

    // Reasoning models emit a <think> block before the answer.
    const size_t think = text.find(u"</think>");
    if (think != std::u16string::npos) text = trimmed(text.substr(think + 8));

    // Fenced code blocks, which some models wrap prose in.
    if (starts_with(text, u"```")) {
        const auto lines = split_lines(text);
        size_t end = 1;
        while (end < lines.size() && !starts_with(lines[end], u"```")) ++end;
        text = join_lines(lines, 1, end);
    }

    // A preamble like "Here is the corrected text:" on its own first line.
    static const std::u16string preambles[] = {
        u"here is", u"here's", u"sure", u"certainly", u"corrected text",
        u"rewritten text", u"revised text"};
    const auto lines = split_lines(text);
    if (lines.size() > 1) {
        const auto first = trim_spaces(lowercased(lines[0]));
        if (ends_with(first, u":")
            && std::any_of(std::begin(preambles), std::end(preambles),
                           [&](const std::u16string& p) { return starts_with(first, p); })) {
            text = trimmed(join_lines(lines, 1, lines.size()));
        }
    }

    // Matched wrapping quotes the model added around the whole answer.
    static const std::pair<char16_t, char16_t> pairs[] = {
        {u'"', u'"'}, {u'“', u'”'}, {u'\'', u'\''}};
    for (const auto& [open, close] : pairs) {
        if (!text.empty() && text.front() == open && text.back() == close
            && grapheme_count(text) > 2) {
            text = text.substr(1, text.size() - 2);
            break;
        }
    }
    return trimmed(text);
}

RewriteError failure(int32_t status, const std::string& body, const std::string& log) {
    std::u16string detail = utf8_to_utf16(body);
    const auto json = nlohmann::json::parse(body, nullptr, false);
    if (json.is_object()) {
        const auto error = json.find("error");
        if (error != json.end() && error->is_object()) {
            const auto message = error->find("message");
            if (message != error->end() && message->is_string()) {
                detail = utf8_to_utf16(message->get<std::string>());
            }
        }
    }

    // The body carries llama.cpp's own message, which for a model too large is
    // the unhelpful "Compute error."; the log carries the out-of-memory line
    // that says what actually happened. The fix is a smaller model, not a retry.
    const auto haystack = lowercased(detail + u" " + utf8_to_utf16(log));
    for (const char16_t* marker : {u"out of memory", u"outofmemory", u"insufficient memory",
                                   u"failed to allocate", u"unable to allocate"}) {
        if (contains(haystack, marker)) return {RewriteError::Kind::out_of_memory, {}, status};
    }

    std::u16string shortened;
    const auto chars = graphemes(detail);
    for (size_t i = 0; i < chars.size() && i < 200; ++i) shortened += chars[i];
    return {RewriteError::Kind::rejected, trimmed(shortened), status};
}

double character_similarity(const std::u16string& a, const std::u16string& b) {
    const int32_t longest = std::max(grapheme_count(a), grapheme_count(b));
    if (longest <= 0) return 1;
    const int32_t distance = suggestion_filter::edit_distance(a, b);
    return 1.0 - static_cast<double>(distance) / static_cast<double>(longest);
}

bool is_trustworthy(const std::u16string& original, const std::u16string& corrected) {
    if (corrected == original) return true;
    const auto before = lowered_words(original);
    const auto after = lowered_words(corrected);
    if (before.empty() || after.empty()) return false;

    // A wholesale change in length means it summarised, padded, or answered.
    const double ratio = static_cast<double>(after.size()) / static_cast<double>(before.size());
    if (ratio < 0.6 || ratio > 1.6) return false;

    // Characters, not words: "Their is many erors" to "There are many errors"
    // keeps two words of five, and is a correction.
    return character_similarity(lowercased(original), lowercased(corrected)) >= 0.5;
}

int32_t longest_dropped_run(const std::u16string& original, const std::u16string& corrected) {
    const auto before = lowered_words(original);
    const auto after = lowered_words(corrected);
    if (before.empty()) return 0;

    // The subsequence is what survived, in order.
    const auto kept = word_diff::longest_common_subsequence(before, after);
    size_t index = 0;
    int32_t run = 0, longest = 0;
    for (const auto& word : before) {
        if (index < kept.size() && word == kept[index]) {
            ++index;
            run = 0;
        } else {
            ++run;
            longest = std::max(longest, run);
        }
    }
    return longest;
}

bool drops_content(const std::u16string& original, const std::u16string& corrected,
                   int32_t limit) {
    return longest_dropped_run(original, corrected) >= limit;
}

int32_t dropped_tail(const std::u16string& original, const std::u16string& corrected) {
    const auto before = lowered_words(original);
    const auto after = lowered_words(corrected);
    if (before.empty()) return 0;
    const auto kept = word_diff::longest_common_subsequence(before, after);
    if (kept.empty()) return static_cast<int32_t>(before.size());
    const auto last = std::find(before.rbegin(), before.rend(), kept.back());
    if (last == before.rend()) return static_cast<int32_t>(before.size());
    const auto index = static_cast<int32_t>(before.rend() - last) - 1;
    return static_cast<int32_t>(before.size()) - 1 - index;
}

bool looks_unfinished(const std::u16string& text) {
    const auto t = trimmed(text);
    const auto chars = graphemes(t);
    if (chars.empty()) return true;
    static constexpr std::u16string_view endings = u".!?…\"')]}»”’";
    const auto& last = chars.back();
    return !(last.size() == 1 && endings.find(last[0]) != std::u16string_view::npos);
}

bool flips_question(const std::u16string& original, const std::u16string& corrected) {
    const bool asked = ends_with(trimmed(original), u"?");
    const bool answers = ends_with(trimmed(corrected), u"?");
    return asked && !answers;
}

}  // namespace rewrite_text
}  // namespace nib
