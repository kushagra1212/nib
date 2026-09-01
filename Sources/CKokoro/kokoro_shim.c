#include "include/kokoro_shim.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "onnxruntime/onnxruntime_c_api.h"

struct kokoro_session {
    void *library;
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory;
    char token_input[64];
    char version[32];
};

static void say(char *error, const char *format, ...) {
    if (!error) return;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(error, KOKORO_ERROR_MAX, format, arguments);
    va_end(arguments);
}

/// Turns an OrtStatus into a message and releases it.
///
/// Every ONNX call returns one of these, and NULL means success. Ignoring it
/// is the classic way to end up with a session pointer that was never set.
static int failed(const OrtApi *api, OrtStatus *status, char *error,
                  const char *what) {
    if (!status) return 0;
    say(error, "%s: %s", what, api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    return 1;
}

kokoro_session *kokoro_open(const char *library_path, const char *model_path,
                            int intra_op_threads, char *error) {
    void *library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        say(error, "cannot load %s: %s", library_path, dlerror());
        return NULL;
    }

    const OrtApiBase *(*get_api_base)(void) =
        (const OrtApiBase *(*)(void))dlsym(library, "OrtGetApiBase");
    if (!get_api_base) {
        say(error, "OrtGetApiBase is not in %s", library_path);
        dlclose(library);
        return NULL;
    }

    const OrtApiBase *base = get_api_base();
    // Asking for the version this was compiled against. A runtime too old to
    // provide it returns NULL rather than a struct with missing members, which
    // is the difference between an error and a crash months later.
    const OrtApi *api = base->GetApi(ORT_API_VERSION);
    if (!api) {
        say(error, "onnxruntime %s is too old; this needs API version %d",
            base->GetVersionString(), ORT_API_VERSION);
        dlclose(library);
        return NULL;
    }

    kokoro_session *session = calloc(1, sizeof(kokoro_session));
    if (!session) {
        say(error, "out of memory");
        dlclose(library);
        return NULL;
    }
    session->library = library;
    session->api = api;
    snprintf(session->version, sizeof(session->version), "%s",
             base->GetVersionString());

    // ORT_LOGGING_LEVEL_ERROR, not WARNING: the default prints a paragraph
    // about unused initialisers to stderr on every load.
    if (failed(api, api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "nib", &session->env),
               error, "creating the onnx environment")) {
        goto fail;
    }

    OrtSessionOptions *options = NULL;
    if (failed(api, api->CreateSessionOptions(&options), error,
               "creating session options")) {
        goto fail;
    }
    // Chosen by the caller, and it matters twice over: it decides how much of
    // the machine speaking costs, and it decides the exact samples.
    //
    // Both calls return a status. Ignoring it would leave the defaults in
    // place silently, so a failure to set them is reported like any other.
    if (failed(api, api->SetIntraOpNumThreads(options, intra_op_threads), error,
               "limiting threads")) {
        api->ReleaseSessionOptions(options);
        goto fail;
    }
    if (failed(api, api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL),
               error, "setting the optimisation level")) {
        api->ReleaseSessionOptions(options);
        goto fail;
    }

    OrtStatus *status = api->CreateSession(session->env, model_path, options,
                                           &session->session);
    api->ReleaseSessionOptions(options);
    if (failed(api, status, error, "opening the model")) {
        goto fail;
    }

    if (failed(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault,
                                             &session->memory),
               error, "describing memory")) {
        goto fail;
    }

    // Older exports call the token input "tokens", newer ones "input_ids".
    // Read from the model rather than guessed, because guessing wrong is an
    // error at every synthesis rather than at load.
    OrtAllocator *allocator = NULL;
    if (failed(api, api->GetAllocatorWithDefaultOptions(&allocator), error,
               "getting an allocator")) {
        goto fail;
    }

    size_t inputs = 0;
    if (failed(api, api->SessionGetInputCount(session->session, &inputs), error,
               "counting model inputs")) {
        goto fail;
    }

    session->token_input[0] = '\0';
    for (size_t index = 0; index < inputs; index++) {
        char *name = NULL;
        if (failed(api, api->SessionGetInputName(session->session, index,
                                                 allocator, &name),
                   error, "reading an input name")) {
            goto fail;
        }
        if (strcmp(name, "input_ids") == 0 || strcmp(name, "tokens") == 0) {
            snprintf(session->token_input, sizeof(session->token_input), "%s", name);
        }
        allocator->Free(allocator, name);
    }

    if (session->token_input[0] == '\0') {
        say(error, "the model has no input called input_ids or tokens; "
                   "it may not be a Kokoro export");
        goto fail;
    }

    return session;

fail:
    kokoro_close(session);
    return NULL;
}

int kokoro_run(kokoro_session *session,
               const int64_t *tokens, size_t token_count,
               const float *style, size_t style_count,
               float speed,
               float **samples, size_t *count,
               char *error) {
    if (!session || !session->session) {
        say(error, "the model is not open");
        return 1;
    }

    const OrtApi *api = session->api;

    // A zero at each end. The model was trained with them and without them
    // every utterance loses its first and last phoneme -- which sounds like a
    // clipped recording rather than a missing input.
    size_t padded_count = token_count + 2;
    int64_t *padded = calloc(padded_count, sizeof(int64_t));
    if (!padded) {
        say(error, "out of memory");
        return 1;
    }
    memcpy(padded + 1, tokens, token_count * sizeof(int64_t));

    OrtValue *token_value = NULL;
    OrtValue *style_value = NULL;
    OrtValue *speed_value = NULL;
    OrtValue *output = NULL;
    int result = 1;

    const int64_t token_shape[2] = {1, (int64_t)padded_count};
    if (failed(api, api->CreateTensorWithDataAsOrtValue(
                        session->memory, padded,
                        padded_count * sizeof(int64_t), token_shape, 2,
                        ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &token_value),
               error, "building the token tensor")) {
        goto done;
    }

    const int64_t style_shape[2] = {1, (int64_t)style_count};
    if (failed(api, api->CreateTensorWithDataAsOrtValue(
                        session->memory, (void *)style,
                        style_count * sizeof(float), style_shape, 2,
                        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &style_value),
               error, "building the style tensor")) {
        goto done;
    }

    const int64_t speed_shape[1] = {1};
    if (failed(api, api->CreateTensorWithDataAsOrtValue(
                        session->memory, &speed, sizeof(float), speed_shape, 1,
                        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &speed_value),
               error, "building the speed tensor")) {
        goto done;
    }

    const char *input_names[3] = {session->token_input, "style", "speed"};
    const OrtValue *input_values[3] = {token_value, style_value, speed_value};
    const char *output_names[1] = {"waveform"};

    // The first output whatever it is called. Kokoro exports name it
    // "waveform", but asking by name would fail on an export that does not.
    OrtAllocator *allocator = NULL;
    char *first_output = NULL;
    if (!failed(api, api->GetAllocatorWithDefaultOptions(&allocator), error,
                "getting an allocator")
        && !failed(api, api->SessionGetOutputName(session->session, 0, allocator,
                                                  &first_output),
                   error, "reading the output name")) {
        output_names[0] = first_output;
    }

    OrtStatus *status = api->Run(session->session, NULL, input_names,
                                 input_values, 3, output_names, 1, &output);
    if (first_output) allocator->Free(allocator, first_output);
    if (failed(api, status, error, "running the model")) {
        goto done;
    }

    float *data = NULL;
    if (failed(api, api->GetTensorMutableData(output, (void **)&data), error,
               "reading the samples")) {
        goto done;
    }

    OrtTensorTypeAndShapeInfo *info = NULL;
    if (failed(api, api->GetTensorTypeAndShape(output, &info), error,
               "reading the output shape")) {
        goto done;
    }
    size_t total = 0;
    OrtStatus *counted = api->GetTensorShapeElementCount(info, &total);
    api->ReleaseTensorTypeAndShapeInfo(info);
    if (failed(api, counted, error, "counting the samples")) {
        goto done;
    }

    // Copied out. The buffer belongs to the OrtValue, which is released below.
    *samples = malloc(total * sizeof(float));
    if (!*samples) {
        say(error, "out of memory for %zu samples", total);
        goto done;
    }
    memcpy(*samples, data, total * sizeof(float));
    *count = total;
    result = 0;

done:
    if (output) api->ReleaseValue(output);
    if (speed_value) api->ReleaseValue(speed_value);
    if (style_value) api->ReleaseValue(style_value);
    if (token_value) api->ReleaseValue(token_value);
    free(padded);
    return result;
}

void kokoro_free_samples(float *samples) { free(samples); }

void kokoro_close(kokoro_session *session) {
    if (!session) return;
    const OrtApi *api = session->api;
    if (api) {
        if (session->memory) api->ReleaseMemoryInfo(session->memory);
        if (session->session) api->ReleaseSession(session->session);
        if (session->env) api->ReleaseEnv(session->env);
    }
    // The library is left open. Releasing it while ORT's own threads are
    // winding down unmaps code they are still running.
    free(session);
}

const char *kokoro_runtime_version(kokoro_session *session) {
    return session ? session->version : "";
}

const char *kokoro_token_input_name(kokoro_session *session) {
    return session ? session->token_input : "";
}
