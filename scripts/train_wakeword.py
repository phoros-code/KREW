"""Guided stub for training the custom "maxy" wake-word model (Sprint 2.1).

This script does NOT train anything — there is no honest way to train a
wake-word model without 50-100 labeled "maxy" clips the user has not
provided yet. It validates prerequisites, reports exactly what is missing,
and prints the real next steps.

Usage:
    .\\venv312\\Scripts\\python.exe scripts/train_wakeword.py [--clips-dir DIR]

Exits 0 only when the data prerequisites look satisfied (training itself
still has to be run via openwakeword.train or the upstream notebook —
see voice/models/README.md). Exits 1 with a helpful message otherwise.
Never writes .onnx bytes.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CLIPS_DIR = REPO_ROOT / "voice" / "training" / "maxy"
MIN_POSITIVE_CLIPS = 50


def _count_wavs(directory: Path) -> int:
    if not directory.is_dir():
        return 0
    return sum(1 for p in directory.iterdir() if p.suffix.lower() == ".wav" and p.is_file())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--clips-dir",
        default=str(DEFAULT_CLIPS_DIR),
        help="Directory holding positives/ + negatives/ clip folders.",
    )
    args = parser.parse_args(argv)
    clips_dir = Path(args.clips_dir)

    positives = clips_dir / "positives"
    negatives = clips_dir / "negatives"
    n_pos = _count_wavs(positives)
    n_neg = _count_wavs(negatives)

    print(f"clips dir: {clips_dir}")
    print(f"  positives: {n_pos} wav(s) in {positives} (need >={MIN_POSITIVE_CLIPS})")
    print(f"  negatives: {n_neg} wav(s) in {negatives} (need >=1)")

    if n_pos < MIN_POSITIVE_CLIPS or n_neg < 1:
        print(
            "\nNOT READY — training data missing. Next steps:\n"
            "  1. Record 50-100 clips of someone saying \"maxy\"\n"
            "     (16 kHz mono 16-bit WAV, 1-2 s each, several speakers/rooms)\n"
            f"     into: {positives}\\\n"
            "  2. Add background/other-speech WAVs (same format) into:\n"
            f"     {negatives}\\\n"
            "  3. Re-run this script to re-check.\n"
            "  4. Full procedure: voice/models/README.md\n"
            "  Until then the \"alexa\" stand-in remains active — by design.",
            file=sys.stderr,
        )
        return 1

    print(
        "\nData prerequisites look satisfied. THIS STUB DOES NOT TRAIN.\n"
        "Real training (needs torch, not in the default env):\n"
        "  1. Install torch, then write voice/training/maxy/training.yaml\n"
        "     (target_phrase=maxy, output_dir, model_name=maxy, ...)\n"
        "  2. Run:\n"
        "       python -m openwakeword.train"
        " --training_config voice/training/maxy/training.yaml"
        " --generate_clips --augment_clips --train_model\n"
        "  3. Copy outputs to voice/models/maxy.onnx + voice/models/maxy.onnx.json\n"
        "  4. Verify:  python -m voice.wake   (say \"maxy\")\n"
        "  Details: voice/models/README.md"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
