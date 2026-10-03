#include "speech/speech_text.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <unicode/uchar.h>
#include "speech/kokoro_vocab.hpp"
#include "text/unicode.hpp"

namespace nib::speech {

bool is_space(char32_t c) { return u_isUWhiteSpace(static_cast<UChar32>(c)); }

std::u32string to_u32(const std::u16string& text) {
    const auto cps = code_points(text);
    return std::u32string(cps.begin(), cps.end());
}

std::u32string to_u32(const std::string& utf8) { return to_u32(utf8_to_utf16(utf8)); }

std::string to_utf8(const std::u32string& text) {
    std::u16string u;
    for (char32_t c : text) {
        if (c <= 0xFFFF) {
            u.push_back(static_cast<char16_t>(c));
        } else {
            c -= 0x10000;
            u.push_back(static_cast<char16_t>(0xD800 + (c >> 10)));
            u.push_back(static_cast<char16_t>(0xDC00 + (c & 0x3FF)));
        }
    }
    return utf16_to_utf8(u);
}

namespace {

bool starts(const std::u32string& s, const std::u32string& p) {
    return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}
bool ends(const std::u32string& s, const std::u32string& p) {
    return s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0;
}

std::u32string replace_all(std::u32string s, const std::u32string& from, const std::u32string& to) {
    if (from.empty()) return s;
    std::u32string out;
    size_t at = 0;
    for (;;) {
        const size_t hit = s.find(from, at);
        if (hit == std::u32string::npos) {
            out.append(s, at, std::u32string::npos);
            return out;
        }
        out.append(s, at, hit - at);
        out += to;
        at = hit + from.size();
    }
}

std::u32string strip_ws(const std::u32string& s) {
    size_t a = 0, b = s.size();
    while (a < b && is_space(s[a])) ++a;
    while (b > a && is_space(s[b - 1])) --b;
    return s.substr(a, b - a);
}

std::u32string strip_trailing(std::u32string s) {
    while (!s.empty() && is_space(s.back())) s.pop_back();
    return s;
}

}  // namespace

// --- PhonemePunctuation -------------------------------------------------------

namespace punctuation {
namespace {

bool is_ascii_digit(char32_t c) { return c >= U'0' && c <= U'9'; }

bool is_mark(const std::u32string& chars, size_t i, const std::u32string& marks) {
    const char32_t c = chars[i];
    if (marks.find(c) == std::u32string::npos) return false;
    if (c != U',' && c != U'.') return true;
    // Between two digits it is part of a number: "19,99" must reach espeak
    // whole, or it is read as two numbers.
    const bool before = i > 0 && is_ascii_digit(chars[i - 1]);
    const bool after = i + 1 < chars.size() && is_ascii_digit(chars[i + 1]);
    return !(before && after);
}

struct Run {
    size_t start, end;
};

// Maximal runs of marks and whitespace holding at least one mark: phonemizer's
// (\s*(?:marks)+\s*)+ written out.
std::vector<Run> mark_runs(const std::u32string& chars, const std::u32string& marks) {
    std::vector<Run> runs;
    size_t i = 0;
    while (i < chars.size()) {
        if (!(is_mark(chars, i, marks) || is_space(chars[i]))) {
            ++i;
            continue;
        }
        size_t end = i;
        bool holds = false;
        while (end < chars.size() && (is_mark(chars, end, marks) || is_space(chars[end]))) {
            if (is_mark(chars, end, marks)) holds = true;
            ++end;
        }
        if (holds) runs.push_back({i, end});
        i = end;
    }
    return runs;
}

void preserve_line(const std::u32string& line, int32_t number, const std::u32string& marks,
                   std::vector<std::u32string>& chunks, std::vector<Mark>& out) {
    const auto runs = mark_runs(line, marks);
    if (runs.empty()) {
        chunks.push_back(line);
        return;
    }
    std::vector<std::u32string> texts;
    for (const auto& r : runs) texts.push_back(line.substr(r.start, r.end - r.start));

    // Nothing but marks: carried whole, so "..." still says "...".
    if (texts.size() == 1 && texts[0] == line) {
        out.push_back({number, line, Position::alone});
        return;
    }
    for (size_t i = 0; i < texts.size(); ++i) {
        Position p = Position::inside;
        if (i == 0 && starts(line, texts[i])) p = Position::begin;
        else if (i == texts.size() - 1 && ends(line, texts[i])) p = Position::end;
        out.push_back({number, texts[i], p});
    }
    // Cut where the marks actually are -- not by searching for their text,
    // which lands on the dot inside "5.8" and reads it as "five. eight".
    size_t cursor = 0;
    for (const auto& r : runs) {
        chunks.push_back(line.substr(cursor, r.start - cursor));
        cursor = r.end;
    }
    chunks.push_back(line.substr(cursor));
}

}  // namespace

const std::u32string& default_marks() {
    static const std::u32string marks = U";:,.!?¡¿—…\"«»“”(){}[]";
    return marks;
}

std::vector<std::u32string> lines(const std::u32string& text) {
    size_t a = 0, b = text.size();
    while (a < b && text[a] == U'\n') ++a;
    while (b > a && text[b - 1] == U'\n') --b;
    const auto body = text.substr(a, b - a);
    std::vector<std::u32string> out;
    size_t start = 0;
    for (;;) {
        const size_t nl = body.find(U'\n', start);
        const auto piece = body.substr(start, nl == std::u32string::npos ? std::u32string::npos : nl - start);
        if (!strip_ws(piece).empty()) out.push_back(piece);
        if (nl == std::u32string::npos) break;
        start = nl + 1;
    }
    return out;
}

Preserved preserve(const std::u32string& text, const std::u32string& marks) {
    Preserved p;
    std::vector<std::u32string> chunks;
    int32_t number = 0;
    for (const auto& line : lines(text)) preserve_line(line, number++, marks, chunks, p.marks);
    for (auto& c : chunks) {
        if (!c.empty()) p.chunks.push_back(std::move(c));
    }
    return p;
}

std::vector<std::u32string> restore(std::vector<std::u32string> text, std::vector<Mark> marks,
                                    const std::u32string& separator, bool strip) {
    std::vector<std::u32string> restored;
    int32_t line = 0;
    size_t ti = 0, mi = 0;  // fronts of the two queues

    while (ti < text.size() || mi < marks.size()) {
        if (mi >= marks.size()) {
            for (; ti < text.size(); ++ti) {
                const bool needs = !strip && !separator.empty() && !ends(text[ti], separator);
                restored.push_back(needs ? text[ti] + separator : text[ti]);
            }
            continue;
        }
        if (ti >= text.size()) {
            std::u32string joined;
            for (; mi < marks.size(); ++mi) joined += marks[mi].text;
            restored.push_back(replace_all(joined, U" ", separator));
            continue;
        }
        if (marks[mi].line != line) {
            restored.push_back(text[ti++]);
            ++line;
            continue;
        }
        const Mark current = marks[mi++];
        const std::u32string mark = replace_all(current.text, U" ", separator);

        if (!separator.empty() && ends(text[ti], separator)) {
            text[ti].resize(text[ti].size() - separator.size());
        }
        const std::u32string trailing = (strip || ends(mark, separator)) ? U"" : separator;
        switch (current.position) {
        case Position::begin:
            text[ti] = mark + text[ti];
            break;
        case Position::end:
            restored.push_back(text[ti] + mark + trailing);
            ++ti;
            ++line;
            break;
        case Position::alone:
            restored.push_back(mark + trailing);
            ++line;
            break;
        case Position::inside:
            if (text.size() - ti == 1) {
                text[ti] += mark;
            } else {
                const auto first = text[ti++];
                text[ti] = first + mark + text[ti];
            }
            break;
        }
    }
    return restored;
}

}  // namespace punctuation

// --- Phonemizer ----------------------------------------------------------------

namespace phonemizer {

std::u32string tidy(const std::u32string& raw, bool strip) {
    std::u32string line = strip_ws(raw);
    line = replace_all(line, U"\n", U" ");
    // One pass, not until stable, as in phonemizer.
    line = replace_all(line, U"  ", U" ");

    std::u32string collapsed;
    bool previous = false;
    for (char32_t c : line) {
        if (c == U'_') {
            if (previous) continue;
            previous = true;
        } else {
            previous = false;
        }
        collapsed.push_back(c);
    }
    line = replace_all(collapsed, U"_ ", U" ");
    if (line.empty()) return {};

    std::u32string result;
    size_t start = 0;
    for (;;) {
        const size_t sp = line.find(U' ', start);
        std::u32string word = strip_ws(line.substr(start, sp == std::u32string::npos ? std::u32string::npos : sp - start));
        if (!strip) word += U"_";
        result += replace_all(word, U"_", U"") + U" ";
        if (sp == std::u32string::npos) break;
        start = sp + 1;
    }
    if (strip && !result.empty()) result.pop_back();
    return result;
}

std::u32string phonemize(const std::u32string& text, const PhonemeSource& source) {
    const auto preserved = punctuation::preserve(text);
    std::vector<std::u32string> spoken;
    for (const auto& chunk : preserved.chunks) spoken.push_back(tidy(source(chunk)));
    const auto lines = punctuation::restore(spoken, preserved.marks, U" ", false);
    std::u32string out;
    for (size_t i = 0; i < lines.size(); ++i) {
        if (i) out.push_back(U'\n');
        out += lines[i];
    }
    return out;
}

std::u32string phonemes(const std::u32string& text, const PhonemeSource& source) {
    const auto raw = phonemize(text, source);
    std::u32string out;
    bool pending_space = false;
    for (char32_t c : raw) {
        if (!kokoro::token_for(c)) continue;
        if (is_space(c)) {
            pending_space = !out.empty();
            continue;
        }
        if (pending_space) out.push_back(U' ');
        pending_space = false;
        out.push_back(c);
    }
    return out;
}

}  // namespace phonemizer

// --- PhonemeChunker -----------------------------------------------------------

namespace chunker {
namespace {

const std::u32string sentence_marks = U".!?…";
const std::u32string clause_marks = U",;:";

struct Batch {
    size_t start, end;
};

std::vector<Batch> pack(const std::vector<size_t>& lengths, size_t limit) {
    std::vector<Batch> batches;
    size_t start = 0, size = 0;
    for (size_t i = 0; i < lengths.size(); ++i) {
        // + 1 is the space that rejoins two pieces.
        const size_t candidate = i == start ? lengths[i] : size + 1 + lengths[i];
        if (candidate > limit && i > start) {
            batches.push_back({start, i});
            start = i;
            size = lengths[i];
        } else {
            size = candidate;
        }
    }
    if (!lengths.empty()) batches.push_back({start, lengths.size()});
    return batches;
}

// Python's re.split on (?<=[marks])\s+, or \s+ when marks is null.
std::vector<std::u32string> separate(const std::u32string& text, const std::u32string* marks) {
    std::vector<std::u32string> pieces;
    std::u32string current;
    bool has_previous = false;
    char32_t previous = 0;
    size_t i = 0;
    while (i < text.size()) {
        if (!is_space(text[i])) {
            current.push_back(text[i]);
            previous = text[i];
            has_previous = true;
            ++i;
            continue;
        }
        size_t run = i;
        while (run < text.size() && is_space(text[run])) ++run;
        const bool qualifies = !marks || (has_previous && marks->find(previous) != std::u32string::npos);
        if (qualifies) {
            pieces.push_back(current);
            current.clear();
            has_previous = false;
        } else {
            current.append(text, i, run - i);
        }
        i = run;
    }
    pieces.push_back(current);
    return pieces;
}

std::vector<std::u32string> atoms(const std::u32string& p, size_t limit, int level = 0) {
    if (p.size() <= limit) return p.empty() ? std::vector<std::u32string>{} : std::vector<std::u32string>{p};
    const std::u32string* boundaries[] = {&sentence_marks, &clause_marks, nullptr};
    for (int index = level; index < 3; ++index) {
        const auto pieces = separate(p, boundaries[index]);
        if (pieces.size() <= 1) continue;
        std::vector<std::u32string> out;
        for (const auto& piece : pieces) {
            for (auto& a : atoms(strip_ws(piece), limit, index + 1)) out.push_back(std::move(a));
        }
        return out;
    }
    // One unbroken run longer than the context: sliced rather than dropped,
    // because losing the tail is silent.
    std::vector<std::u32string> out;
    for (size_t at = 0; at < p.size(); at += limit) out.push_back(p.substr(at, limit));
    return out;
}

}  // namespace

std::vector<std::u32string> split(const std::u32string& phonemes, int32_t limit_in) {
    const size_t limit = static_cast<size_t>(limit_in);
    const auto pieces = atoms(strip_ws(phonemes), limit);
    if (pieces.empty()) return {};
    std::vector<size_t> lengths;
    for (const auto& a : pieces) lengths.push_back(a.size());
    const size_t fewest = pack(lengths, limit).size();

    // The smallest limit that still yields `fewest` batches: balanced, so the
    // last batch is not a short one spoken at a different rate.
    size_t low = *std::max_element(lengths.begin(), lengths.end());
    size_t high = limit;
    while (low < high) {
        const size_t middle = (low + high) / 2;
        if (pack(lengths, middle).size() <= fewest) high = middle;
        else low = middle + 1;
    }
    std::vector<std::u32string> out;
    for (const auto& b : pack(lengths, low)) {
        std::u32string joined;
        for (size_t i = b.start; i < b.end; ++i) {
            if (i > b.start) joined.push_back(U' ');
            joined += pieces[i];
        }
        out.push_back(std::move(joined));
    }
    return out;
}

std::vector<std::u32string> streaming(const std::u32string& phonemes, int32_t limit, int32_t lead) {
    auto batches = split(phonemes, limit);
    if (batches.size() <= 1) return batches;
    auto first = split(batches.front(), lead);
    first.insert(first.end(), batches.begin() + 1, batches.end());
    return first;
}

double pause_after(const std::u32string& phonemes, double sentence, double clause) {
    const auto t = strip_trailing(phonemes);
    if (t.empty()) return 0;
    if (sentence_marks.find(t.back()) != std::u32string::npos) return sentence;
    if (clause_marks.find(t.back()) != std::u32string::npos) return clause;
    return 0;
}

}  // namespace chunker

// --- AudioTrim ----------------------------------------------------------------

namespace trim {

Range bounds(const std::vector<float>& samples, float top_db, size_t frame_length, size_t hop_length) {
    // RMS per frame over samples padded by half a frame each side
    // (librosa's center=True).
    const size_t pad = frame_length / 2;
    const size_t padded = samples.size() + pad * 2;
    if (padded < frame_length) return {};
    const size_t frames = (padded - frame_length) / hop_length + 1;
    auto at = [&](size_t i) -> float {
        return i < pad || i >= pad + samples.size() ? 0.f : samples[i - pad];
    };
    std::vector<float> loudness(frames);
    for (size_t f = 0; f < frames; ++f) {
        double total = 0;
        const size_t start = f * hop_length;
        for (size_t k = 0; k < frame_length; ++k) {
            const float s = at(start + k);
            total += static_cast<double>(s) * s;
        }
        loudness[f] = static_cast<float>(std::sqrt(total / frame_length));
    }
    const float loudest = *std::max_element(loudness.begin(), loudness.end());
    if (!(loudest > 0)) return {};

    constexpr float minimum_power = 1e-10f;
    const float reference = std::max(minimum_power, loudest * loudest);
    std::optional<size_t> first, last;
    for (size_t i = 0; i < frames; ++i) {
        const float power = std::max(minimum_power, loudness[i] * loudness[i]);
        const float db = 10 * std::log10(power) - 10 * std::log10(reference);
        if (!(db > -top_db)) continue;
        if (!first) first = i;
        last = i;
    }
    if (!first) return {};
    const size_t start = *first * hop_length;
    const size_t end = std::min(samples.size(), (*last + 1) * hop_length);
    return {start, std::max(start, end)};
}

std::vector<float> trimmed(const std::vector<float>& samples) {
    const auto r = bounds(samples);
    return std::vector<float>(samples.begin() + static_cast<std::ptrdiff_t>(r.start),
                              samples.begin() + static_cast<std::ptrdiff_t>(r.end));
}

}  // namespace trim

std::vector<float> leveled(const std::vector<float>& samples, float volume) {
    std::vector<float> out(samples.size());
    for (size_t i = 0; i < samples.size(); ++i) {
        out[i] = std::clamp(volume == 1.f ? samples[i] : samples[i] * volume, -1.f, 1.f);
    }
    return out;
}

}  // namespace nib::speech

namespace nib::kokoro {

std::optional<int32_t> token_for(char32_t symbol) {
    static const auto index = [] {
        std::vector<std::pair<char32_t, int32_t>> sorted = vocab();
        std::sort(sorted.begin(), sorted.end());
        return sorted;
    }();
    const auto it = std::lower_bound(index.begin(), index.end(), std::pair<char32_t, int32_t>{symbol, INT32_MIN});
    if (it == index.end() || it->first != symbol) return std::nullopt;
    return it->second;
}

std::vector<int32_t> tokenize(const std::u32string& phonemes) {
    if (phonemes.size() > static_cast<size_t>(max_phonemes)) {
        throw std::length_error(std::to_string(phonemes.size()) + " phonemes is more than the model's limit of "
                                + std::to_string(max_phonemes));
    }
    std::vector<int32_t> out;
    for (char32_t c : phonemes) {
        if (auto t = token_for(c)) out.push_back(*t);
    }
    return out;
}

std::u32string unknown_symbols(const std::u32string& phonemes) {
    std::u32string out;
    for (char32_t c : phonemes) {
        if (!token_for(c) && out.find(c) == std::u32string::npos) out.push_back(c);
    }
    return out;
}

}  // namespace nib::kokoro
