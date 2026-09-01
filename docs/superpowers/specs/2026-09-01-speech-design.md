# Speaking text aloud in nib

Select text, press a key, hear it. Local, offline, and idle when unused.

Status: design written 2026-09-01. Not implemented.

## Why

There is a working text-to-speech setup on this machine already: a Node server
on port 41777 with Kokoro behind it, driven by a `voice` CLI and two hotkeys.
It works. The request is to fold it into nib so there is one application rather
than an app plus a server plus a shell alias.

The instruction was to move it without changing how it works.

## What is there now

    voice-server-cloudci/
      server.js              1243 lines, HTTP on 41777
      bin/voice               444 lines, the CLI
      vendor/kokoro_worker.py  85 lines, the engine
      vendor/kokoro-models/   426MB
      vendor/kokoro-venv/     Python, onnxruntime 1.29.0, phonemizer
      voices/                 piper models, unused

`voice status` reports the live configuration:

    engine        kokoro
    model         af_heart
    voices        54 kokoro, 2 piper
    volume        0.45
    worker        ready
    cache         125 entries, 99.1MB

Piper is vendored and not in use. That matters: the first reading of this
blamed piper for the licence, and piper is not what runs.

## Decisions

| Question | Answer |
|---|---|
| Which engine | Kokoro, the one actually running |
| How is it reached | Ported natively, linked into nib |
| Start speaking | `⌃⌘N` |
| Stop speaking | `⌃⇧H` |
| What is spoken | The selection, falling back to the clipboard |
| Voice | Chosen from nib's menu, 54 to pick from |

### Why a native port and not the server

nib would be smaller and this would be finished today if nib simply POSTed to
127.0.0.1:41777. That was offered and declined: the requirement is one
self-contained binary, no Node, no Python.

The cost is honest and worth stating. Today's engine is a warm worker with a
99MB cache; a fresh port starts cold and will be slower per call until it
builds one of its own.

### Why this made nib GPL

Kokoro is Apache-2.0. Its phonemiser is not: `phonemizer` 3.4.0 declares "GNU
GENERAL PUBLIC LICENSE" and reaches espeak-ng through `espeakng_loader`.
Linking that chain into nib makes the whole application a derivative work.

piper reaches espeak-ng too. There is no route to speech synthesis here that
avoids it, so the choice was GPL or a separate process, and GPL was chosen.

## The pipeline to preserve

Read from `kokoro_worker.py` and `kokoro_onnx`, and reproduced exactly:

1. Text is split into chunks.
2. Each chunk is phonemised by espeak-ng, under a lock -- espeak holds
   process-global state, and concurrent calls return the wrong answer.
3. Phonemes become token ids through `DEFAULT_VOCAB`, capped at
   `MAX_PHONEME_LENGTH` of 510.
4. The voice pack is indexed by token count to give a style vector.
5. ONNX runs with `input_ids` (older exports call it `tokens`), `style`, and
   `speed`.
6. Output is float samples at 24000 Hz.
7. Volume multiplies the samples and clips to [-1, 1]. Scaling above 1.0
   without clipping crackles rather than getting louder.

Defaults carried over unchanged: voice `af_heart`, speed 1.0, volume 0.45,
language `en-us`.

## Files

    kokoro-v1.0.onnx        326MB    the model
    kokoro-v1.0.int8.onnx    92MB    quantised, unused today
    voices-v1.0.bin          28MB    a zip archive -- starts "PK", numpy npz

The voice pack being an npz matters: reading it natively means unzipping and
parsing numpy arrays, not a bespoke format.

## Components

New, under `Sources/nib/Speech/`:

| File | Responsibility |
|---|---|
| `KokoroEngine.swift` | actor over the C shim: load, synthesise, release |
| `KokoroShim.cpp` | ONNX Runtime and espeak-ng, behind a C interface |
| `VoicePack.swift` | reads voices-v1.0.bin, lists and indexes the 54 voices |
| `SpeechController.swift` | state machine: idle, speaking, stopping |
| `SpeechPlayer.swift` | plays the samples, and stops on demand |
| `VoiceMenu.swift` | the picker in the menu bar |

Reused: `HotkeyMonitor` (a third id), the selection reader, `Log`,
`ModelInstaller` and the setup window for fetching models.

## What is unresolved

**~~The tokeniser is the risk.~~ Closed, 2026-09-01.**

It turned out not to need porting by hand at all. The table is not Python code
-- `DEFAULT_VOCAB` is read from `kokoro_onnx/config.json`, 114 entries in 2351
bytes of data. `Scripts/generate-vocab.py` reads it and writes
`KokoroVocab.swift`, so transcription is out of the process entirely and the
source hash is embedded to catch an engine upgrade changing it.

The rule that uses it is four lines: map each Character through the table and
drop what is missing, which is exactly what Python's
`[i for i in map(self.vocab.get, phonemes) if i is not None]` does.

Verified rather than assumed. `Tests/Fixtures/kokoro-golden.json` holds one
sentence run through the Python engine on this machine -- its phonemes, the 53
ids it produced, and a hash of the audio. The Swift tokeniser produces the same
53 ids from the same phonemes. Eleven tests cover it, including that every
symbol in a real transcript is known, since an unknown one is dropped and a
word simply goes missing.

What is still unverified is everything after tokenisation: the ONNX call and
the voice pack. The fixture already carries `sha256_float32_le` and
`sample_count` for that comparison when the engine exists.

**Two engines will want the GPU.** Whisper already holds Metal memory for 180
seconds after transcribing, and a rewrite in that window fails. Adding a third
model makes that worse, and the mitigation used so far -- shut one down before
starting another -- does not obviously extend to three.

**Not measured yet:** how long a cold Kokoro load takes, and how that compares
to the warm worker. That number decides whether the model is held between
presses or released like whisper's, and it should be measured before the
decision is made rather than after.

## Out of scope

Streaming as it synthesises. Speaking whole documents. The piper engine.
Anything the current setup does not already do.
