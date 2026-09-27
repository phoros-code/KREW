"""Microphone check for the voice loop (HARDWARE_VERIFICATION.md step 1.3).

Lists every pyaudio input device, then records a short sample from the
default mic (or --device-index) and reports the RMS level — silence reads
~0, speech reads in the hundreds/thousands. Nothing is saved.

Usage:
    python scripts/mic_check.py                 # list + 2s default-mic test
    python scripts/mic_check.py --list-only     # just list inputs
    python scripts/mic_check.py --device-index 1 --seconds 3
"""

from __future__ import annotations

import argparse
import audioop
import sys

SAMPLE_RATE = 16000
SAMPLE_SECONDS = 2
FRAMES_PER_BUFFER = 1024

# RMS below this on a 2s sample almost certainly means a muted/disabled mic
# or the wrong device — speech at normal volume reads 10-100x higher.
SILENCE_RMS_WARN = 50


def _load_pyaudio():
    try:
        import pyaudio
    except ImportError as exc:
        raise RuntimeError(
            "pyaudio not installed — run: pip install -e .[voice]"
        ) from exc
    return pyaudio


def list_inputs(pyaudio_mod=None) -> list[dict]:
    """Return one dict per input-capable device: index, name, channels, rate."""
    pa = pyaudio_mod or _load_pyaudio()
    audio = pa.PyAudio()
    try:
        found = []
        for i in range(audio.get_device_count()):
            info = audio.get_device_info_by_index(i)
            if info.get("maxInputChannels", 0) > 0:
                found.append(
                    {
                        "index": i,
                        "name": info.get("name", f"device {i}"),
                        "channels": info.get("maxInputChannels"),
                        "default_rate": int(info.get("defaultSampleRate", SAMPLE_RATE)),
                    }
                )
        return found
    finally:
        audio.terminate()


def record_sample(
    seconds: int = SAMPLE_SECONDS,
    device_index: int | None = None,
    sample_rate: int = SAMPLE_RATE,
    pyaudio_mod=None,
) -> bytes:
    """Record mono 16-bit PCM from the mic. Needs a real mic — not for pytest."""
    pa = pyaudio_mod or _load_pyaudio()
    audio = pa.PyAudio()
    kwargs: dict = {
        "format": pa.paInt16,
        "channels": 1,
        "rate": sample_rate,
        "input": True,
        "frames_per_buffer": FRAMES_PER_BUFFER,
    }
    if device_index is not None:
        kwargs["input_device_index"] = device_index
    stream = audio.open(**kwargs)
    frames: list[bytes] = []
    try:
        for _ in range(int(sample_rate / FRAMES_PER_BUFFER * seconds)):
            frames.append(stream.read(FRAMES_PER_BUFFER, exception_on_overflow=False))
    finally:
        stream.stop_stream()
        stream.close()
        audio.terminate()
    return b"".join(frames)


def rms_level(pcm16: bytes) -> float:
    """RMS level of mono 16-bit PCM. Speech ≈ hundreds–thousands; silence ≈ 0."""
    if not pcm16:
        return 0.0
    return float(audioop.rms(pcm16, 2))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check the microphone for the voice loop.")
    parser.add_argument("--list-only", action="store_true", help="List input devices and exit.")
    parser.add_argument("--device-index", type=int, default=None, help="pyaudio input device index.")
    parser.add_argument("--seconds", type=int, default=SAMPLE_SECONDS, help="Sample length (default: 2).")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        devices = list_inputs()
    except RuntimeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    if not devices:
        print("FAIL: pyaudio found no input devices.")
        print("Windows: Settings → Privacy → Microphone → allow desktop apps, then retry.")
        return 1
    print(f"Found {len(devices)} input device(s):")
    for d in devices:
        print(f"  [{d['index']}] {d['name']} ({d['channels']}ch, {d['default_rate']}Hz)")
    if args.list_only:
        return 0
    if args.device_index is not None and all(d["index"] != args.device_index for d in devices):
        print(f"FAIL: --device-index {args.device_index} is not an input device (see list above).")
        return 1
    print(f"\nRecording {args.seconds}s — speak at normal volume…")
    try:
        pcm = record_sample(args.seconds, device_index=args.device_index)
    except Exception as exc:
        print(f"FAIL: recording failed: {exc}")
        return 1
    level = rms_level(pcm)
    print(f"Captured {len(pcm) / 2 / SAMPLE_RATE:.1f}s of audio, RMS level: {level:.0f}")
    if level < SILENCE_RMS_WARN:
        print("WARN: near silence — mic may be muted, wrong device, or privacy-blocked.")
        print("Windows: Settings → System → Sound → Input: confirm the level bar moves.")
        return 2
    print("PASS: mic is capturing audio. The voice loop (python -m voice.voice_loop) can hear you.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
