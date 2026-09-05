<div align="center">

<img src="Resources/AppIcon.iconset/icon_256x256.png" width="128" alt="nib">

# nib

**An offline writing assistant for macOS.**
Underlines mistakes in any app, rewrites what you select, types what you say —
and never sends any of it anywhere.

[![CI](https://github.com/kushagra1212/nib/actions/workflows/ci.yml/badge.svg)](https://github.com/kushagra1212/nib/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/kushagra1212/nib)](https://github.com/kushagra1212/nib/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

<img src="media/nib-demo.gif" width="640" alt="nib correcting a sentence as it is typed, then rewriting a selected sentence">

</div>

---

## Install

```sh
brew install --cask kushagra1212/tap/nib
xattr -dr com.apple.quarantine /Applications/nib.app
```

Or [download the DMG](https://github.com/kushagra1212/nib/releases/latest), drag
nib to Applications, and run that same second line.

> **The second line is not optional.** nib is not notarised — that needs a paid
> Apple Developer account — so Gatekeeper refuses to open it, says it "could
> not verify nib is free of malware", and offers only *Move to Trash*. Press
> that and the app is deleted while Homebrew still believes it is installed.
>
> macOS applies the block to anything carrying the quarantine attribute, which
> a browser download and Homebrew both attach. Homebrew 6 has no flag to skip
> it — `--no-quarantine` was removed and now fails as an invalid option — so
> clearing it afterwards is the way.
>
> **Run it before you open nib for the first time.** Measured on a downloaded
> DMG: launching first gets the process killed outright — no dialog, no message
> — and macOS removes the app. Clearing the attribute afterwards is then a
> command pointed at something that is no longer there.
>
> Both routes need it. Until nib is notarised, there is no install that does
> not.

### Grant Accessibility permission

nib reads the text you are editing through the macOS Accessibility API. It
cannot see anything until you allow it.

1. Launch nib. A pencil icon appears in the menu bar.
2. Approve the prompt, or open **System Settings → Privacy & Security →
   Accessibility** and switch **nib** on.
3. Start typing.

Requires **macOS 13 Ventura or later** on **Apple silicon**.

---

## Use

Type. Mistakes get underlined where you wrote them. Hover one for the fix.

| | Meaning |
|---|---|
| <span style="color:#FFA0A0">**Red**</span> | Spelling, grammar, punctuation |
| <span style="color:#6FB4FF">**Blue**</span> | The sentence could read more clearly |

Hovering shows a card with the change: the old wording struck through, the new
wording in its place. **Accept** applies it, **Dismiss** hides it, and the
arrows step through the rest.

Colours follow [Grammarly's convention](https://www.grammarly.com/blog/product/better-writing-with-grammarly/)
so the meaning is already familiar, at a fraction of the saturation — these
surfaces sit on top of a sentence you are trying to read.

### How many mistakes

Selecting text shows a count beside the rewrite buttons: `3 mistakes · 4.2 per
100 words`, or `no mistakes in 13 words`.

A rate, not a total, because three mistakes in a tweet and three in an essay are
not the same writing. Below twenty words no rate is shown at all — one slip in
six words is "17 per 100", which reads as a verdict on you rather than on the
sentence.

It counts what harper finds: spelling, grammar and punctuation. It does not
judge whether the writing *sounds* natural, and a sentence can score clean while
still being worth running through **Native**.

### The panel

Some apps do not report where their text sits on screen, so no underline can be
placed. Press **⌥Space** there instead: nib grabs the selection, shows the same
suggestions in a floating panel, and writes the result back.

The menu bar icon has **Check Selection** for the same thing without the hotkey.

### Command line

```sh
nib --lint "Their is many erors"        # check text and print suggestions
nib --rewrite "text to improve"         # run all four rewrite modes, with timings
nib --speak "testing one two three"     # read aloud, printing every stage
nib --speak-silent "one two three"      # the same, without playing it
nib --whisper-probe                     # report the speech engine and GPU
nib --whisper-probe model.bin audio.wav # transcribe a file, no microphone
nib --model-bench 5                     # time model load, first call, warm calls
nib --bench 2000                        # measure lint latency
nib --ax-probe 5                        # report what the focused field exposes
nib --live-probe 20                     # trace the inline pipeline
nib --marker-probe                      # check underline placement
```

Handy once installed:

```sh
alias nib=/Applications/nib.app/Contents/MacOS/nib
```

---

## AI rewrite (optional)

Grammar checking works out of the box and needs no model.

The **Fix / Clearer / Shorter / Native** buttons and the blue clarity underlines
run a language model locally. nib bundles the engine that runs it but no model,
because the smallest useful one is another 800MB and that is a choice worth
leaving open. Nothing leaves your machine either way.

**nib offers to set this up for you.** The first launch with no model installed
opens a window listing the models it knows, downloads the one you pick, checks
it loads by running a real correction through it, and switches the features on
without a restart. It is also under **Set Up AI Rewrite…** in the menu bar. If a
model is already installed, none of this appears.

To do it by hand instead, put any `.gguf` in
`~/Library/Application Support/nib/models` and restart nib.

**What the four buttons do**

| | |
|---|---|
| **Fix** | Correct the grammar. Change as little else as possible. |
| **Clearer** | Same meaning, easier to read, roughly the same length. |
| **Shorter** | Cut it down, keeping every point. |
| **Native** | Rewrite it the way a native speaker would have said it. |

Selecting text runs Fix, then Clearer, then Native, and shows the first one that
changes anything — least invasive first, so an unasked-for rewrite fixes the
mistake and leaves your voice alone.

The consequence is that **Fix answers nearly every time**, because it is reached
first and something is usually wrong. Native only runs on its own when the
grammar is already correct. So the suggestion is labelled with the mode that
produced it — `FIX`, `CLEARER`, `SHORTER`, `NATIVE` — and pressing another
button asks that question directly.

That label exists because of a real mix-up: nib's Fix output was compared
against ChatGPT's free rewrite and judged as nib's Native. They are different
answers to different questions.

There is no step for installing llama.cpp: a build of `llama-server` ships
inside the app, so the model is the only piece you supply. A Homebrew
installation is still used if one is there and the bundled copy is not, which
in practice means a checkout that has not run `Scripts/fetch-llama.sh`.

### Which model

**Qwen3 4B Instruct-2507 is what nib preselects**, at 2.5GB.

It replaced the 0.6B after both were measured on a sentence someone here
actually wrote:

> Also I do not have option to see the score of the selected text how much is it
> grammatically correct because I am very naive at English so I can not judge
> myself.

| | |
|---|---|
| **0.6B**, Fix | added one comma |
| **0.6B**, Native | added a second comma |
| **4B**, Native | "I also don't have the option to see how grammatically correct the selected text is — I'm quite inexperienced with English, so I can't judge it on my own." |

The 0.6B is a comma inserter on writing like this. That is not a cheap version
of the feature, it is the feature absent.

**Instruct-2507 rather than plain Qwen3 4B**: the base model thinks out loud
before answering, and every token of that is latency for output nib throws away.

**The cost is real.** About 1.4s a rewrite against the 0.6B's 0.3s, and 2.5GB
against 805MB. That is the right trade for something you ask for by pressing a
button — and it is exactly why the live underlining stays on harper, which
answers in 30ms and never wakes the model at all.

**Qwen3 0.6B stays on the list** for a small disk, and still fixes everyday
mistakes: wrong verb forms, tense, plurals.

Gemma 3 270M was tried and is not usable. It fixed only the misspellings, and
for "clearer" and "shorter" it *described* the sentence — returning
`"The sentence is too long and wordy."` in 0.04s — instead of rewriting it.

None of this limits you to the list — **Choose File…** in the same window takes
any GGUF, and nib prefers the largest of the models it recognises.

Measured on a 24GB machine. A 2.2GB model was previously seen to fail on a 16GB
machine with a browser open, reporting
`kIOGPUCommandBufferCallbackErrorOutOfMemory`; the 4B has not been retested
against that, which is recorded here rather than assumed away. nib reports it as
*"not enough memory to run this model"* rather than as a parse failure.

---

## Dictation (optional)

Press **⌃⌥D**, talk, press it again. The words appear where your cursor is, in
whatever app you are typing in.

Nothing runs until you press the key: no microphone open, no model resident, no
background process. That is the whole design. A speech model is hundreds of
megabytes and is loaded when you stop speaking, then released.

**Setup.** Put a whisper `.bin` model in
`~/Library/Application Support/nib/speech`, then press ⌃⌥D. Whisper small is a
reasonable start:

```sh
mkdir -p ~/Library/Application\ Support/nib/speech
curl -L -o ~/Library/Application\ Support/nib/speech/ggml-small-q5_1.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin
```

macOS will ask for the microphone the first time. Audio is transcribed on this
machine, is never written to disk, and is discarded when the transcript is
inserted.

### If you missed it

Dictation writes into whatever app has focus, which is fine until the focus
moved, the field rejected it, or you were not looking. **Recent Dictation** in
the menu bar keeps the last hundred transcripts; pick one to copy it.

Stored under `~/Library/Application Support/nib`, readable only by you, and
never sent anywhere.

### Teach it your words

The single largest improvement to accuracy, and the one most people never find.

Speech models replace any name they have never seen with the nearest real word.
Measured here on Indian-accented English:

| said | heard |
|---|---|
| `The useMemo hook is causing a re-render` | The **Usamimohuk** is causing a re-render |
| `The Hasura metadata needs refreshing` | The **Azure** metadata needs refreshing |

Ordinary sentences were already correct. Only the names failed — and no accent
handling fixes that, because "Hasura" is not a word in any accent.

**Dictation Words…** in the menu opens a list nib primes the model with. Add
your project names, your libraries, your colleagues. Both examples above then
transcribe exactly. Edits apply to the next sentence; no restart.

Keep it short — it is a nudge, not a dictionary, and a long list dilutes it.

### What it will not do

- **Type sound effects.** Whisper writes `[BLANK_AUDIO]` for silence and
  `(upbeat music)` for a hum. Those are stripped, and silence is refused before
  the model is even loaded, because whisper invents words for it — four seconds
  of a silent file transcribes as "you".
- **Run for ever.** A forgotten toggle stops itself after ten minutes and
  transcribes what it heard rather than discarding it.
- **Stream.** The transcript arrives when you stop, not word by word. One burst
  of work instead of continuous inference, which is where the CPU goes.

---

## Reading aloud (optional)

Select text anywhere, press **⌃⌘N**, and nib reads it. **⌃⇧H** stops. With
nothing selected it falls back to whatever is on the clipboard.

54 voices, picked from nib's menu under **Voice** — American, British, Spanish,
French, Hindi, Italian, Japanese, Portuguese and Chinese, in both registers.

**Setup.** Open **Voices…** from nib's menu and press Download. It fetches two
files into `~/Library/Application Support/nib/voice`: the Kokoro model (326MB)
and the voice pack (28MB). Both stay on this machine.

The speech runs entirely on the CPU, on two threads. That is a measured choice
rather than a default: on a 12-core machine one thread synthesises at 1.9x real
time, two at 3.5x, four at 4.9x — so the second thread earns its place and the
third does not, and nib leaves the rest of the machine alone. It also means
speech never competes with dictation for the GPU.

The model is held between presses, which costs about half a second the first
time and nothing after, then is released after two minutes idle.

**Speaking stops when you start dictating.** Pressing ⌃⌥D while nib is reading
aloud stops the reading first. Otherwise the microphone hears the speech and
transcribes nib back to itself, and two models sit in memory at once.

**When it does not work**, ask it directly:

```sh
/Applications/nib.app/Contents/MacOS/nib --speak "testing one two three"
```

That prints every stage — where espeak was found, which runtime loaded, the
phonemes, the token count, the sample count and the peak — so a failure names
itself instead of being silence.

## How it works

Three passes, ordered by cost, each superseding the last:

| Pass | Latency | Provides |
|---|---|---|
| [harper](https://writewithharper.com/) | ~30ms | Spelling and hard grammar |
| Local model | ~1.5s | Context-aware corrections |
| Local model, per sentence | ~1.5s each | Clarity rewrites |

harper is a dictionary matcher: fast, and with no idea what your words mean. It
will happily turn `NSString` into `Nesting` and `gpt` into `get`. nib filters
those out by shape — acronyms, medial capitals, identifier punctuation, and
tokens with no vowel — then the model rereads the sentence with the context
harper lacks.

The model returns a rewritten sentence, which is diffed against yours so each
change becomes one underline rather than a wholesale replacement. This mirrors
[what Grammarly does](https://www.grammarly.com/blog/engineering/gec-tag-not-rewrite/):
a sequence-to-sequence rewrite for sentence-level context, paired with a
mechanism that turns it into individually taggable edits.

Rewrites are checked before they are trusted. A small model asked to fix grammar
will sometimes answer the text or summarise it, and applying that as inline
"corrections" would silently rewrite what you meant.

### Privacy

Everything runs on your machine. No network calls, no telemetry, no account.
The only time nib touches the network is when you download a model yourself.

---

## Build from source

```sh
git clone https://github.com/kushagra1212/nib.git
cd nib

Scripts/fetch-harper.sh          # prebuilt harper-ls, no Rust toolchain needed
Scripts/fetch-llama.sh           # llama-server and the libraries it loads
Scripts/fetch-whisper.sh         # the speech engine; required before any build
swift build -c release
swift test

swift Scripts/make-icon.swift
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
Scripts/bundle.sh                # dist/nib.app
Scripts/install.sh               # move it to /Applications, leaving one copy
Scripts/make-dmg.sh              # dist/nib-<version>.dmg
```

`install.sh` rather than copying by hand. macOS ties Accessibility and
microphone permission to one specific app, identified by its code signature, so
two copies of nib is a trap: launch the wrong one and it is listed and switched
on in System Settings while refusing to work. The script deletes `dist/nib.app`
after installing, and clears both permissions when the signature has changed —
a stale grant does not fail loudly, it just never works.

Ad-hoc signing means every rebuild changes that signature. A real certificate
makes the requirement the identity rather than the hash, and the permissions
survive.

Needs Swift 5.9+ and Xcode command line tools.

> Rebuilding changes the app's code signature, and macOS ties Accessibility
> permission to that signature. The old grant stays listed and switched on
> while being dead. Clear it:
>
> ```sh
> pkill -x nib
> tccutil reset Accessibility com.kushagra.nib
> open dist/nib.app
> ```

### Layout

```
Sources/nib/
  Lint/      harper client, filtering, diffing, edit planning, writing score
  Inline/    underlines, hover card, geometry, live checking, selection bar
  AX/        Accessibility read and write
  UI/        menu bar, hotkeys, panels, theme, contrast
  Rewrite/   llama.cpp lifecycle, model catalogue, prompts
  Dictation/ audio capture, whisper, the recording overlay, history
  Speech/    espeak, Kokoro, phonemes, voice pack, playback
  Support/   memory readout and other small shared pieces
```

---

## Known limits

- **Apple silicon only.** harper-ls ships an arm64 binary here.
- **Not notarised**, so a hand-installed DMG needs `xattr -cr`.
- **Underlines need the app to report text geometry.** Most do, including
  Electron apps. Where it is missing, ⌥Space still works.
- **A word wrapping across a line break gets no underline** — the API reports
  one box for the whole span. The panel still offers the fix.
- **Fields over 4000 characters are skipped**, because measuring thousands of
  ranges per keystroke stalls the app you are typing in.
- **English only** for underlines, which is a harper limitation. Dictation is
  multilingual, though it is told to expect English unless you change that.
- **Dictation and rewrite share the GPU.** Whisper holds its memory for about
  three minutes after transcribing, so a rewrite in that window can report
  running out of memory. It says so plainly rather than pretending the model is
  missing.
- **Reading aloud and dictation do not run together.** Starting one stops the
  other, on purpose: the microphone would otherwise transcribe nib's own voice.
- **The rewrite bar is clicked, not typed.** It never takes keyboard focus, so
  that typing keeps going to the app underneath — which also means there is no
  Return-to-accept. Esc dismisses everything.
- **No Developer ID signature yet.** Every rebuild changes the ad-hoc signature,
  and macOS ties Accessibility and microphone permission to it, so both must be
  granted again after an update.

## Credits

All three are shipped inside the app, unmodified, and their full licence texts
are in [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt) — also inside the
bundle, and under **Licences…** in the menu bar.

- [harper](https://github.com/automattic/harper) by Automattic — the grammar engine, Apache-2.0
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — rewriting, MIT
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — dictation, MIT

Models are downloaded by you and are not part of this repository or the app.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: measure before claiming,
explain why rather than what, and make failures say what to do about them.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

nib was MIT through v1.0.3. Building speech synthesis in changed that. The
engine, Kokoro, is Apache-2.0 — but it phonemises through phonemizer and
espeak-ng, which are GPL-3.0, and linking that chain in makes the whole
application a derivative work. piper reaches espeak-ng too, so there is no
route to speech here that avoids it. Keeping the engine at arm's length as a
separate process would have preserved MIT, and was rejected in favour of one
self-contained binary.

The bundled engines stay compatible — harper-ls is Apache-2.0, llama.cpp and
whisper.cpp are MIT, and all three may be combined into a GPL-3.0 work.
