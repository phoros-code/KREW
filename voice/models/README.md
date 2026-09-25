# Training a custom "maxy" wake-word model

> Status: **NOT TRAINED YET.** Until `maxy.onnx` exists in this folder,
> the voice loop uses the `"alexa"` stand-in
> (`voice/wake.py::DEFAULT_WAKE_WORD`, `config/models.yaml → wake.stand_in`).
> That is intentional wiring, not the product name.

This folder currently holds **TTS** assets (`en_US-lessac-medium.onnx` —
Piper voice, unrelated to wake-word). The wake-word model will live here as:

```
voice/models/maxy.onnx       # the trained model
voice/models/maxy.onnx.json  # sidecar ("<model path>" + ".json")
```

`voice/wake.py::resolve_wake_models()` auto-picks `maxy.onnx` the moment
both files are present — no code change needed. Verify with:

```powershell
.\venv312\Scripts\python.exe -m voice.wake
# expect: "wake: using custom maxy model (...)"
# today:  "wake: using alexa stand-in (train maxy per voice/models/README.md)"
```

## 1. Data requirements (the part that needs a human)

Collect **50–100 clips of someone saying "maxy"** plus negatives:

| Set | Location | Contents | Format |
|-----|----------|----------|--------|
| Positives | `voice/training/maxy/positives/*.wav` | 50–100 utterances of **"maxy"**, several speakers if possible, quiet + realistic rooms | 16 kHz, mono, 16-bit WAV, 1–2 s each |
| Negatives | `voice/training/maxy/negatives/*.wav` | Other speech, silence, room noise, TV/music background | same format, a few minutes total |

Tips: varied distance (0.5 m / 2 m / 4 m), varied rooms, some clips with
background noise. More speakers = fewer false rejects on guests.

Check what you have:

```powershell
.\venv312\Scripts\python.exe scripts/train_wakeword.py
```

The stub counts your clips and tells you exactly what is missing.
It never fakes training — with no data it exits non-zero.

## 2. Train

Training needs **torch** (NOT in the default `venv312` — it ships inference
deps only: `openwakeword`, `onnxruntime`). Either:

**Option A — local (GPU recommended):**

```powershell
.\venv312\Scripts\python.exe -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu121
# 1. Write a training config (see openwakeword.train --help for fields:
#    target_phrase, n_samples, output_dir, model_name, rir/background paths, ...)
# 2. Run the upstream trainer:
.\venv312\Scripts\python.exe -m openwakeword.train --training_config voice/training/maxy/training.yaml --generate_clips --augment_clips --train_model
```

**Option B — upstream Colab notebook** (easiest, no local torch):
use the official openWakeWord custom-model notebook, upload your
`positives/` + `negatives/`, train, and download the resulting model.

## 3. Place the outputs

Copy the trained artifacts here with EXACTLY these names:

```
<trainer output>/maxy.onnx      →  voice/models/maxy.onnx
<trainer output>/maxy.onnx.json →  voice/models/maxy.onnx.json
```

(`maxy.onnx.json` is the sidecar — same basename plus `.json`.
`voice/wake.py::CUSTOM_WAKE_MODEL_JSON` points at it.)
Do NOT commit fake bytes: a placeholder file that is not a real trained
model will fail loudly inside onnxruntime instead of silently degrading.

## 4. Verify

```powershell
.\venv312\Scripts\python.exe -c "import voice.wake; print(voice.wake.resolve_wake_models())"
# → ['...\\voice\\models\\maxy.onnx']

.\venv312\Scripts\python.exe -m voice.wake
# say "maxy" → WAKE DETECTED
```

Threshold tuning lives in `config/models.yaml → wake.threshold`
(default `0.5`): lower = more sensitive (more false alarms), higher =
stricter (more missed wakes). Change it there, never in code.
