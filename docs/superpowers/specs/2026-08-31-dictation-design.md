# Dictation in nib

Speak into any text field and have the words appear there. Local, offline, and
idle when you are not using it.

Status: design approved 2026-08-31. Not implemented.

## Why

FluidVoice does this today and costs about 25% CPU. Wispr Flow is not free.
nib already owns the difficult half of the problem -- Accessibility permission,
finding the focused field, and writing text back into any app -- so the missing
piece is audio and a speech model.

The target is not a faster model. It is a design where nothing runs at all
until you ask for it.

## What FluidVoice is doing

Worth recording, because it explains the number being escaped. Its bundle
contains:

    FluidIntelligenceMLXArtifacts.json        MLX runtime
    parakeet_custom_vocabulary.default.json   NVIDIA Parakeet
    llama.framework                           a second model, for formatting
    CTranscribe.framework
    170 MB

Two models in the loop, one of them an LLM, on a runtime that keeps weights
resident. Parakeet is also English-only, which is why a separate vocabulary
file exists to patch in technical terms.

## Decisions

| Question | Answer |
|---|---|
| Where does it live | Inside nib |
| How is it triggered | `⌃⌥D` toggles on, `⌃⌥D` toggles off |
| When does text appear | All at once, after you stop |
| Is the text cleaned up | No. Insert exactly what was heard |
| What is dictated | English prose, technical terms, long passages; Hindi occasionally |

### Why toggle rather than hold

Hold-to-talk is cheaper still, but it is unusable for the long dictation this
has to support. The cost of toggle is a state you can forget you are in, so
the microphone being live has to be visible without looking for it.

### Why `⌃⌥D`

`RegisterEventHotKey` takes a combination system-wide, so whatever it grabs is
gone from every other app for as long as nib runs. `⌘E` was considered and
rejected on those grounds: it is Eject in the Finder and "Use Selection for
Find" in every standard text view, and dictation is not worth losing both
everywhere.

`⌃⌥D` is awkward to press and owned by nothing, which is the trade being made.
It joins the existing preference list in `HotkeyMonitor` -- `⌥Space` for the
panel, `⌘⇧G` as its fallback -- and registration failure has to degrade the
same way theirs does rather than leaving dictation silently unavailable.

### Why no cleanup pass

nib already ships llama-server and a model, and already has guards that refuse
a rewrite which drops content or turns a question into a statement. Reusing
them for dictated text would fix filler words and punctuation for about a
second of latency.

Rejected deliberately: what you said is what you get. Nothing can silently
reword you if nothing tries. This is reversible later -- the guards will still
be there.

## Engine

**whisper.cpp, linked as an XCFramework.**

It is the only engine that covers all four content cases. Parakeet is
English-only. Apple's `SFSpeechRecognizer` has no custom-vocabulary hook, is
weak at code-switching, and has historically capped a single request near a
minute. `SpeechAnalyzer` would be the obvious answer but arrived in macOS 26;
this machine is on 15.7.9.

Verified against release `b4938` before this was written:

    whisper.xcframework/macos-arm64_x86_64/whisper.framework   5.9 MB
      276 embedded Metal kernels
      214 ggml_metal symbols
      137 whisper_* API symbols
      links Metal, Accelerate

This is a better shape than the `llama-server` integration. whisper.cpp
publishes no macOS command-line tarball -- the assets are Linux, Windows, and
this XCFramework -- and linking it means no subprocess, no port, no health
check, no idle-shutdown timer, and no `@loader_path` dylib closure to vendor.
The framework is consumed as a SwiftPM `binaryTarget` pinned by URL and
checksum, pointing at upstream directly.

No mirror is needed, which is the opposite of the llama runtime. llama.cpp
keeps about a hundred nightly builds -- roughly nine days -- so its URL had to
be mirrored onto this repository's own releases. whisper.cpp publishes the
XCFramework rarely and keeps it: 15 releases carry it, back to `b2365` from
March 2025. A pinned upstream URL will still resolve.

### Model

Sizes are real, from the Hugging Face API:

| Model | Size |
|---|---|
| `ggml-base-q5_1.bin` | 60 MB |
| `ggml-small-q5_1.bin` | 190 MB |
| `ggml-medium-q5_0.bin` | 539 MB |
| `ggml-large-v3-turbo-q5_0.bin` | 574 MB |
| `ggml-large-v3-turbo-q8_0.bin` | 874 MB |

Starting point is `large-v3-turbo-q5_0`: multilingual, and the best
quality-per-second on Apple silicon. **The default is not fixed until it is
measured** on real speech from this machine, against `small` and `medium`,
for both accuracy and wall-clock. The 0.6B rewrite model was chosen this way
and two larger models were rejected on measurement; the same applies here.

Technical vocabulary is handled by whisper's initial prompt, which biases
decoding towards supplied terms. This is the mechanism Parakeet needed a
separate JSON for.

## Flow

    hotkey ──▶ recording ──▶ hotkey ──▶ transcribing ──▶ insert at cursor
                mic live               one whisper run    existing write-back

Idle cost is zero: no microphone, no model resident, no process. While
recording, the only work is an audio tap writing 16kHz mono samples into a
buffer. The model is loaded when transcription starts and released when it
ends.

## Components

New, under `Sources/nib/Dictation/`:

| File | Responsibility |
|---|---|
| `AudioRecorder.swift` | AVAudioEngine tap, 16kHz mono Float32, level metering |
| `WhisperEngine.swift` | actor over the whisper C API: load, transcribe, release |
| `DictationController.swift` | state machine and the only place that sequences the above |
| `DictationOverlay.swift` | the recording indicator: level, elapsed time, Cancel |
| `WhisperModelCatalog.swift` | downloadable models, alongside the existing rewrite catalogue |

Reused unchanged: `HotkeyMonitor`, focused-element resolution, the text
write-back path, `ModelInstaller` and `ModelSetupWindow`, `Log`.

### State machine

    idle → arming → recording → transcribing → inserting → idle
                        │            │
                        └── cancel ──┴──▶ idle (audio discarded)

One owner. The overlay renders state and never drives it; the hotkey posts
events and never touches audio. Every transition is testable without a
microphone or a model.

## Found while building

Two things the design did not anticipate, both measured.

**Metal shaders compile once, and it takes half a minute.** The first run of a
freshly built binary reports:

    ggml_metal_library_init: loaded in 31.201 sec

Every run after that: `0.009 sec`. macOS caches the compiled library per
binary, so the cost lands once per install -- on a new user's first dictation,
which is the worst moment for it. The bundled app paid it again at 20.3s,
because a different binary is a different cache entry.

Dictation must warm this at install time, not on first use: after the speech
model is fetched, initialise the engine once in the background. The setup
window already waits on a download, which is the natural place to hide it.

**The framework wants macOS 13.3, and nib claims 13.0.**

    ld: warning: building for macOS-13.0, but linking with dylib
    '@rpath/whisper.framework/...' which was built for newer version 13.3

The cask says `depends_on macos: :ventura`, which includes 13.0 through 13.2 --
where this framework may not load. SwiftPM's platform list has no point
releases, so this cannot be expressed in Package.swift. Unresolved: either the
cask's floor rises, or dictation is gated at runtime on the OS version. It is
not a build error and does not affect anyone on 13.3 or later.

## Resource conflict

Measured this session: a 2.2GB model failed to run on this 16GB machine with a
browser open, and llama.cpp reported
`kIOGPUCommandBufferCallbackErrorOutOfMemory`. nib reports that as "not enough
memory to run this model".

Whisper and llama-server both want the GPU and are never needed at the same
instant. `DictationController` shuts `llama-server` down before transcribing.
The rewrite engine already restarts on demand and has an idle timeout, so this
costs a model load on the next rewrite and nothing else.

## Permissions

Dictation needs microphone access: a second TCC prompt, and
`NSMicrophoneUsageDescription` in `Info.plist`.

This changes what nib claims about itself. "Never sends your text anywhere"
stays true -- audio is captured, transcribed and discarded locally, and there
is no network path -- but the README has to say plainly that nib can now listen
when asked to, rather than leaving someone to discover a microphone permission
they did not expect. The menu bar icon changes while recording, and the overlay
is visible for the entire time the microphone is live.

Audio is never written to disk. The buffer is freed after transcription.

## Failure modes

| Case | Behaviour |
|---|---|
| No speech model installed | The existing setup window, with speech models |
| Microphone denied | Menu explains and links to the settings pane |
| No focused text field | Transcript goes to the clipboard, overlay says so |
| Recording exceeds the cap | Stops itself and transcribes what it has |
| Model fails to load | Reported as the reason, not as a generic failure |
| Transcript is empty | Nothing inserted, no empty edit in the field |

A recording cap is required. Held audio grows without bound and a forgotten
toggle is the expected way that happens. Ten minutes, warned at nine.

## Testing

Pure, no hardware:

- state machine transitions, including cancel from each state
- hotkey debounce and double-fire
- 16kHz conversion and buffer accounting from synthetic samples
- insertion target resolution, including the no-target clipboard path
- catalogue invariants, as for the rewrite models

Integration, skipped when the framework is absent, as with the llama closure
test:

- the framework loads and reports its version
- a known WAV transcribes to known text

Measurement, and not a pass/fail test:

- `nib --dictate-bench <wav>` reports wall-clock, real-time factor and peak
  memory per model, so the default is chosen on evidence

## Out of scope

Streaming transcription. Cleanup or reformatting. Always-on listening. Wake
words. Speaker diarisation. Translation. Custom vocabulary UI -- the prompt
mechanism exists, but exposing it is a later decision.

## Open questions

1. Which model becomes the default. Answered by measurement, not by argument:
   `--dictate-bench` over `small`, `medium` and `large-v3-turbo` on real speech
   from this machine, comparing accuracy, wall-clock and peak memory. Nothing
   is written into the catalogue as recommended before that has been run.
