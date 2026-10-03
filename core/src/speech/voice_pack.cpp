#include "speech/voice_pack.hpp"

#include <algorithm>
#include <cstring>
#include <fstream>

namespace nib::speech {
namespace {

std::string read(std::ifstream& in, int64_t offset, int64_t count, const char* what) {
    if (offset < 0 || count < 0) throw SpeechError(std::string("the archive ends in the middle of ") + what);
    in.clear();
    in.seekg(offset);
    std::string data(static_cast<size_t>(count), '\0');
    in.read(data.data(), count);
    if (in.gcount() != count) throw SpeechError(std::string("the archive ends in the middle of ") + what);
    return data;
}

int64_t le(const std::string& d, size_t at, int bytes) {
    if (at + static_cast<size_t>(bytes) > d.size()) return -1;
    int64_t v = 0;
    for (int i = 0; i < bytes; ++i) v |= static_cast<int64_t>(static_cast<uint8_t>(d[at + i])) << (8 * i);
    return v;
}

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) --b;
    return s.substr(a, b - a);
}

// The value against 'key':, up to the comma that ends it; bracket depth is
// tracked because a shape's own commas do not end the field.
std::optional<std::string> field(const std::string& header, const std::string& key) {
    const auto at = header.find("'" + key + "':");
    if (at == std::string::npos) return std::nullopt;
    int depth = 0;
    std::string value;
    for (size_t i = at + key.size() + 3; i < header.size(); ++i) {
        const char c = header[i];
        if (depth == 0 && (c == ',' || c == '}')) break;
        if (c == '(' || c == '[') ++depth;
        if (c == ')' || c == ']') --depth;
        value.push_back(c);
    }
    return trim(value);
}

}  // namespace

int64_t NumpyLayout::elements_per_row() const {
    int64_t n = 1;
    for (size_t i = 1; i < shape.size(); ++i) n *= shape[i];
    return n;
}

NumpyLayout NumpyLayout::parse(const std::string& blob) {
    static const std::string magic = "\x93NUMPY";
    if (blob.size() <= 10 || blob.compare(0, 6, magic) != 0) {
        throw SpeechError("not a numpy array: the file does not start with \\x93NUMPY");
    }
    const auto major = static_cast<uint8_t>(blob[6]);
    const size_t length_bytes = major >= 2 ? 4 : 2;
    const size_t header_start = 8 + length_bytes;
    if (blob.size() < header_start) throw SpeechError("the numpy header is cut short");
    const auto length = static_cast<size_t>(le(blob, 8, static_cast<int>(length_bytes)));
    if (blob.size() < header_start + length) throw SpeechError("the numpy header is cut short");
    const std::string header = blob.substr(header_start, length);

    const auto descr = field(header, "descr");
    if (!descr) throw SpeechError("the numpy header has no 'descr'");
    if (*descr != "'<f4'") {
        throw SpeechError("numpy type " + *descr + " is not supported here; the voice pack should be "
                          "'<f4', little-endian float32");
    }
    const auto order = field(header, "fortran_order");
    if (!order) throw SpeechError("the numpy header has no 'fortran_order'");
    if (*order != "False") throw SpeechError("the array is column-major, and this reads rows");
    const auto shape_text = field(header, "shape");
    if (!shape_text) throw SpeechError("the numpy header has no 'shape'");

    NumpyLayout layout;
    std::string inner;
    for (char c : *shape_text) {
        if (c != '(' && c != ')' && c != '[' && c != ']') inner.push_back(c);
    }
    size_t start = 0;
    for (;;) {
        const size_t comma = inner.find(',', start);
        const auto part = trim(inner.substr(start, comma == std::string::npos ? std::string::npos : comma - start));
        if (!part.empty()) {
            char* end = nullptr;
            const long long v = std::strtoll(part.c_str(), &end, 10);
            if (*end != '\0' || v <= 0) throw SpeechError("cannot read the numpy shape " + *shape_text);
            layout.shape.push_back(v);
        }
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    if (layout.shape.empty()) throw SpeechError("cannot read the numpy shape " + *shape_text);
    layout.data_offset = header_start + length;
    return layout;
}

namespace zip {

std::vector<Entry> entries(const std::filesystem::path& file) {
    std::ifstream in(file, std::ios::binary);
    if (!in) throw SpeechError("cannot open " + file.string());
    in.seekg(0, std::ios::end);
    const int64_t size = in.tellg();
    const int64_t tail_length = std::min<int64_t>(size, 22 + 0xFFFF);
    const std::string tail = read(in, size - tail_length, tail_length, "the end of the archive");

    int64_t end = -1;
    for (int64_t at = static_cast<int64_t>(tail.size()) - 22; at >= 0; --at) {
        if (le(tail, static_cast<size_t>(at), 4) == 0x06054B50) {
            end = at;
            break;
        }
    }
    if (end < 0) throw SpeechError("not a zip archive: no end-of-central-directory record");
    const int64_t count = le(tail, static_cast<size_t>(end) + 10, 2);
    const int64_t dir_size = le(tail, static_cast<size_t>(end) + 12, 4);
    const int64_t dir_offset = le(tail, static_cast<size_t>(end) + 16, 4);
    if (dir_offset == 0xFFFFFFFF || dir_size == 0xFFFFFFFF) {
        throw SpeechError("zip64 archives are not read here");
    }
    const std::string dir = read(in, dir_offset, dir_size, "the central directory");

    std::vector<Entry> out;
    size_t cursor = 0;
    while (static_cast<int64_t>(out.size()) < count) {
        if (cursor + 46 > dir.size() || le(dir, cursor, 4) != 0x02014B50) {
            throw SpeechError("the archive ends in the middle of the central directory");
        }
        const auto name_length = static_cast<size_t>(le(dir, cursor + 28, 2));
        const auto extra_length = static_cast<size_t>(le(dir, cursor + 30, 2));
        const auto comment_length = static_cast<size_t>(le(dir, cursor + 32, 2));
        if (cursor + 46 + name_length > dir.size()) throw SpeechError("the archive ends in the middle of an entry name");
        Entry e;
        e.name = dir.substr(cursor + 46, name_length);
        e.method = static_cast<int32_t>(le(dir, cursor + 10, 2));
        e.compressed_size = le(dir, cursor + 20, 4);
        e.uncompressed_size = le(dir, cursor + 24, 4);
        e.local_header_offset = le(dir, cursor + 42, 4);
        out.push_back(std::move(e));
        cursor += 46 + name_length + extra_length + comment_length;
    }
    return out;
}

int64_t data_offset(const Entry& entry, std::ifstream& in) {
    const std::string header = read(in, entry.local_header_offset, 30, "a local file header");
    if (le(header, 0, 4) != 0x04034B50) throw SpeechError("the archive ends in the middle of a local file header");
    return entry.local_header_offset + 30 + le(header, 26, 2) + le(header, 28, 2);
}

}  // namespace zip

VoicePack::VoicePack(const std::filesystem::path& file) : file_(file) {
    std::vector<zip::Entry> members;
    for (auto& e : zip::entries(file)) {
        if (e.name.size() > 4 && e.name.compare(e.name.size() - 4, 4, ".npy") == 0) members.push_back(e);
    }
    if (members.empty()) throw SpeechError("no voices in " + file.filename().string());

    std::ifstream in(file, std::ios::binary);
    for (const auto& m : members) {
        if (!m.stored()) {
            throw SpeechError(m.name + " is compressed (method " + std::to_string(m.method)
                              + ") and this reads stored entries only");
        }
        // Every header now: a malformed entry should fail at load, not halfway
        // through speaking a sentence.
        const int64_t start = zip::data_offset(m, in);
        const auto layout = NumpyLayout::parse(read(in, start, std::min<int64_t>(512, m.compressed_size), "a numpy header"));
        const auto name = m.name.substr(0, m.name.size() - 4);
        entries_[name] = {start + static_cast<int64_t>(layout.data_offset), layout.rows(), layout.elements_per_row()};
    }
    for (const auto& [name, entry] : entries_) names_.push_back(name);
}

std::vector<float> VoicePack::style(const std::string& voice, int32_t token_count) const {
    if (token_count <= 0) throw SpeechError("no tokens to speak, so there is no style to choose");
    const auto it = entries_.find(voice);
    if (it == entries_.end()) {
        throw SpeechError("no voice named " + voice + " in the pack, which has " + std::to_string(entries_.size()));
    }
    const auto& e = it->second;
    const int64_t row = std::min<int64_t>(token_count, e.rows) - 1;
    std::ifstream in(file_, std::ios::binary);
    const auto data = read(in, e.data_offset + row * e.elements_per_row * 4, e.elements_per_row * 4,
                           "the style for a voice");
    std::vector<float> out(static_cast<size_t>(e.elements_per_row));
    // Byte by byte: zip offsets are not aligned.
    for (size_t i = 0; i < out.size(); ++i) {
        uint32_t bits = 0;
        for (int b = 0; b < 4; ++b) bits |= static_cast<uint32_t>(static_cast<uint8_t>(data[i * 4 + b])) << (8 * b);
        std::memcpy(&out[i], &bits, 4);
    }
    return out;
}

}  // namespace nib::speech
