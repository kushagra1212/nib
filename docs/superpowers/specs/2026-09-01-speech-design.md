# Speaking text aloud in nib

Select text, press a key, hear it. Local, offline, and idle when unused.

Status: done, 2026-09-02. Built, verified against the Python engine end to end,
and in use -- the Node server and its worker are stopped, the shell integration
is off, and nib speaks.

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
| `KokoroEngine.swift` | over the C shim: load, synthesise, release — done |
| `CKokoro/kokoro_shim.c` | ONNX Runtime behind four C functions — done |
| `EspeakLibrary.swift` | espeak-ng through dlopen — done |
| `Phonemizer.swift` | text to phonemes, punctuation included — done |
| `PhonemePunctuation.swift` | hides marks from espeak, puts them back — done |
| `PhonemeChunker.swift` | 510 phonemes a pass, balanced — done |
| `VoicePack.swift` | reads voices-v1.0.bin, lists and indexes the 54 voices — done |
| `NumpyLayout.swift` | parses a .npy header, refusing anything not `<f4` — done |
| `ZipDirectory.swift` | finds a stored member's bytes without unpacking — done |
| `VoiceCatalog.swift` | the two files to fetch, and where they live — done |
| `SpeechController.swift` | state machine: idle, speaking, stopping — done |
| `SpeechPlayer.swift` | plays the samples, and stops on demand — done |
| `SpeechSynthesizer.swift` | the whole pipeline, text to samples — done |
| `AudioTrim.swift` | removes the silence the model pads with — done |
| `SpeechState.swift` | what may follow what — done |
| `VoiceNames.swift` | af_heart to "Heart — American, female" — done |
| `SpeechProbe.swift` | `nib --speak`, for when it goes wrong — done |
| `UI/VoiceSetupWindow.swift` | fetches the two files — done |

The voice picker went in the existing menu rather than a `VoiceMenu.swift` of
its own: 54 voices grouped by accent is a submenu, not a component.

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

**~~The voice pack is unread.~~ Closed, 2026-09-01.**

`VoicePack.swift` reads `voices-v1.0.bin` without unpacking it. Every entry is
stored rather than deflated, so a style vector is a seek and a 1KB read out of
28MB, and nothing stays resident between presses.

The same shape of check as the tokeniser, for the same reason: a style from the
neighbouring row is the right voice with the wrong intonation, which gets blamed
on the model. `Scripts/capture-voice-golden.py` records three rows from the
Python engine -- the one the golden sentence uses, the first row of another
voice, and the last -- and Swift returns the same 256 floats for all three.

The numpy header is checked rather than assumed, because every field in it can
be wrong while still producing plausible numbers: big-endian read as
little-endian, float64 as float32, column-major as row-major.

Worth keeping: the data offset comes from the local file header, not the central
directory. The two carry separate extra fields, and computing from the central
one lands a few bytes into the array.

**~~The ONNX call is unverified.~~ Closed, 2026-09-01.**

Tokens and style in, samples out, identical to onnxruntime in Python. Bit for
bit: 79200 samples, same hash, same peak.

`Tests/Fixtures/audio-golden.json` deliberately does not use
`kokoro-golden.json`. That one records `kokoro.create()`, which is inference
plus trimming plus pauses -- three things behind one hash. This runs
onnxruntime directly on the same 53 tokens and the same style row, so a
disagreement can only be the inference.

Thread count turned out not to be a tuning knob. It changes the order
reductions happen in, so it changes the samples; the first run differed from
the fixture and the cause was two threads against Python's default of four.
Capturing at 1, 2 and 4 confirmed it -- two threads in Python gives exactly the
hash Swift produced. It is now explicit and recorded in the fixture.

Two, by measurement: on 12 cores, one thread runs at 1.9x real time, two at
3.5x, three at 4.6x, four at 4.9x, the default at 5.2x.

**Three models, one GPU: resolved, and not by scheduling.** Kokoro runs on
ONNX Runtime's CPU provider, so it never asks for Metal. whisper keeps the GPU
to itself and the contention the design worried about does not arise. If a
CoreML execution provider is ever added for speed, this comes back.

**Not measured yet:** cold load. `CreateSession` takes about 0.3s in Python,
which suggests holding the model between presses is unnecessary -- but that
figure is Python's, and the decision should wait for nib's own.

## Out of scope

Streaming as it synthesises. Speaking whole documents. The piper engine.
Anything the current setup does not already do.

## What replaced what

Retired 2026-09-02, once nib had spoken the same sentence:

    node server.js on 41777      stopped
    kokoro_worker.py             stopped
    shell/voice.zsh in .zshrc    commented out
    /opt/homebrew/bin/voice      removed

The `cloudcli` wrapper in that shell file started the server on every
invocation, which is why it had been up eight days. Removing the line is what
makes the retirement stick; killing the process alone would not have.

The worker had used 1300 minutes of CPU over those eight days -- about a ninth
of a core, permanently, to wait for a keypress. nib runs nothing between
presses except a loaded model, and that is 0.6s of load it saves rather than a
process.

Not removed: `~/code/per/voice-server-cloudci` itself, 882MB. It is not a git
repository and has no remote, so deleting it cannot be undone, and it is where
every fixture in `Tests/Fixtures` was captured from. That is a decision to take
deliberately rather than as part of a port.
