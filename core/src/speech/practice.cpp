#include "speech/practice.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <map>
#include "text/unicode.hpp"

namespace nib::speech {
namespace {

const std::vector<std::u16string> filler_words = {u"um", u"umm", u"uh", u"uhh", u"er", u"erm", u"ah", u"hmm"};
// Filler only when they open a sentence: "so that the index is used" is a
// conjunction doing its job.
const std::vector<std::u16string> opening_fillers = {u"so",       u"right",    u"okay",      u"yeah",
                                                     u"well",     u"now",      u"basically", u"actually",
                                                     u"literally", u"obviously", u"essentially"};
const std::vector<std::u16string> filler_phrases = {u"you know", u"i mean",     u"sort of", u"kind of",
                                                    u"you see",  u"and stuff", u"or something", u"and all"};
const std::vector<std::u16string> trailing_endings = {
    u"so yeah", u"yeah so", u"something like that", u"or something", u"and stuff", u"or whatever",
    u"that's it i guess", u"i guess", u"you know", u"and so on", u"etc"};
const std::u16string marker = u"·filler·";

bool has(const std::vector<std::u16string>& list, const std::u16string& w) {
    return std::find(list.begin(), list.end(), w) != list.end();
}

std::u16string replace_all(std::u16string s, const std::u16string& from, const std::u16string& to) {
    size_t at = 0;
    while ((at = s.find(from, at)) != std::u16string::npos) {
        s.replace(at, from.size(), to);
        at += to.size();
    }
    return s;
}

std::u16string fmt(const char* f, double v) {
    char buf[32];
    std::snprintf(buf, sizeof buf, f, v);
    return utf8_to_utf16(buf);
}

}  // namespace

std::u16string DeliveryReport::normalise(const std::u16string& text) {
    std::u16string stripped;
    for (const auto& g : graphemes(lowercased(text))) {
        const char32_t c = first_code_point(g);
        stripped += (is_letter(c) || is_number(c) || c == U'\'') ? g : u" ";
    }
    std::u16string out;
    for (const auto& w : split_whitespace(stripped)) {
        if (!out.empty()) out.push_back(u' ');
        out += w;
    }
    return out;
}

int32_t DeliveryReport::occurrences(const std::u16string& needle, const std::u16string& haystack) {
    if (needle.empty()) return 0;
    int32_t count = 0;
    for (size_t at = haystack.find(needle); at != std::u16string::npos; at = haystack.find(needle, at + needle.size())) {
        ++count;
    }
    return count;
}

std::vector<std::u16string> DeliveryReport::sentences(const std::u16string& text) {
    std::vector<std::u16string> out;
    std::u16string current;
    auto flush = [&] {
        auto t = trimmed(current);
        if (!t.empty()) out.push_back(std::move(t));
        current.clear();
    };
    for (char16_t c : text) {
        if (c == u'.' || c == u'!' || c == u'?') flush();
        else current.push_back(c);
    }
    flush();
    return out;
}

DeliveryReport::DeliveryReport(const std::vector<SpokenSegment>& segments, double total) : duration(total) {
    std::u16string text;
    for (size_t i = 0; i < segments.size(); ++i) {
        if (i) text.push_back(u' ');
        text += segments[i].text;
    }
    const auto normalised = normalise(text);
    const auto words = split_whitespace(normalised);
    word_count = static_cast<int32_t>(words.size());
    pace = duration > 0 ? word_count / duration * 60 : 0;

    // An unambiguous filler counts anywhere; a positional one if it opens the
    // sentence or follows another filler -- "um, so basically" is one
    // hesitation with three words in it.
    std::map<std::u16string, int32_t> counts;
    for (const auto& sentence : sentences(text)) {
        auto working = normalise(sentence);
        for (const auto& phrase : filler_phrases) {
            const int32_t hits = occurrences(phrase, working);
            if (!hits) continue;
            counts[phrase] += hits;
            working = replace_all(working, phrase, u" " + marker + u" ");
        }
        bool previous = false;
        const auto tokens = split_whitespace(working);
        for (size_t i = 0; i < tokens.size(); ++i) {
            const auto& token = tokens[i];
            if (token == marker) {
                previous = true;
            } else if (has(filler_words, token)) {
                ++counts[token];
                previous = true;
            } else if (has(opening_fillers, token) && (i == 0 || previous)) {
                ++counts[token];
                previous = true;
            } else {
                previous = false;
            }
        }
    }
    for (const auto& [w, n] : counts) fillers.emplace_back(w, n);
    // Most first; ties alphabetical.
    std::sort(fillers.begin(), fillers.end(), [](const auto& a, const auto& b) {
        return a.second != b.second ? a.second > b.second : a.first < b.first;
    });
    for (const auto& [w, n] : counts) filler_total += n;

    // The gap between segments, not their own length: whisper ends a segment
    // where the speech stops.
    for (size_t i = 1; i < segments.size(); ++i) {
        const double gap = segments[i].start - segments[i - 1].end;
        if (gap >= pause_threshold) long_pauses.emplace_back(segments[i - 1].end, gap);
    }
    for (const auto& s : sentences(text)) {
        longest_sentence = std::max(longest_sentence, static_cast<int32_t>(split_whitespace(s).size()));
    }
    std::u16string tail;
    const size_t from = words.size() > 4 ? words.size() - 4 : 0;
    for (size_t i = from; i < words.size(); ++i) {
        if (i > from) tail.push_back(u' ');
        tail += words[i];
    }
    for (const auto& ending : trailing_endings) {
        if (ends_with(tail, ending)) trails_off = true;
    }
}

std::u16string DeliveryReport::pace_verdict() const {
    if (pace < 110) return u"too slow -- you sound unsure";
    if (pace < comfortable_low) return u"a little slow";
    if (pace <= comfortable_high) return u"good";
    if (pace <= 185) return u"a little fast";
    return u"rushing -- the listener stops retaining detail";
}

double DeliveryReport::filler_rate() const { return duration > 0 ? filler_total / duration * 60 : 0; }

std::u16string DeliveryReport::filler_verdict() const {
    const double r = filler_rate();
    if (r < 3) return u"clean";
    if (r < 6) return u"noticeable";
    return u"distracting";
}

namespace practice {

std::u16string time(double seconds) {
    const auto total = static_cast<long long>(std::llround(seconds));
    char buf[32];
    std::snprintf(buf, sizeof buf, "%lld:%02lld", total / 60, total % 60);
    return utf8_to_utf16(buf);
}

std::vector<std::u16string> advice(const DeliveryReport& r) {
    // Ordered by what each costs the listener, not by how easy it is to fix.
    std::vector<std::u16string> fixes;
    if (r.trails_off) {
        fixes.push_back(u"**End on a full stop.** The take finishes on a trailing phrase, which leaves the "
                        u"listener unsure whether you are done. Decide your last sentence before you start.");
    }
    if (r.filler_rate() >= 6) {
        std::u16string line = u"**Cut the filler.** " + fmt("%.0f", r.filler_rate()) + u" per minute";
        if (!r.fillers.empty()) line += u", mostly “" + r.fillers.front().first + u"”";
        line += u". The fix is not talking faster, it is being willing to be silent for a second.";
        fixes.push_back(line);
    }
    const auto wpm = to_u16(std::llround(r.pace));
    if (r.pace > 185) {
        fixes.push_back(u"**Slow down.** " + wpm + u" wpm is past the point where a listener retains detail.");
    } else if (r.pace < 110 && r.word_count > 30) {
        fixes.push_back(u"**Pick up the pace.** " + wpm + u" wpm reads as unsure of the answer.");
    }
    if (r.longest_sentence > 35) {
        fixes.push_back(u"**Break up the long sentence.** " + to_u16(r.longest_sentence)
                        + u" words is one the listener lost halfway through. Spoken sentences want to be "
                          u"under 25.");
    }
    if (r.long_pauses.size() >= 3) {
        fixes.push_back(u"**" + to_u16(static_cast<int64_t>(r.long_pauses.size()))
                        + u" silent stalls.** Say what you are thinking instead: “let me start with the "
                          u"simple version” buys the same time and sounds like reasoning rather than a "
                          u"blank.");
    }
    return fixes;
}

std::u16string markdown(const std::vector<SpokenSegment>& segments, const DeliveryReport& report,
                        const std::u16string& audio_name, int64_t unix_seconds) {
    const std::time_t t = static_cast<std::time_t>(unix_seconds);
    std::tm local{}, utc{};
#if defined(_WIN32)
    localtime_s(&local, &t);
    gmtime_s(&utc, &t);
#else
    localtime_r(&t, &local);
    gmtime_r(&t, &utc);
#endif
    char stamp[32], iso[32];
    std::strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M", &local);
    std::strftime(iso, sizeof iso, "%Y-%m-%dT%H:%M:%SZ", &utc);

    std::u16string out;
    out += u"---\ntags:\n  - practice\n  - speaking\n";
    out += u"created: " + utf8_to_utf16(iso) + u"\n";
    out += u"type: practice-take\n---\n\n";
    out += u"# Practice take, " + utf8_to_utf16(stamp) + u"\n\n";
    out += u"Audio: [" + audio_name + u"](" + audio_name + u")\n\n";
    out += u"## Delivery\n\n| | |\n|---|---|\n";
    out += u"| Length | " + time(report.duration) + u" |\n";
    out += u"| Words | " + to_u16(report.word_count) + u" |\n";
    out += u"| Pace | **" + to_u16(std::llround(report.pace)) + u" wpm** -- " + report.pace_verdict() + u" |\n";
    out += u"| Fillers | **" + to_u16(report.filler_total) + u"** (" + fmt("%.1f", report.filler_rate())
           + u"/min) -- " + report.filler_verdict() + u" |\n";
    out += u"| Pauses over " + to_u16(static_cast<int64_t>(DeliveryReport::pause_threshold)) + u"s | "
           + to_u16(static_cast<int64_t>(report.long_pauses.size())) + u" |\n";
    out += u"| Longest sentence | " + to_u16(report.longest_sentence) + u" words"
           + (report.longest_sentence > 30 ? u" -- too long to follow spoken |\n" : u" |\n");
    out += u"| Ending | " + std::u16string(report.trails_off ? u"**trails off**" : u"lands") + u" |\n\n";

    if (!report.fillers.empty()) {
        out += u"### What you said instead of nothing\n\n";
        for (const auto& [w, n] : report.fillers) out += u"- **" + w + u"** × " + to_u16(n) + u"\n";
        out += u"\n";
    }
    if (!report.long_pauses.empty()) {
        out += u"### Where you stalled\n\n";
        out += u"Play the audio at these points. A pause is only a problem when it is silent -- thinking out "
               u"loud is not a pause.\n\n";
        for (const auto& [at, length] : report.long_pauses) {
            out += u"- **" + time(at) + u"** -- " + fmt("%.1f", length) + u"s of silence\n";
        }
        out += u"\n";
    }
    out += u"## What to fix first\n\n";
    const auto fixes = advice(report);
    if (fixes.empty()) {
        out += u"Nothing measurable. Judge the content on its own.\n\n";
    } else {
        for (size_t i = 0; i < fixes.size(); ++i) out += to_u16(static_cast<int64_t>(i + 1)) + u". " + fixes[i] + u"\n";
        out += u"\n";
    }
    out += u"## Transcript\n\n";
    if (segments.empty()) {
        out += u"*No speech detected.*\n";
    } else {
        for (const auto& s : segments) {
            const auto t2 = trimmed(s.text);
            if (t2.empty()) continue;
            out += u"**[" + time(s.start) + u"]** " + t2 + u"\n\n";
        }
    }
    return out;
}

}  // namespace practice
}  // namespace nib::speech
