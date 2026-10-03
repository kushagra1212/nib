#pragma once
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <optional>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace nib::speech {

struct SpeechError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// Port of NumpyLayout: the shape of one .npy array and where its numbers
// begin. Every field is checked -- big-endian, float64 and column-major all
// read as 256 plausible floats, and none of them would fail on its own.
struct NumpyLayout {
    std::vector<int64_t> shape;
    size_t data_offset = 0;

    int64_t rows() const { return shape.empty() ? 0 : shape.front(); }
    int64_t elements_per_row() const;

    // Throws SpeechError.
    static NumpyLayout parse(const std::string& blob);
};

// Port of ZipDirectory: the central directory of a stored (uncompressed) zip,
// enough to seek straight to one member's bytes.
namespace zip {
struct Entry {
    std::string name;
    int32_t method = 0;
    int64_t compressed_size = 0;
    int64_t uncompressed_size = 0;
    int64_t local_header_offset = 0;
    bool stored() const { return method == 0; }
};
std::vector<Entry> entries(const std::filesystem::path& file);
int64_t data_offset(const Entry& entry, std::ifstream& in);
}  // namespace zip

// Port of VoicePack: the 54 voices in one 28MB archive, read a row at a time.
// A style is a seek and a 1KB read; nothing here loads the file.
class VoicePack {
public:
    explicit VoicePack(const std::filesystem::path& file);

    const std::vector<std::string>& names() const { return names_; }
    bool stored() const { return stored_; }

    // The 256 numbers for this voice at this sentence length: row
    // min(tokens, rows) - 1, as kokoro_onnx reads it. The neighbouring row is
    // not an error, it is slightly wrong intonation -- so this is exact.
    std::vector<float> style(const std::string& voice, int32_t token_count) const;

private:
    struct Entry {
        int64_t data_offset;
        int64_t rows;
        int64_t elements_per_row;
    };
    std::filesystem::path file_;
    std::map<std::string, Entry> entries_;
    std::vector<std::string> names_;
    bool stored_ = true;
};

}  // namespace nib::speech
