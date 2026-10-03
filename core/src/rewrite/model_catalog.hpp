#pragma once
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>
#include "rewrite/rewrite_engine.hpp"

namespace nib {

// Port of ModelCatalog: a short list of models that have been run against
// nib's own prompts, rather than a browser over everything on Hugging Face.
struct CatalogModel {
    std::string filename;  // on disk; also what rank_models reads
    std::u16string title;
    std::u16string detail;
    int64_t bytes = 0;
    std::string url;       // https://, or a local path for "Choose File..."

    std::u16string size_label() const;
    friend bool operator==(const CatalogModel& a, const CatalogModel& b) {
        return a.filename == b.filename && a.url == b.url && a.bytes == b.bytes;
    }
};

namespace model_catalog {

// Smallest first, which is also roughly worst first. Sizes are the real byte
// counts from Hugging Face, so the figure before the download matches during.
const std::vector<CatalogModel>& all();
// The 4B: the 0.6B is a comma inserter on real writing.
const CatalogModel& recommended();
const CatalogModel& compact();

// A file the user picked, wrapped so it takes the same path as a download.
CatalogModel local(const std::filesystem::path& file);

std::filesystem::path install_directory();

}  // namespace model_catalog

// Ranks installed model filenames best-first. 0.6B is the floor for this task;
// a 270M answers the wrong question and is only used when nothing else is.
std::vector<std::string> rank_models(std::vector<std::string> names);

// The best installed model, searching the install folder then a development
// checkout's models\. An explicit absolute path or a filename overrides.
std::optional<std::filesystem::path> find_model(const std::string& requested = {});

// llama-server.exe and the DLLs it loads travel together; the directory is
// the unit, so a candidate is only real if the libraries came with it.
std::optional<std::filesystem::path> locate_llama_server();
std::optional<std::filesystem::path> locate_harper();

// A rewrite configuration, or nullopt if the server or a model is missing.
std::optional<RewriteEngine::Config> rewrite_config(const std::string& requested = {});

// Port of ModelInstaller: downloads a model and proves it works before calling
// itself done. A file of the right size is not a working rewrite -- it can be
// an error page, a captive portal, or a GGUF this llama.cpp cannot read.
class ModelInstaller {
public:
    struct Stage {
        enum class Kind { idle, downloading, verifying, done, failed, cancelled };
        Kind kind = Kind::idle;
        double fraction = 0;
        int64_t received = 0;
        int64_t total = 0;
        std::filesystem::path installed;  // done
        std::u16string message;           // failed
    };

    // Called on the installer's thread for every change.
    std::function<void(const Stage&)> on_change;

    explicit ModelInstaller(std::filesystem::path destination = model_catalog::install_directory(),
                            bool verifies = true);
    ~ModelInstaller();

    void start(const CatalogModel& model);
    void cancel();
    void reset();
    bool busy() const;
    Stage stage() const;

    // Refuses a download that cannot fit: both the temporary and the final
    // copy can exist at the moment of the move, so twice the size plus margin.
    static std::optional<std::u16string> space_problem(const CatalogModel& model,
                                                       std::optional<uint64_t> free_bytes);

private:
    void run(CatalogModel model);
    void set(Stage stage);
    void fail(std::u16string message);

    std::filesystem::path destination_;
    bool verifies_;
    mutable std::mutex lock_;
    Stage stage_;
    std::atomic<bool> cancel_{false};
    std::thread worker_;
};

}  // namespace nib
