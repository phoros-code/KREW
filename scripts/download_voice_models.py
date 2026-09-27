"""Download Piper TTS voice models into voice/models/ (step 1.2).

Fetches the default en_US-lessac-medium voice (both the .onnx model and its
.onnx.json sidecar) from the rhasspy/piper-voices HuggingFace repo using the
standard library only — no new dependencies.

Usage:
    python scripts/download_voice_models.py                    # default voice
    python scripts/download_voice_models.py --force            # re-download
    python scripts/download_voice_models.py --voice en_US-ryan-high
    python scripts/download_voice_models.py --out-dir /tmp/voices
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

# Layout inside rhasspy/piper-voices: <lang>/<lang>_<REGION>/<quality>/<file>
# e.g. en/en_US/lessac/medium/en_US-lessac-medium.onnx (+ .onnx.json sidecar)
_HF_BASE = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

DEFAULT_VOICE = "en_US-lessac-medium"
DEFAULT_OUT_DIR = Path(__file__).resolve().parent.parent / "voice" / "models"
DOWNLOAD_TIMEOUT = 300


def model_urls(voice_name: str = DEFAULT_VOICE) -> tuple[str, str]:
    """Return (onnx_url, json_url) for a '<lang>_<REGION>-<name>-<quality>' voice."""
    try:
        lang_region, _name, _quality = voice_name.split("-", 2)
        lang, region = lang_region.split("_", 1)
    except ValueError as exc:
        raise ValueError(
            f"Voice name {voice_name!r} must look like 'en_US-lessac-medium'"
        ) from exc
    base = f"{_HF_BASE}/{lang}/{lang_region}/{_name}/{_quality}/{voice_name}"
    return base + ".onnx", base + ".onnx.json"


def download(url: str, dest: Path, timeout: int = DOWNLOAD_TIMEOUT) -> int:
    """Fetch url to dest (stdlib urllib). Returns bytes written. Raises on HTTP error."""
    req = urllib.request.Request(url, headers={"User-Agent": "everyday-buddy/voice-setup"})
    dest.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if getattr(resp, "status", 200) >= 400:
            raise RuntimeError(f"HTTP {resp.status} fetching {url}")
        expected = resp.headers.get("Content-Length")
        with open(dest, "wb") as fh:
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                fh.write(chunk)
                total += len(chunk)
                print(f"\r  {dest.name}: {total / 1024 / 1024:.1f} MB", end="", flush=True)
        print()
    if expected is not None and total != int(expected):
        raise RuntimeError(
            f"Short download for {dest.name}: got {total} bytes, expected {expected}"
        )
    if total == 0:
        raise RuntimeError(f"Empty download for {url}")
    return total


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Download Piper TTS voice models.")
    parser.add_argument("--voice", default=DEFAULT_VOICE, help="Voice name (default: %(default)s).")
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR), help="Target directory.")
    parser.add_argument("--force", action="store_true", help="Re-download existing files.")
    parser.add_argument("--timeout", type=int, default=DOWNLOAD_TIMEOUT, help="Seconds per file.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        onnx_url, json_url = model_urls(args.voice)
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    out_dir = Path(args.out_dir)
    targets = [
        (onnx_url, out_dir / f"{args.voice}.onnx"),
        (json_url, out_dir / f"{args.voice}.onnx.json"),
    ]
    for url, dest in targets:
        if dest.exists() and dest.stat().st_size > 0 and not args.force:
            print(f"SKIP: {dest} exists ({dest.stat().st_size} bytes) — use --force to re-fetch.")
            continue
        print(f"Fetching {url}")
        try:
            size = download(url, dest, timeout=args.timeout)
        except Exception as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
        print(f"wrote {dest} ({size} bytes)")
    print(f"PASS: {args.voice} ready in {out_dir} (.onnx + .onnx.json side by side).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
