#include "lint/suggestion.hpp"

#include <algorithm>
#include <atomic>
#include <nlohmann/json.hpp>

namespace nib {

uint64_t Suggestion::next_id() {
    static std::atomic<uint64_t> counter{1};
    return counter.fetch_add(1, std::memory_order_relaxed);
}

std::optional<std::u16string> Suggestion::excerpt(const std::u16string& text) const {
    const int32_t n = static_cast<int32_t>(text.size());
    if (range.location < 0 || range.length < 0 || range_end(range) > n) {
        return std::nullopt;
    }
    return text.substr(static_cast<size_t>(range.location),
                       static_cast<size_t>(range.length));
}

PositionMapper::PositionMapper(const std::u16string& text) {
    line_starts_.push_back(0);
    int32_t offset = 0;
    for (char16_t unit : text) {
        ++offset;
        if (unit == u'\n') line_starts_.push_back(offset);
    }
    length_ = offset;
}

int32_t PositionMapper::offset(int32_t line, int32_t character) const {
    if (line < 0) return 0;
    if (line >= static_cast<int32_t>(line_starts_.size())) return length_;

    const int32_t start = line_starts_[static_cast<size_t>(line)];
    // A line ends just before the next line's start, which is the newline
    // itself; the last line runs to the end of the text.
    const int32_t end = line + 1 < static_cast<int32_t>(line_starts_.size())
        ? std::max(start, line_starts_[static_cast<size_t>(line) + 1] - 1)
        : length_;
    return std::min(start + std::max(0, character), end);
}

std::optional<nib_range> PositionMapper::range(const nlohmann::json& lsp) const {
    if (!lsp.is_object()) return std::nullopt;
    const auto start = lsp.find("start");
    const auto end = lsp.find("end");
    if (start == lsp.end() || end == lsp.end()
        || !start->is_object() || !end->is_object()) {
        return std::nullopt;
    }
    auto integer = [](const nlohmann::json& o, const char* key) -> std::optional<int32_t> {
        const auto it = o.find(key);
        if (it == o.end() || !it->is_number_integer()) return std::nullopt;
        return it->get<int32_t>();
    };
    const auto sl = integer(*start, "line"), sc = integer(*start, "character");
    const auto el = integer(*end, "line"), ec = integer(*end, "character");
    if (!sl || !sc || !el || !ec) return std::nullopt;

    const int32_t from = offset(*sl, *sc);
    const int32_t to = offset(*el, *ec);
    if (to < from || to > length_) return std::nullopt;
    return nib_range{from, to - from};
}

}  // namespace nib
