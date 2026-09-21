#include <algorithm>
#include <cstring>
#include <vector>
#include "nib/nib_core.h"
#include "text/sentence_split.hpp"

// The handle owns its sentences outright. Returning pointers into a vector
// that the caller might outlive is the classic way to make an ABI crash three
// calls later in someone else's code.
struct nib_sentence_list {
    std::vector<nib::Sentence> items;
};

extern "C" {

nib_sentence_list* nib_sentences(const uint16_t* text, int32_t length,
                                 int32_t minimum_words, const char* locale) {
    auto* list = new nib_sentence_list();
    if (text != nullptr && length > 0) {
        list->items = nib::sentences(nib::u16view(text, length),
                                     minimum_words, locale);
    }
    return list;
}

int32_t nib_sentence_count(const nib_sentence_list* list) {
    return list ? static_cast<int32_t>(list->items.size()) : 0;
}

nib_range nib_sentence_range(const nib_sentence_list* list, int32_t index) {
    if (!list || index < 0 || index >= static_cast<int32_t>(list->items.size())) {
        return nib_range{0, 0};
    }
    return list->items[static_cast<size_t>(index)].range;
}

int32_t nib_sentence_text(const nib_sentence_list* list, int32_t index,
                          uint16_t* buffer, int32_t capacity) {
    if (!list || index < 0 || index >= static_cast<int32_t>(list->items.size())) {
        return 0;
    }
    const auto& text = list->items[static_cast<size_t>(index)].text;
    const int32_t length = static_cast<int32_t>(text.size());
    if (buffer && capacity > 0) {
        // Short buffers are filled as far as they go, and the full length is
        // still reported, so a caller that guessed low retries instead of
        // silently shipping a truncated sentence.
        const int32_t n = std::min(length, capacity);
        std::memcpy(buffer, text.data(), static_cast<size_t>(n) * sizeof(uint16_t));
    }
    return length;
}

void nib_sentence_list_free(nib_sentence_list* list) {
    delete list;
}

}  // extern "C"
