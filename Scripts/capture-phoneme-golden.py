#!/usr/bin/env python3
"""Capture what the Python engine turns text into, across the cases that break.

    Scripts/capture-phoneme-golden.py

Phonemisation is the step before everything already verified. The tokeniser and
the voice pack are both checked against this engine, but they are checked on the
phonemes this produces -- so a phonemiser that disagrees makes both of those
proofs describe the wrong sentence.

espeak alone is not enough. It drops punctuation, and kokoro's vocabulary
contains ".", ",", "!" and "?" -- the full stop is a token in its own right and
carries sentence-final prosody. phonemizer hides punctuation from espeak and
puts it back afterwards, and that restoration is what has to be ported.

So the corpus below is punctuation-shaped: marks at the start, the end and the
middle, marks that double as decimal separators, marks alone, and text with no
marks at all. Each entry records what espeak returned, what phonemizer returned,
what kokoro kept after filtering to the vocabulary, and the token ids.
"""

import json
import sys
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent.parent / "Tests/Fixtures/phonemes-golden.json"

# Grouped by what each one is here to catch, because a corpus without that
# rationale gets trimmed by the next person who finds it slow.
CORPUS = [
    # The sentence the other fixtures use, so all three line up.
    ("plain", "The quick brown fox jumps over the lazy dog."),
    # No punctuation at all: the path where restoration does nothing.
    ("no-marks", "the quick brown fox"),
    # One mark at the end. Position 'E' in phonemizer's terms.
    ("full-stop", "Hello."),
    ("question", "Is it working?"),
    ("exclamation", "Stop!"),
    # A mark in the middle. Position 'I', and the one most likely to be
    # dropped by a port that only handles the end of a sentence.
    ("comma", "Hello, world."),
    ("semicolon", "First; second: third."),
    # Several sentences in one go: multiple marks, multiple chunks.
    ("many-sentences", "One. Two. Three."),
    ("mixed-marks", "Really? Yes! Of course."),
    # A mark at the start. Position 'B'.
    ("leading-mark", "...and then it stopped."),
    # Nothing but marks. Position 'A', where there is no text to attach to.
    ("only-marks", "..."),
    ("only-mark-single", "?"),
    # Decimal separators, which phonemizer deliberately does not split. Getting
    # this wrong makes espeak read two numbers: "19,99" became "nineteen
    # ninety-nine" rather than "nineteen comma ninety-nine".
    ("decimal-comma", "It costs 19,99 euro."),
    ("decimal-point", "Pi is 3.14 exactly."),
    ("thousands", "That is 1,000,000 rows."),
    # Marks that are in the default list but rarely thought about.
    ("dash-ellipsis", "A long pause—then more… and done."),
    ("quotes", 'He said "yes" and left.'),
    ("brackets", "Parentheses (like this) and [brackets] and {braces}."),
    ("inverted", "¡Hola! ¿Qué tal?"),
    # Whitespace, which is collapsed rather than preserved.
    ("padded", "   leading and trailing   "),
    ("newline", "line one\nline two."),
    ("double-space", "two  spaces  here."),
    # Apostrophes and hyphens are not in the mark list, so they reach espeak.
    ("apostrophes", "don't can't won't it's"),
    ("hyphens", "e-mail re-do well-known"),
    # The words nib's own vocabulary exists for.
    ("technical", "The useMemo hook and the Hasura metadata."),
    # Nothing to say.
    ("empty", ""),
    ("space-only", "   "),
    # Longer than MAX_PHONEME_LENGTH of 510, which is where chunking starts.
    ("long", " ".join(["the quick brown fox jumps over the lazy dog."] * 12)),
]


def main() -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import phonemizer
        from kokoro_onnx.chunker import pause_after, split_phonemes
        from kokoro_onnx.config import MAX_PHONEME_LENGTH
        from kokoro_onnx.tokenizer import Tokenizer
    except ImportError as err:
        print(f"needs the kokoro venv: {err}", file=sys.stderr)
        print("run with voice-server-cloudci/vendor/kokoro-venv/bin/python",
              file=sys.stderr)
        return 1

    # Constructing the Tokenizer is what points phonemizer at the bundled
    # espeak; without it phonemizer reports "espeak not installed".
    tokenizer = Tokenizer()

    from phonemizer.backend.espeak.wrapper import EspeakWrapper
    espeak = EspeakWrapper()
    # Without this every call returns "no voice specified", which records as a
    # string and looks like data. The point of the espeak_only column is to say
    # whether a divergence came from espeak or from the restoration around it,
    # and it cannot do that if it is an error message.
    espeak.set_voice("en-us")

    from phonemizer.punctuation import Punctuation
    punctuation = Punctuation()

    entries = []
    for name, text in CORPUS:
        # What espeak returns on its own, before punctuation is put back. Kept
        # so a divergence can be traced to espeak or to the restoration.
        try:
            raw = espeak.text_to_phonemes(text, None) if text.strip() else ""
        except Exception as err:  # noqa: BLE001 - recorded, not raised
            raw = f"<error: {err}>"

        # The intermediates, which is what makes the Swift port testable without
        # espeak: the chunks punctuation was hidden from, the marks and where
        # they sit, and what espeak returned for each chunk on its own.
        #
        # Per chunk rather than for the whole text, because they differ. espeak
        # stressed "(like this)" as ð_ɪ_s when it saw the brackets and as ðˈɪs
        # when the chunk was handed over alone -- so a port that phonemises once
        # and patches punctuation back in produces different speech.
        # Named apart from the batch split below, which is a different thing
        # cutting the same text for a different reason. Sharing the name once
        # meant this field recorded the batches instead, and the fixture looked
        # plausible: one entry where espeak had produced three.
        #
        # Given the lines rather than the text, because that is what the real
        # path does: phonemize() splits on newlines and drops the blank ones
        # before the backend runs. Calling preserve() on the raw string instead
        # recorded "   " as a chunk to phonemise, which the engine never does.
        lines = [line for line in text.strip("\n").split("\n") if line.strip()]
        preserved, marks = punctuation.preserve(lines)
        chunk_phonemes = []
        for chunk in preserved:
            try:
                chunk_phonemes.append(espeak.text_to_phonemes(chunk, None))
            except Exception as err:  # noqa: BLE001
                chunk_phonemes.append(f"<error: {err}>")

        try:
            full = phonemizer.phonemize(
                text, "en-us", preserve_punctuation=True, with_stress=True)
        except Exception as err:  # noqa: BLE001
            full = f"<error: {err}>"

        kept = tokenizer.phonemize(text, "en-us") if text.strip() else ""
        # kokoro collapses whitespace before tokenising, in _prepare.
        collapsed = " ".join(kept.split())

        # Anything past 510 phonemes is split before it is tokenised, so the
        # batches are the truth rather than one long id list. Short texts
        # produce exactly one batch, which is the same thing said plainly.
        chunks = split_phonemes(collapsed, MAX_PHONEME_LENGTH)
        batches = [
            {
                "phonemes": chunk,
                "token_ids": tokenizer.tokenize(chunk),
                "pause_after": pause_after(chunk, 0.25, 0.1),
            }
            for chunk in chunks
        ]

        entries.append({
            "name": name,
            "text": text,
            "espeak_only": raw,
            "preserved_chunks": preserved,
            "marks": [
                {"line": mark.index, "mark": mark.mark, "position": mark.position}
                for mark in marks
            ],
            "chunk_phonemes": chunk_phonemes,
            "phonemizer": full,
            "phonemes": collapsed,
            "batches": batches,
            "token_count": sum(len(b["token_ids"]) for b in batches),
        })

    fixture = {
        "language": "en-us",
        "espeak_version": ".".join(str(part) for part in espeak.version),
        "with_stress": True,
        "preserve_punctuation": True,
        # The marks phonemizer hides from espeak, verbatim from its source.
        "punctuation_marks": ';:,.!?¡¿—…"«»“”(){}[]',
        "entries": entries,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")

    print(f"wrote {OUTPUT.relative_to(OUTPUT.parent.parent.parent)}")
    print(f"  {len(entries)} texts, espeak {fixture['espeak_version']}")
    longest = max(entries, key=lambda e: e["token_count"])
    print(f"  longest is {longest['name']} at {longest['token_count']} tokens")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
