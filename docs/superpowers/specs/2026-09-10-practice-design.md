---
tags:
  - design
created: 2026-09-10
type: spec
---

# Practice takes

Record yourself answering a question. Get the audio back to listen to, and a
transcript with the things you cannot hear yourself doing.

## Why this is not dictation with a flag

Dictation and practice share a microphone, a model and nothing else.

Dictation is a **means**. The words go into a field and the audio is discarded
the moment it has served its purpose; `AudioRecorder.stop()` returns the samples
and `DictationController` never writes them anywhere. That is correct for
dictation and wrong for practice.

A practice take is the **artefact**. You keep the audio because hearing yourself
is the point, and you keep the transcript because what you said and what you
remember saying are different documents.

Reusing `DictationController` would mean threading a mode flag through a state
machine whose entire job is deciding what may follow what, in order to make it
sometimes not type. `PracticeController` is 190 lines and shares the two pieces
worth sharing: `AudioRecorder` and `WhisperEngine`.

## What it measures

`DeliveryReport` is pure -- segments in, numbers out, no clock and no disk.
Everything in it is something you cannot perceive in your own voice while
producing it. People underestimate their own filler and overestimate their own
pace, which is why practising without a recording mostly rehearses the mistakes.

| Measure | Why it is here |
|---|---|
| Pace, wpm | Over the whole take, **silence included**. Dividing by speaking time would score a halting answer as brisk, which is the opposite of what the listener heard |
| Fillers, and per minute | The rate is what compares across takes of different length |
| Pauses over 2s | Two, not one. Ordinary speech is full of sub-second gaps; flagging those would bury the real ones |
| Longest sentence | A spoken sentence past ~30 words is one the listener already lost |
| Whether the ending lands | A trailing "so yeah" undoes an otherwise good answer |

It does not grade content. Whether the answer was *good* is a judgement.

### The filler rule, and why it has two lists

The obvious implementation -- one list of filler words, count them everywhere --
was written first and a test caught it marking **"the right call"** as filler.

So there are two lists:

- `fillerWords` (um, uh, er, hmm) count **anywhere**. These words have no other job.
- `openingFillers` (so, right, okay, basically, actually) count only when they
  **open a sentence, or follow another filler**.

"So" opening a sentence is a verbal throat clear. "So that the index is used" is
a conjunction doing its job. The follow-a-filler part matters too: *"um, so
basically"* is one hesitation with three words in it, and stopping at the "um"
reports a third of what the listener heard.

Phrases are counted first and replaced with a marker rather than deleted, so the
run detection still sees a filler in that position. Deleting them would break
the chain and undercount.

## Timings

`WhisperEngine.transcribe` returned a flat `String`, which is all dictation
needs. Practice needs to know *when* things were said, because the gap between
two segments is a pause and the pauses are most of what makes someone sound
unprepared.

`transcribeSegments` is now the real function and `transcribe` joins its output.
There is no second decode -- this is the transcription whisper already did, with
the timings not thrown away. whisper reports centiseconds; the conversion to
seconds happens at the boundary so nothing downstream has to know that.

## Files

Takes land in `~/Documents/nib/practice/`, as `yyyy-MM-dd-HHmmss.wav` and the
matching `.md`.

**Documents, not Application Support.** These are things you open, play and
delete yourself. Burying them somewhere Finder hides by default would make the
feature useless for the one thing it is for.

The stem is a sortable timestamp, so a hundred takes list themselves in the
order you recorded them without anyone naming anything, and the pair stays
obvious.

The WAV is **16-bit PCM**, not 32-bit float: Preview, QuickTime and Quick Look
all open the former without comment and some refuse the latter. Samples are
clamped before scaling, because a float that drifts past 1.0 truncates to a loud
click at the other end of the range and one clipped sample is audible.

The transcript is **Markdown** because it is meant to be read by a person and
pasted to whoever is coaching them. The numbers go above the words: someone
reviewing a take wants "you said um fourteen times" first, and reads the
transcript afterwards to find where.

## Wiring

- **⌃⌥P**, next to dictation's ⌃⌥D. Same gesture, pointed at yourself.
- Menu: **Practice Take**, and **Practice Takes…** to open the folder.
- On finish, the folder is **revealed**, not the file opened. Which app owns a
  `.md` is the user's business, and a take is usually one of several being
  compared.
- Same two courtesies as dictation: free the GPU before the speech model loads,
  and stop reading aloud before the microphone opens. Without the second, nib
  records its own voice and transcribes it as though you had said it.
- Registered with `identifier: 5`. Carbon delivers every hotkey press to every
  installed handler, so a monitor without its own identity fires for another
  one's key.

## Limits

- **10 minutes**, inherited from `AudioRecorder.maximumDuration`. Long enough
  for any single interview answer.
- Takes under a second are rejected rather than transcribed, because whisper
  invents words for silence.
- **Audio only.** Video would need `AVCaptureSession`, a camera permission and a
  preview window, and would not improve the measurements: pace, filler and
  pauses are all audible. Watch yourself in QuickTime if you want eye line.
