#!/usr/bin/env python3
"""Capture what the Python engine reads out of voices-v1.0.bin, as a fixture.

    Scripts/capture-voice-golden.py [path/to/voices-v1.0.bin]

The voice pack decides how nib sounds. It is a 28MB zip of 54 numpy arrays,
each (510, 1, 256) float32, and synthesis uses exactly one row of 256 floats
from one of them -- picked by the number of tokens in the sentence.

Reading it natively is easy to get subtly wrong: the row index is off by one
from the token count, and a wrong row is not an error. It is the right voice
with the wrong intonation, which sounds like a worse model rather than a bug.

So this records what numpy returns for three rows chosen to catch that:
the first row, the last row, and the row the golden sentence uses. The Swift
reader is compared against these rather than against a reading of the format.

The reference setup this reads from was deleted on 2026-09-03, once nib had
replaced it. Everything it produced is committed under Tests/Fixtures, so the
tests do not need it -- but regenerating a fixture does. To rebuild it:

    python3.12 -m venv /tmp/kokoro-venv
    /tmp/kokoro-venv/bin/pip install kokoro-onnx phonemizer espeakng-loader \
        onnxruntime==1.29.0 numpy soundfile
    # models from https://github.com/thewh1teagle/kokoro-onnx/releases
    #   model-files-v1.0/kokoro-v1.0.onnx and voices-v1.0.bin

Then run this with that interpreter, passing the model directory where a path
is taken. Pin onnxruntime to 1.29.0: the audio fixture is compared bit for bit
and another build produces different samples.
"""

import hashlib
import json
import sys
import zipfile
from pathlib import Path

import numpy as np

DEFAULT_SOURCE = Path.home() / (
    "code/per/voice-server-cloudci/vendor/kokoro-models/voices-v1.0.bin"
)
OUTPUT = Path(__file__).resolve().parent.parent / "Tests/Fixtures/voices-golden.json"

# The golden sentence tokenises to 53 ids, and kokoro_onnx indexes the style
# with `voice[min(len(tokens), len(voice)) - 1]`.
GOLDEN_TOKEN_COUNT = 53


def row(voices, name: str, index: int) -> dict:
    flat = np.asarray(voices[name][index], dtype=np.float32).ravel()
    return {
        "voice": name,
        "row": index,
        "count": int(flat.size),
        "first_4": [float(x) for x in flat[:4]],
        "last_4": [float(x) for x in flat[-4:]],
        "sha256_float32_le": hashlib.sha256(flat.tobytes()).hexdigest(),
    }


def main() -> int:
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SOURCE
    if not source.exists():
        print(f"no voice pack at {source}", file=sys.stderr)
        print("pass the path to voices-v1.0.bin", file=sys.stderr)
        return 1

    archive = zipfile.ZipFile(source)
    names = sorted(entry[: -len(".npy")] for entry in archive.namelist())
    voices = np.load(source)
    shape = voices[names[0]].shape

    fixture = {
        "source": source.name,
        "sha256_file": hashlib.sha256(source.read_bytes()).hexdigest(),
        "voice_count": len(names),
        "voices": names,
        "rows": int(shape[0]),
        "style_dimensions": int(shape[-1]),
        # Every entry is stored rather than deflated, which is why the Swift
        # reader can seek to a row instead of decompressing 28MB to reach it.
        "all_entries_stored": all(
            info.compress_type == zipfile.ZIP_STORED for info in archive.infolist()
        ),
        "samples": [
            # The row the golden sentence uses. Off by one from its token count.
            row(voices, "af_heart", GOLDEN_TOKEN_COUNT - 1),
            # A different voice at the first row, so reading the wrong entry in
            # the archive fails rather than passing on af_heart's numbers.
            row(voices, "am_adam", 0),
            # The last row, which is also where anything longer than 510 clamps.
            row(voices, "af_heart", int(shape[0]) - 1),
        ],
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")

    print(f"wrote {OUTPUT.relative_to(OUTPUT.parent.parent.parent)}")
    print(f"  {len(names)} voices, {shape[0]} rows of {shape[-1]} floats")
    print(f"  stored, not deflated: {fixture['all_entries_stored']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
