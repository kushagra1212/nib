#include "text/sentence_split.hpp"
#include <memory>
#include <unicode/brkiter.h>
#include <unicode/uchar.h>
#include <unicode/unistr.h>
#include "text/word_tokenize.hpp"

namespace nib {
namespace {

// enumerateSubstrings(.bySentences, .localized) is ICU's sentence
// BreakIterator plus CLDR's abbreviation exceptions. The iterator alone is not
// enough: it breaks after "Dr." and Foundation does not, so a clarity mark
// would cover half a sentence on one platform and all of it on the other.
//
// The exceptions are listed here rather than loaded from the locale because
// the data is not reliably present. Apple's ICU carries it; Homebrew's ICU 78
// does not, and every locale there answers U_USING_DEFAULT_WARNING with no
// suppressions at all. A list that ships with the source is identical on macOS
// and Windows no matter how either platform's ICU was built, which is the
// whole reason the core exists.
//
// Derived by asking Foundation, not by guessing: 266 candidate abbreviations
// were put through enumerateSubstrings and these 62 are the ones it declined
// to break after. The gaps are CLDR's, not typos -- "Mar." is here and "Apr."
// is not, "a.m." is here and "p.m." is not. Reproducing the list means
// reproducing its inconsistencies.
//
// English only. harper is English-only and so are the rewrite prompts, so this
// matches what nib actually does; a German user gets plain ICU behaviour, and
// gets it identically on both platforms.
const char* const kSentenceBreakExceptions[] = {
    "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Rev.", "Rep.", "Col.", "Maj.",
    "Capt.", "Lt.", "Sgt.", "Dept.", "Ph.D.", "M.D.", "B.A.", "M.A.", "J.D.",
    "LL.B.", "D.D.S.", "e.g.", "i.e.", "vs.", "N.B.", "a.m.", "A.M.", "P.M.",
    "U.S.", "U.K.", "U.S.A.", "E.U.", "Sq.", "Mt.", "Is.", "Jan.", "Feb.",
    "Mar.", "Jun.", "Aug.", "Sep.", "Sept.", "Nov.", "Dec.", "Fri.", "pp.",
    "Cap.", "Conn.", "Md.", "Ex.", "Lev.", "Num.", "Est.", "Jam.", "Alt.",
    "Misc.", "P.O.", "L.P.", "Long.", "Mgr.", "Var.", "Card.", "MR.",
};

bool is_whitespace(uint16_t unit) {
    const UChar32 c = static_cast<UChar32>(unit);
    return u_isUWhiteSpace(c) || c == u'\n' || c == u'\r';
}

// Shrinks a range to exclude leading and trailing whitespace, so a clarity
// mark does not extend across the blank space after a sentence.
bool tighten(u16view text, int32_t location, int32_t length, nib_range* out) {
    int32_t start = location;
    int32_t end = location + length;
    while (start < end && is_whitespace(text[start])) ++start;
    while (end > start && is_whitespace(text[end - 1])) --end;
    if (end <= start) return false;
    *out = nib_range{start, end - start};
    return true;
}

// The exceptions are applied here rather than through ICU's
// FilteredBreakIteratorBuilder, which does not do the job.
//
// Measured on ICU 78: suppressBreakAfter reports success for every entry, then
// suppresses only the single-period ones. "Dr." works; "e.g.", "i.e.", "a.m.",
// "U.S." and "Ph.D." all still break, because the abbreviations that matter
// most here contain interior periods. Building on that would be building on a
// quirk, and one that could be fixed upstream and change nib's output.
//
// Filtering the boundaries directly is a dozen lines, depends on nothing, and
// behaves the same on every ICU build.
bool ends_with_exception(u16view text, int32_t boundary) {
    // Trailing whitespace sits between the abbreviation and the boundary.
    int32_t end = boundary;
    while (end > 0 && is_whitespace(text[end - 1])) --end;
    if (end == 0) return false;

    for (const char* exception : kSentenceBreakExceptions) {
        const icu::UnicodeString pattern = icu::UnicodeString::fromUTF8(exception);
        const int32_t length = pattern.length();
        if (length > end) continue;

        const int32_t start = end - length;
        bool same = true;
        for (int32_t i = 0; i < length && same; ++i) {
            same = text[start + i] == static_cast<uint16_t>(pattern.charAt(i));
        }
        if (!same) continue;

        // "Dr." must not match inside "Mandr.". The character before the match
        // has to be a separator, exactly as it would be for a whole token.
        if (start > 0) {
            const UChar32 before = static_cast<UChar32>(text[start - 1]);
            if (u_isalnum(before)) continue;
        }
        return true;
    }
    return false;
}

}  // namespace

std::vector<Sentence> sentences(u16view text, int32_t minimum_words,
                                const char* locale) {
    std::vector<Sentence> found;
    if (text.empty()) return found;

    UErrorCode status = U_ZERO_ERROR;
    const icu::Locale where = locale ? icu::Locale(locale) : icu::Locale::getDefault();
    std::unique_ptr<icu::BreakIterator> it(
        icu::BreakIterator::createSentenceInstance(where, status));
    if (U_FAILURE(status) || !it) return found;

    // setText borrows, so the UnicodeString has to outlive the iteration and
    // cannot be a temporary.
    const icu::UnicodeString subject(
        false, reinterpret_cast<const char16_t*>(text.data), text.size);
    it->setText(subject);

    // A boundary that follows an abbreviation is dropped, which merges that
    // span into the next one -- so the sentence runs on, as Foundation's does.
    int32_t start = it->first();
    for (int32_t end = it->next(); end != icu::BreakIterator::DONE; end = it->next()) {
        if (end < text.size && ends_with_exception(text, end)) continue;

        nib_range tight{};
        const bool usable = tighten(text, start, end - start, &tight);
        start = end;
        if (!usable) continue;

        const u16view slice = text.slice(tight.location, tight.length);
        if (static_cast<int32_t>(tokenize(slice).size()) < minimum_words) continue;

        found.push_back(Sentence{slice.to_string(), tight});
    }
    return found;
}

}  // namespace nib
