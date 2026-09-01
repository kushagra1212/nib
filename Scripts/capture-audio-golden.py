#!/usr/bin/env python3
"""Capture what the model returns for one known input, before anything else.

    Scripts/capture-audio-golden.py

The existing kokoro-golden.json records `kokoro.create(...)`, which is the whole
pipeline: inference, then trimming the silence the model leaves at each end,
then inserting pauses at punctuation. Comparing against that would test three
things at once and blame the wrong one.

This runs onnxruntime directly on inputs that are already verified -- the 53
token ids the tokeniser produces, and the 256-float style row the voice pack
reader returns -- so the only thing it can disagree about is the inference.

Padding matters and is easy to miss: the model is fed [0, *tokens, 0]. Without
the zeros every utterance loses a phoneme at each end, which sounds like a
clipped recording rather than a wrong input.
"""

import hashlib
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
MODELS = Path.home() / "code/per/voice-server-cloudci/vendor/kokoro-models"
OUTPUT = HERE.parent / "Tests/Fixtures/audio-golden.json"

# From Tests/Fixtures/kokoro-golden.json, which the Swift tokeniser reproduces.
TOKENS = [81, 83, 16, 53, 65, 156, 102, 53, 16, 44, 123, 156, 43, 135, 56, 16,
          48, 156, 69, 158, 53, 61, 16, 46, 147, 156, 138, 55, 58, 61, 16, 157,
          57, 135, 64, 85, 16, 81, 83, 16, 54, 156, 47, 102, 68, 51, 16, 46,
          156, 69, 158, 92, 4]
VOICE = "af_heart"
SPEED = 1.0

# The count nib ships, and not a detail. Reductions run in a different order per
# thread count, so the same input at 2 threads and at 4 produces different
# samples -- indistinguishable by ear, different by hash. Captured at nib's own
# setting so the comparison can be exact rather than approximate.
#
# See KokoroEngine.threads for why it is 2.
INTRA_OP_THREADS = 2


def main() -> int:
    try:
        import onnxruntime as ort
    except ImportError as err:
        print(f"needs the kokoro venv: {err}", file=sys.stderr)
        return 1

    model = MODELS / "kokoro-v1.0.onnx"
    voices = MODELS / "voices-v1.0.bin"
    for path in (model, voices):
        if not path.exists():
            print(f"missing {path}", file=sys.stderr)
            return 1

    options = ort.SessionOptions()
    options.intra_op_num_threads = INTRA_OP_THREADS
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = ort.InferenceSession(str(model), options)
    inputs = {node.name: node for node in session.get_inputs()}
    token_input = "input_ids" if "input_ids" in inputs else "tokens"

    # One style row per token count, indexed from zero.
    style = np.asarray(np.load(voices)[VOICE][len(TOKENS) - 1], dtype=np.float32)

    outputs = session.run(None, {
        token_input: np.array([[0, *TOKENS, 0]], dtype=np.int64),
        "style": style,
        "speed": np.array([SPEED], dtype=np.float32),
    })
    audio = np.asarray(outputs[0], dtype=np.float32).ravel()

    fixture = {
        "onnxruntime_version": ort.__version__,
        "intra_op_threads": INTRA_OP_THREADS,
        "model": model.name,
        "voice": VOICE,
        "speed": SPEED,
        "token_ids": TOKENS,
        "token_input_name": token_input,
        "output_name": session.get_outputs()[0].name,
        "style_row": len(TOKENS) - 1,
        "style_sha256": hashlib.sha256(style.tobytes()).hexdigest(),
        "sample_count": int(audio.size),
        "sha256_float32_le": hashlib.sha256(audio.tobytes()).hexdigest(),
        # Individual numbers too, so a mismatch reads as a number rather than
        # as a hash that differs.
        "first_8": [float(x) for x in audio[:8]],
        "last_8": [float(x) for x in audio[-8:]],
        "peak": float(np.max(np.abs(audio))),
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")

    print(f"wrote {OUTPUT.relative_to(OUTPUT.parent.parent.parent)}")
    print(f"  onnxruntime {ort.__version__}, input {token_input}, "
          f"{INTRA_OP_THREADS} threads")
    print(f"  {audio.size} samples, peak {fixture['peak']:.4f}")
    print(f"  sha256 {fixture['sha256_float32_le'][:16]}…")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
