#include "speech/dictation_text.hpp"

#include <fstream>
#include <memory>
#include <nlohmann/json.hpp>
#include <unicode/regex.h>
#include <unicode/unistr.h>
#include "platform/paths.hpp"
#include "text/unicode.hpp"

namespace nib::speech {
namespace fs = std::filesystem;

namespace {

std::u16string regex_replace(const std::u16string& text, const char16_t* pattern, const char16_t* with) {
    UErrorCode status = U_ZERO_ERROR;
    icu::UnicodeString pat(reinterpret_cast<const UChar*>(pattern));
    std::unique_ptr<icu::RegexPattern> re(icu::RegexPattern::compile(pat, 0, status));
    if (U_FAILURE(status)) return text;
    icu::UnicodeString input(reinterpret_cast<const UChar*>(text.data()), static_cast<int32_t>(text.size()));
    std::unique_ptr<icu::RegexMatcher> m(re->matcher(input, status));
    if (U_FAILURE(status)) return text;
    const icu::UnicodeString out = m->replaceAll(icu::UnicodeString(reinterpret_cast<const UChar*>(with)), status);
    if (U_FAILURE(status)) return text;
    return std::u16string(reinterpret_cast<const char16_t*>(out.getBuffer()), static_cast<size_t>(out.length()));
}

}  // namespace

std::u16string clean_transcript(const std::u16string& raw) {
    std::u16string text = raw;
    // Brackets and asterisks go unconditionally: whisper never uses them for
    // speech.
    text = regex_replace(text, u"\\[[^\\]]*\\]", u" ");
    text = regex_replace(text, u"\\*[^*]*\\*", u" ");
    // Parentheses only around a short phrase of plain words describing a
    // sound; anything with digits, punctuation or four words is dictation.
    text = regex_replace(text, u"\\((?:[A-Za-z]+ ){0,2}[A-Za-z]+\\)", u" ");
    text = regex_replace(text, u"\\s+", u" ");
    // "Hello [BLANK_AUDIO], there" must not end up "Hello , there".
    text = regex_replace(text, u" ([,.!?;:])", u"$1");
    return trimmed(text);
}

namespace vocabulary {

const std::vector<std::u16string>& defaults() {
    static const std::vector<std::u16string> list = {
        u"GitHub", u"TypeScript", u"JavaScript", u"Swift", u"Visual Studio", u"Windows", u"npm", u"API",
        u"JSON", u"SQL", u"GraphQL", u"CSS", u"HTML", u"React", u"Node", u"Docker", u"Kubernetes",
        u"Postgres", u"Redis", u"useMemo", u"useState", u"useEffect", u"useCallback", u"backend",
        u"frontend", u"staging", u"refactor", u"async", u"await", u"repo", u"commit", u"merge", u"rebase",
        u"pull request", u"changelog"};
    return list;
}

fs::path file() { return platform::paths::data_dir() / L"vocabulary.txt"; }

std::vector<std::u16string> parse(const std::u16string& contents) {
    std::vector<std::u16string> out;
    size_t start = 0;
    for (;;) {
        const size_t nl = contents.find(u'\n', start);
        auto line = trimmed(contents.substr(start, nl == std::u16string::npos ? std::u16string::npos : nl - start));
        if (!line.empty() && line[0] != u'#') out.push_back(std::move(line));
        if (nl == std::u16string::npos) break;
        start = nl + 1;
    }
    return out;
}

std::vector<std::u16string> terms() {
    std::ifstream in(file(), std::ios::binary);
    if (!in) return defaults();
    const std::string utf8((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    auto list = parse(utf8_to_utf16(utf8));
    return list.empty() ? defaults() : list;
}

std::optional<std::u16string> prompt(const std::vector<std::u16string>& list) {
    if (list.empty()) return std::nullopt;
    std::u16string out = u"Terms used: ";
    for (size_t i = 0; i < list.size() && i < limit; ++i) {
        if (i) out += u", ";
        out += list[i];
    }
    return out + u".";
}

std::u16string file_header() {
    return u"# Words nib should expect when you dictate.\n"
           u"#\n"
           u"# One per line. Names, jargon and project words belong here: whisper\n"
           u"# replaces anything it has never seen with the nearest real word, so\n"
           u"# \"Hasura\" becomes \"Azure\" until it is listed below.\n"
           u"#\n"
           u"# Keep it short. This is a nudge, not a dictionary, and a long list\n"
           u"# dilutes it. Lines starting with # are ignored.\n";
}

fs::path create_file_if_needed() {
    const auto path = file();
    std::error_code ec;
    if (fs::exists(path, ec)) return path;
    fs::create_directories(path.parent_path(), ec);
    std::u16string body = file_header();
    for (const auto& t : defaults()) body += t + u"\n";
    std::ofstream(path, std::ios::binary) << utf16_to_utf8(body);
    return path;
}

}  // namespace vocabulary

std::u16string DictationHistory::Entry::label(size_t width) const {
    const auto words = split_whitespace(text);
    std::u16string flat;
    for (size_t i = 0; i < words.size(); ++i) {
        if (i) flat.push_back(u' ');
        flat += words[i];
    }
    const auto chars = graphemes(flat);
    if (chars.size() <= width) return flat;
    std::u16string head, tail;
    for (size_t i = 0; i < width - 22; ++i) head += chars[i];
    for (size_t i = chars.size() - 18; i < chars.size(); ++i) tail += chars[i];
    return head + u"… " + tail;
}

int64_t DictationHistory::now() {
    return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}

void DictationHistory::add(const std::u16string& text, int64_t at) {
    const auto t = trimmed(text);
    if (t.empty()) return;
    // The same sentence twice in a row is one entry: repeating a failed
    // dictation is the commonest reason to say it again.
    if (!entries_.empty() && entries_.front().text == t) {
        entries_.front() = {t, at};
        return;
    }
    entries_.insert(entries_.begin(), {t, at});
    if (entries_.size() > limit) entries_.resize(limit);
}

fs::path DictationHistory::file() { return platform::paths::data_dir() / L"dictation.json"; }

DictationHistory DictationHistory::load(const fs::path& from) {
    DictationHistory h;
    std::ifstream in(from, std::ios::binary);
    if (!in) return h;
    const auto j = nlohmann::json::parse(in, nullptr, false);
    if (!j.is_array()) return h;
    for (const auto& e : j) {
        if (!e.is_object() || !e.contains("text") || !e["text"].is_string()) continue;
        h.entries_.push_back({utf8_to_utf16(e["text"].get<std::string>()), e.value("date", int64_t{0})});
        if (h.entries_.size() >= limit) break;
    }
    return h;
}

void DictationHistory::save(const fs::path& to) const {
    nlohmann::json j = nlohmann::json::array();
    for (const auto& e : entries_) j.push_back({{"text", utf16_to_utf8(e.text)}, {"date", e.unix_seconds}});
    std::error_code ec;
    fs::create_directories(to.parent_path(), ec);
    const auto tmp = to.wstring() + L".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        out << j.dump();
    }
    fs::rename(tmp, to, ec);
    // %LOCALAPPDATA% is already private to the user on Windows; nothing more
    // to tighten, unlike the world-readable default on macOS.
}

}  // namespace nib::speech
