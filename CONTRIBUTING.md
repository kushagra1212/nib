# Contributing

Patches welcome. This is a small project with a few strong opinions; the rest
is negotiable.

## Getting it building

```sh
Scripts/fetch-harper.sh          # grammar engine
Scripts/fetch-llama.sh           # rewrite engine
Scripts/fetch-whisper.sh         # speech engine
swift build -c release
swift test
```

All three fetches are required. `Package.swift` declares the whisper
XCFramework as a binary target, so nothing builds until it is on disk — that is
the one step whose absence produces a confusing error rather than a clear one.

To run what you built:

```sh
Scripts/bundle.sh
Scripts/install.sh
```

Use `install.sh` rather than copying `dist/nib.app` anywhere. macOS ties
Accessibility and microphone permission to a specific code signature, so two
copies of nib on one machine is a trap: the wrong one ends up in the menu bar,
listed and switched on in System Settings and refusing to work. The script
leaves exactly one copy and clears permissions the new signature cannot use.

Ad-hoc signing changes the signature on every build, so expect to re-approve
after each install unless you sign with a real certificate.

## What this project cares about

**Measure before claiming.** Several decisions here were made by argument
first, and every one of them was wrong. The rewrite model is 0.6B because a
1.7B was tried and scored worse; whisper's `small` sits where it does for the
same reason; `[BLANK_AUDIO]` was fixed twice because the first fix made silence
produce the word "you" instead. If a change is meant to improve something,
include the before and after.

**Comments explain why.** What the code does is legible from the code. What
belongs in a comment is the thing the next reader would otherwise undo — the
measurement behind a threshold, the failure a guard prevents, the API that
behaves unexpectedly. `git log` is used the same way; commits explain the
reasoning, not the diff.

**Failures say what to do.** "Model unavailable" for a model that is present
and working wastes someone's evening. Name the actual cause and, where nib can
open the relevant settings pane, offer that.

**Nothing runs when it is not being used.** No always-on microphone, no model
held resident between uses, no polling that could be an event. This is the
constraint dictation was designed around and it is not up for trade.

**Nothing leaves the machine.** No telemetry, no analytics, no crash reporting,
no network call that is not a model download the user asked for.

## Tests

`swift test` should pass before and after your change.

Test the logic, not the framework. The parts worth covering are pure: state
transitions, text filtering, size formatting, the choice of message for a
failure. Anything needing a window, a microphone or a model belongs behind a
skip, as `LlamaServerLookupTests` does — a test that only runs where the
vendored files exist, and says so rather than silently passing.

Name tests after the behaviour, not the function:
`testSilenceEndsQuietlyRatherThanInserting` over `testTranscribe3`. Several
tests here carry a comment describing the bug that prompted them, which is what
stops a future change quietly reintroducing it.

## Style

Follow what is already in the file you are editing. Broadly: British spelling
in prose and comments, American in API names where the platform uses it
(`color` in AppKit calls, `colour` in a sentence about them). Four spaces. No
force-unwrapping outside tests.

## Reporting a bug

The useful ones so far have arrived as a screenshot plus what was expected.
If it involves permissions, `Scripts/install.sh` output and the menu bar's
first line are usually enough to identify it.

For anything about text handling, say which app — Slack, Chrome and native
fields expose their text through three different mechanisms, and a bug in one
is often absent in the others.

## Scope

nib is a writing assistant that works in other people's applications. Things
that fit: better correction, better rewriting, better dictation, wider app
support, less noise.

Things that do not: cloud features, accounts, sync, telemetry, a document
editor of its own.

If you are unsure whether something fits, open an issue before writing it.
