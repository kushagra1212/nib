#include "rewrite/rewrite_mode.hpp"

#include "text/unicode.hpp"

namespace nib::rewrite_mode {

const char16_t* raw_value(RewriteMode mode) {
    switch (mode) {
    case RewriteMode::fix_grammar: return u"Fix grammar";
    case RewriteMode::clearer:     return u"Make clearer";
    case RewriteMode::shorter:     return u"Make shorter";
    case RewriteMode::native:      return u"Native English";
    }
    return u"";
}

const char16_t* short_title(RewriteMode mode) {
    switch (mode) {
    case RewriteMode::fix_grammar: return u"Fix";
    case RewriteMode::clearer:     return u"Clearer";
    case RewriteMode::shorter:     return u"Shorter";
    case RewriteMode::native:      return u"Native";
    }
    return u"";
}

std::u16string badge(RewriteMode mode) {
    std::u16string out = short_title(mode);
    for (auto& c : out) {
        if (c >= u'a' && c <= u'z') c = static_cast<char16_t>(c - u'a' + u'A');
    }
    return out;
}

// The prompts are the Swift strings verbatim. Each one was measured against
// real sentences on Qwen3 -- see RewriteEngine.swift for what every clause
// bought and what removing it broke. Do not paraphrase them.
std::u16string instruction(RewriteMode mode) {
    switch (mode) {
    case RewriteMode::fix_grammar:
        return u"Correct the grammar, spelling, and punctuation of the user's text. "
               u"Keep the meaning and wording as close to the original as possible. "
               u"Split run-on sentences and comma splices.";
    case RewriteMode::clearer:
        return u"Rewrite the user's text to be clearer and easier to read. "
               u"Keep the same meaning and roughly the same length.";
    case RewriteMode::shorter:
        return u"Rewrite the user's text to be shorter, keeping every important point.";
    case RewriteMode::native:
        // The verb rule comes second, before the general instructions.
        // Placement is the whole change: appended at the end it was ignored.
        return u"Rewrite the user's text the way a native British English "
               u"speaker would naturally write it. Give every clause the "
               u"verb and preposition it needs, supplying the one the "
               u"sentence implies rather than dropping the clause. "
               u"Fix the grammar, replace "
               u"unidiomatic phrasing with what a native speaker would say, "
               u"and reorder or split sentences where that is more natural. "
               u"Keep every fact and every point the text makes. "
               u"Do not introduce a new fact, name or number that is not "
               u"already in the text.";
    }
    return {};
}

std::u16string system_prompt(RewriteMode mode) {
    return instruction(mode)
        + u" Rewrite as much as needed for it to read well."
        + u" Use British English spelling and idiom."
        + u" Reply with only the rewritten text."
        + u" Do not explain, comment, add quotes, or think out loud."
        + u" Leave code, identifiers, acronyms and proper nouns exactly as written.";
}

bool may_restructure(RewriteMode mode) {
    return mode != RewriteMode::fix_grammar;
}

}  // namespace nib::rewrite_mode
