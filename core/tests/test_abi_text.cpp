#include <catch2/catch_test_macros.hpp>
#include <string>
#include <vector>
#include "nib/nib_core.h"

namespace {

nib_str str_of(const std::u16string& s) {
    return nib_str{reinterpret_cast<const uint16_t*>(s.data()),
                   static_cast<int32_t>(s.size())};
}

std::u16string text_at(const nib_sentence_list* list, int32_t index) {
    const int32_t length = nib_sentence_text(list, index, nullptr, 0);
    std::u16string out(static_cast<size_t>(length), u'\0');
    if (length > 0) {
        nib_sentence_text(list, index, reinterpret_cast<uint16_t*>(out.data()), length);
    }
    return out;
}

}  // namespace

// The ABI hands back an opaque handle the caller drains and then frees. This
// avoids the two traps: returning a pointer into a C++ container that moves,
// and making the caller guess a buffer size up front.
TEST_CASE("the ABI returns sentences and frees them") {
    const std::u16string text =
        u"The quick brown fox jumps over it. Another long sentence follows here.";

    nib_sentence_list* list = nib_sentences(str_of(text), 5, "en_IN");
    REQUIRE(list != nullptr);
    REQUIRE(nib_sentence_count(list) == 2);

    const nib_range first = nib_sentence_range(list, 0);
    CHECK(first.location == 0);
    CHECK(first.length == 34);
    CHECK(text_at(list, 0) == u"The quick brown fox jumps over it.");

    const nib_range second = nib_sentence_range(list, 1);
    CHECK(second.location >= first.location + first.length);
    CHECK(text_at(list, 1) == u"Another long sentence follows here.");

    nib_sentence_list_free(list);
}

// The handle owns its copies, so the caller may drop the input immediately.
// Checked rather than assumed, because the failure would be a use-after-free
// that appears somewhere else entirely.
TEST_CASE("the list does not borrow the input buffer") {
    nib_sentence_list* list = nullptr;
    {
        const std::u16string scoped =
            u"The quick brown fox jumps over it. Another long sentence follows here.";
        list = nib_sentences(str_of(scoped), 5, "en_IN");
    }
    REQUIRE(nib_sentence_count(list) == 2);
    CHECK(text_at(list, 0) == u"The quick brown fox jumps over it.");
    nib_sentence_list_free(list);
}

TEST_CASE("sizing with a null buffer reports the full length") {
    const std::u16string text = u"The quick brown fox jumps over it.";
    nib_sentence_list* list = nib_sentences(str_of(text), 5, "en_IN");

    const int32_t length = nib_sentence_text(list, 0, nullptr, 0);
    CHECK(length == 34);

    // A short buffer is filled as far as it goes and still reports the whole
    // length, so a caller that guessed low can retry rather than truncate
    // silently.
    std::vector<uint16_t> small(10, 0);
    CHECK(nib_sentence_text(list, 0, small.data(), 10) == 34);
    CHECK(std::u16string(small.begin(), small.end()) == u"The quick ");

    nib_sentence_list_free(list);
}

TEST_CASE("an out-of-bounds index returns an empty range rather than crashing") {
    const std::u16string text = u"The quick brown fox jumps over it.";
    nib_sentence_list* list = nib_sentences(str_of(text), 5, "en_IN");

    const nib_range out = nib_sentence_range(list, 99);
    CHECK(out.location == 0);
    CHECK(out.length == 0);
    CHECK(nib_sentence_text(list, 99, nullptr, 0) == 0);
    CHECK(nib_sentence_text(list, -1, nullptr, 0) == 0);

    nib_sentence_list_free(list);
}

TEST_CASE("a null or empty input yields an empty list, not a null handle") {
    nib_sentence_list* empty = nib_sentences(nib_str{nullptr, 0}, 5, "en_IN");
    REQUIRE(empty != nullptr);
    CHECK(nib_sentence_count(empty) == 0);
    nib_sentence_list_free(empty);
}

TEST_CASE("freeing null is safe") {
    nib_sentence_list_free(nullptr);
    CHECK(nib_sentence_count(nullptr) == 0);
    SUCCEED();
}
