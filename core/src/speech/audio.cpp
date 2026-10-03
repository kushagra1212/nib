#include "speech/audio.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <numeric>
#include <stdexcept>

namespace nib::speech::audio {

double duration(const std::vector<float>& samples, int rate) {
    return static_cast<double>(samples.size()) / rate;
}

float peak(const std::vector<float>& samples) {
    float p = 0;
    for (float s : samples) p = std::max(p, std::abs(s));
    return p;
}

bool silent(const std::vector<float>& samples) { return peak(samples) < silence_threshold; }

std::vector<float> to_mono(const std::vector<float>& interleaved, int channels) {
    if (channels <= 1) return interleaved;
    std::vector<float> out(interleaved.size() / static_cast<size_t>(channels));
    for (size_t i = 0; i < out.size(); ++i) {
        float sum = 0;
        for (int c = 0; c < channels; ++c) sum += interleaved[i * channels + c];
        out[i] = sum / channels;
    }
    return out;
}

std::vector<float> resample(const std::vector<float>& in, int from_rate, int to_rate) {
    if (from_rate == to_rate || in.empty()) return in;
    const double ratio = static_cast<double>(to_rate) / from_rate;
    const size_t out_len = static_cast<size_t>(std::floor(in.size() * ratio));
    std::vector<float> out(out_len);

    // Cut off just under the lower of the two Nyquist rates.
    const double cutoff = 0.95 * std::min(1.0, ratio);
    constexpr int half_taps = 16;
    const double scale = std::max(1.0, 1.0 / ratio);  // widen the kernel when shrinking
    const int reach = static_cast<int>(std::ceil(half_taps * scale));
    constexpr double pi = 3.14159265358979323846;

    for (size_t n = 0; n < out_len; ++n) {
        const double centre = n / ratio;
        const auto base = static_cast<long long>(std::floor(centre));
        double acc = 0, weight = 0;
        for (long long k = base - reach + 1; k <= base + reach; ++k) {
            if (k < 0 || k >= static_cast<long long>(in.size())) continue;
            const double x = (centre - k);
            // sinc low-pass times a Blackman window over the kernel's reach.
            const double arg = pi * x * cutoff;
            const double sinc = std::abs(x) < 1e-9 ? 1.0 : std::sin(arg) / arg;
            const double w = x / reach;
            if (std::abs(w) >= 1) continue;
            const double window = 0.42 + 0.5 * std::cos(pi * w) + 0.08 * std::cos(2 * pi * w);
            const double h = cutoff * sinc * window;
            acc += in[static_cast<size_t>(k)] * h;
            weight += h;
        }
        out[n] = weight != 0 ? static_cast<float>(acc / weight) : 0.f;
    }
    return out;
}

std::vector<float> load_wav(const std::filesystem::path& file, int target_rate) {
    std::ifstream in(file, std::ios::binary);
    if (!in) throw std::runtime_error("could not read audio at " + file.string());
    const std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    auto u32 = [&](size_t at) {
        uint32_t v = 0;
        std::memcpy(&v, data.data() + at, 4);
        return v;
    };
    auto u16 = [&](size_t at) {
        uint16_t v = 0;
        std::memcpy(&v, data.data() + at, 2);
        return v;
    };
    if (data.size() < 12 || data.compare(0, 4, "RIFF") != 0 || data.compare(8, 4, "WAVE") != 0) {
        throw std::runtime_error(file.filename().string() + " is not a WAV file");
    }
    int format = 0, channels = 0, rate = 0, bits = 0;
    size_t body = 0, body_len = 0;
    for (size_t at = 12; at + 8 <= data.size();) {
        const std::string id = data.substr(at, 4);
        const size_t len = u32(at + 4);
        if (id == "fmt " && at + 8 + 16 <= data.size()) {
            format = u16(at + 8);
            channels = u16(at + 10);
            rate = static_cast<int>(u32(at + 12));
            bits = u16(at + 22);
            if (format == 0xFFFE && len >= 40) format = u16(at + 8 + 24);  // extensible: sub-format
        } else if (id == "data") {
            body = at + 8;
            body_len = std::min(len, data.size() - body);
            break;
        }
        at += 8 + len + (len & 1);
    }
    if (!body || channels <= 0 || rate <= 0) throw std::runtime_error(file.filename().string() + " has no audio");

    std::vector<float> samples;
    const size_t bytes = static_cast<size_t>(bits / 8);
    if (bytes == 0) throw std::runtime_error("unsupported WAV bit depth");
    samples.reserve(body_len / bytes);
    for (size_t at = body; at + bytes <= body + body_len; at += bytes) {
        const char* p = data.data() + at;
        float v = 0;
        if (format == 3 && bits == 32) {
            std::memcpy(&v, p, 4);
        } else if (format == 1 && bits == 16) {
            int16_t s;
            std::memcpy(&s, p, 2);
            v = s / 32768.f;
        } else if (format == 1 && bits == 24) {
            int32_t s = (static_cast<uint8_t>(p[0])) | (static_cast<uint8_t>(p[1]) << 8) | (static_cast<int8_t>(p[2]) << 16);
            v = s / 8388608.f;
        } else if (format == 1 && bits == 32) {
            int32_t s;
            std::memcpy(&s, p, 4);
            v = static_cast<float>(s / 2147483648.0);
        } else {
            throw std::runtime_error("unsupported WAV format " + std::to_string(format) + "/" + std::to_string(bits));
        }
        samples.push_back(v);
    }
    return resample(to_mono(samples, channels), rate, target_rate);
}

void write_wav(const std::filesystem::path& file, const std::vector<float>& samples, int rate) {
    std::string out;
    auto put32 = [&](uint32_t v) { out.append(reinterpret_cast<const char*>(&v), 4); };
    auto put16 = [&](uint16_t v) { out.append(reinterpret_cast<const char*>(&v), 2); };
    const uint32_t payload = static_cast<uint32_t>(samples.size() * 2);
    out += "RIFF";
    put32(36 + payload);
    out += "WAVEfmt ";
    put32(16);
    put16(1);
    put16(1);
    put32(static_cast<uint32_t>(rate));
    put32(static_cast<uint32_t>(rate * 2));
    put16(2);
    put16(16);
    out += "data";
    put32(payload);
    for (float s : samples) {
        // Clamped before scaling: a float past 1.0 wraps to a loud click.
        const auto v = static_cast<int16_t>(std::clamp(s, -1.f, 1.f) * 32767.f);
        out.append(reinterpret_cast<const char*>(&v), 2);
    }
    const auto tmp = file.wstring() + L".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        f.write(out.data(), static_cast<std::streamsize>(out.size()));
        if (!f) throw std::runtime_error("could not write the recording");
    }
    std::error_code ec;
    std::filesystem::rename(tmp, file, ec);
    if (ec) throw std::runtime_error("could not write the recording: " + ec.message());
}

}  // namespace nib::speech::audio
