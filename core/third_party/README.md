# Third-party headers

Headers only. The libraries themselves are loaded at runtime from the engines
`Scripts/windows/fetch-engines.ps1` downloads, so these must match those
builds exactly.

| Directory | Source | Version | Licence |
|---|---|---|---|
| `onnxruntime/` | microsoft/onnxruntime `include/onnxruntime/core/session` | 1.29.0 | MIT (`onnxruntime/LICENSE`) |
| `whisper/` | ggml-org/whisper.cpp `include/` and `ggml/include/` | b4938 | MIT |

`whisper_full_params` is passed by value across the DLL boundary, so a header
from any other whisper.cpp build than the DLL's is a crash, not a warning.
