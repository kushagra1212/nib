// Kokoro inference, behind four functions.
//
// ONNX Runtime's C API is a struct of several hundred function pointers,
// reached through OrtGetApiBase(). Handing that to Swift would mean either
// importing the whole header into Swift or restating the struct by hand, where
// one member out of order is undefined behaviour rather than a compile error.
//
// So the API stays in C and Swift sees this instead: open a model, run it,
// free the samples, close it. The ONNX headers are private to this target.
//
// The library is opened with dlopen rather than linked, matching espeak. The
// build then works wherever Scripts/fetch-onnx.sh has not been run, and the
// absence is a message rather than a link error.

#ifndef KOKORO_SHIM_H
#define KOKORO_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kokoro_session kokoro_session;

/// Length of the buffer every call writes its error into.
#define KOKORO_ERROR_MAX 512

/// Loads ONNX Runtime and opens a model.
///
/// `library_path` is libonnxruntime.dylib; `model_path` is kokoro-v1.0.onnx.
///
/// `intra_op_threads` is not a tuning knob to leave at a default. It changes
/// the order floating-point reductions happen in, so it changes the samples --
/// the same input at 2 threads and at 4 produces different audio. Identical to
/// the ear, but not to a hash, which is why the fixture records the count it
/// was captured with.
///
/// Returns NULL and fills `error` on failure.
kokoro_session *kokoro_open(const char *library_path,
                            const char *model_path,
                            int intra_op_threads,
                            char *error);

/// Runs one batch.
///
/// `tokens` are phoneme ids without the padding zeros -- those are added here,
/// because the model expects a zero at each end and forgetting one shortens
/// every utterance by a phoneme.
///
/// `style` is 256 floats from the voice pack, chosen by token count.
///
/// On success writes a newly allocated buffer to `samples` and its length to
/// `count`, and returns 0. The caller frees it with kokoro_free_samples.
/// On failure returns non-zero and fills `error`.
int kokoro_run(kokoro_session *session,
               const int64_t *tokens, size_t token_count,
               const float *style, size_t style_count,
               float speed,
               float **samples, size_t *count,
               char *error);

void kokoro_free_samples(float *samples);

void kokoro_close(kokoro_session *session);

/// The runtime's version string, for reporting what was actually loaded.
/// Valid until the session is closed.
const char *kokoro_runtime_version(kokoro_session *session);

/// Which name the model uses for its token input.
///
/// Newer exports call it "input_ids" and older ones "tokens". Reported so a
/// model that uses neither fails with something readable.
const char *kokoro_token_input_name(kokoro_session *session);

#ifdef __cplusplus
}
#endif

#endif
