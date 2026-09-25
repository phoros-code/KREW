# Hardware Verification Checklist — Everyday Buddy v0.1.0

> Run on Windows 11 from the repo root: `C:\Users\hiren\OneDrive\Desktop\ME\maxxy` (branch `master`).
> Phone and laptop must be on the **same LAN/Wi-Fi**. Do not commit anything in this session.
> Key repo facts this checklist is built from: wake word `hey_buddy` (`voice/wake.py`);
> default Piper voice `voice/models/en_US-lessac-medium.onnx` (`voice/tts.py`);
> server TLS on port `8443` (`scripts/serve.ps1`, `config/security.yaml.example`);
> pairing outputs LAN IP + token + cert fingerprint (`scripts/pair_device.py`);
> consent endpoints `POST /screen/consent`, `POST /screen/consent/{id}/approve`,
> `POST /screen/consent/{id}/deny`, `GET /screen?consent_id=…` (`server/main.py`);
> Preview tab never auto-starts (`mobile/lib/widgets/screen_preview.dart`);
> pairing-screen Bluetooth field with hint `AA:BB:CC:DD:EE:FF (Android) or UUID (iOS)`
> (`mobile/lib/screens/pairing_screen.dart`); NEAR/FAR pill in the 56px `StatusHeader`
> (`mobile/lib/widgets/status_header.dart`); threshold lives in
> `config/security.yaml` → `proximity.rssi_near_threshold` (default `-60`).
> Items marked **[UNVERIFIED — not in repo]** are inferences or OS/browser-dependent
> and were filled in so you can execute without other docs.

## 0. Prerequisites (do these first — nothing below works without them)

- [ ] 0.1 Laptop: Windows 11, repo at `C:\Users\hiren\OneDrive\Desktop\ME\maxxy`, branch `master`, `git status --short` clean.
- [ ] 0.2 Python env: `venv312\` exists. Prefer it for everything: `.\venv312\Scripts\python.exe`. (Fallback in `scripts/serve.ps1`: `%LOCALAPPDATA%\Programs\Python\Python312\python.exe`.)
- [ ] 0.3 Ollama running at `http://localhost:11434` with at least one model pulled (`qwen2.5:3b` for fast iteration, `llama3.1:8b` target). The full voice loop calls `orchestrator.run()`, which needs the LLM. Start it before §1 step 5.
- [ ] 0.4 Flutter SDK at `C:\src\flutter` (SDK 3.47.5 known-good here). App installed on a physical phone from this source (Android needs the Android SDK / Android Studio on the build machine; `flutter doctor` reports NO Android SDK on the dev laptop).
- [ ] 0.5 **App namespace MUST already be renamed from `com.example.*`. Device builds refuse placeholder namespaces.** Still `com.example.*` in this tree at time of writing — rename (e.g. `com.yourname.everydaybuddy`) in `mobile/android/app/build.gradle*` + `mobile/ios/Runner/*` BEFORE building to the phone. Verify with a search that no `com.example` remains.
- [ ] 0.6 **Bluetooth ID format: Android uses the laptop's MAC (`AA:BB:CC:DD:EE:FF`); iOS uses a UUID, not a MAC.** Enter exactly what the OS shows (see §3). A MAC pasted on iOS (or UUID on Android) will never match — the watch stays FAR by design.
- [ ] 0.7 TLS certs exist: `certs\dev-cert.pem` + `certs\dev-key.pem`. If missing, generate first (zero-dependency fallback, or mkcert per SECURITY.md):
  `powershell -ExecutionPolicy Bypass -File scripts\gen_cert.ps1`
  PASS: prints `wrote certs/dev-cert.pem + certs/dev-key.pem` plus a `SHA256 fingerprint:` line.
- [ ] 0.8 Same Wi-Fi on laptop + phone. No port forwarding. Keep the laptop screen visible (you approve consent there).

---

## 1. Voice demo (mic + wake word + full loop, out loud)

Repo: `pip install -e .[voice]` provides `openwakeword`, `faster-whisper`, `piper-tts` (+ `pyaudio` for the mic). Default voice per `voice/tts.py` is `en_US-lessac-medium`.

- [x] 1.1 Install voice extras (user-confirmed done 2026-09-26) (prefer `venv312`), from the repo root:
  `.\venv312\Scripts\python.exe -m pip install -e .[voice]`
  PASS: pip completes with no errors; `.\venv312\Scripts\python.exe -c "import openwakeword, faster_whisper, piper, pyaudio; print('voice deps ok')"` prints `voice deps ok`. **[UNVERIFIED — not in repo]**: the exact import names for the smoke check; if one name fails, re-run pip and continue — the procedure below is the real test.
- [x] 1.2 Download the repo's default Piper voice (user-confirmed done 2026-09-26) into `voice\models\` (both files, side by side):
  `New-Item -ItemType Directory -Path voice\models -Force | Out-Null;`
  `Invoke-WebRequest -Uri "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" -OutFile "voice\models\en_US-lessac-medium.onnx";`
  `Invoke-WebRequest -Uri "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json" -OutFile "voice\models\en_US-lessac-medium.onnx.json";`
  `Get-ChildItem voice\models\en_US-lessac-medium.onnx*`
  PASS: both files exist and are non-empty (tens of MB `.onnx` + small `.json`). **[UNVERIFIED — not in repo]**: the `.onnx.json` URL is inferred (repo comment gives only the `.onnx` URL plus "the matching .onnx.json config beside it"); if the second download 404s, open the folder page `https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_US/lessac/medium` in a browser and download the matching `.onnx.json` by hand.
- [x] 1.3 Mic check. (user-confirmed done 2026-09-26) **[UNVERIFIED — not in repo]**: the repo has no mic-check command — this step is OS procedure only. Windows Settings → System → Sound → Input: confirm your microphone appears and the input-level bar moves when you speak. Then in PowerShell:
  `.\venv312\Scripts\python.exe -c "import pyaudio; a=pyaudio.PyAudio(); print('inputs:', [a.get_device_info_by_index(i)['name'] for i in range(a.get_device_count()) if a.get_device_info_by_index(i)['maxInputChannels']>0]); a.terminate()"`
  PASS: at least one input device name prints. If the list is empty, fix Windows mic privacy (Settings → Privacy → Microphone → allow desktop apps) and retry.
- [x] 1.4 Wake-word test: (user-confirmed done 2026-09-26)
  `.\venv312\Scripts\python.exe -m voice.wake`
  Say the wake word out loud (the cue the code listens for is `hey_buddy` — say "hey buddy" clearly toward the mic, normal room, ~1 m distance).
  PASS: terminal prints `WAKE DETECTED` within the 120 s window and exits 0. FAIL = `timed out, no wake word heard` (exit 1): move closer, reduce background noise/TV, confirm the mic from 1.3 is the Windows default, retry.
- [x] 1.5 Full loop test (needs Ollama from prerequisite 0.3 + speakers on): (user-confirmed done 2026-09-26)
  `.\venv312\Scripts\python.exe -m voice.voice_loop` **[UNVERIFIED — not in repo]**: the exact `-m voice.voice_loop` invocation is implied by `voice/voice_loop.py:main()` ("Run the always-on loop"), not spelled out in the repo.
  Flow: say "hey buddy", wait for the record window (6 s per `RECORD_SECONDS`), speak one command (e.g. "what time is it"), then listen.
  PASS (what "pass" sounds like): you HEAR a spoken reply through the speakers (a real answer, or the designed fallbacks `Sorry, I didn't catch that.` / `Sorry, something went wrong handling that.`), AND the terminal prints `buddy: <reply text>`. A fallback reply still PASSES the audio path (mic→STT→orchestrator→TTS→speakers); silence, a traceback, or a hang FAILS. Ctrl+C stops the loop.

---

## 2. Phone-on-LAN HTTPS check (`/health` from the phone browser)

- [x] 2.1 Start the server (TLS, LAN-bound) from the repo root: (user-confirmed done 2026-09-26)
  `powershell -ExecutionPolicy Bypass -File scripts\serve.ps1`
  PASS: uvicorn serves on `0.0.0.0:8443` with `--ssl-certfile certs\dev-cert.pem --ssl-keyfile certs\dev-key.pem` (never use `-AllowPlainHttp` for a phone — that flag serves loopback plain HTTP for dev only).
- [x] 2.2 In a SECOND terminal, print pairing info: (user-confirmed done 2026-09-26)
  `.\venv312\Scripts\python.exe scripts\pair_device.py`
  PASS: prints `=== Everyday Buddy pairing ===` with `LAN IP(s) : <e.g. 192.168.1.10>`, `Port      : 8443 (https)`, `Token     : <long token>`, `Cert SHA256: <hex>`. Write down the first LAN IP and the fingerprint. If it prints `(no cert yet — run scripts/gen_cert.ps1)`, do prerequisite 0.7.
- [x] 2.3 On the phone (same Wi-Fi), open the phone browser to exactly: (user-confirmed done 2026-09-26)
  `https://<ip-from-2.2>:8443/health` (substitute the IP, e.g. `https://192.168.1.10:8443/health`)
  PASS: after accepting/warning through the cert (see §4), the page shows exactly `{"status": "ok"}`. FAIL ("success vs distrust" split):
  - Success = the JSON above (server reachable over LAN TLS).
  - Cert distrust = a full-page interstitial warning (wording varies — see §4) with NO JSON. That warning is EXPECTED for the self-signed dev cert and proves TLS is on; only proceed past it deliberately for this test.
  - Any timeout / `ERR_CONNECTION_REFUSED` / `unreachable` = FAIL: wrong IP, different Wi-Fi, Windows Firewall blocking 8443, or `serve.ps1` not running. Fix and retry.
- [x] 2.4 Keep the server running for §4 and §5. (user-confirmed done 2026-09-26)

---

## 3. BLE calibration (laptop BT id → pairing screen → walk test → threshold)

Goal: pick `rssi_near_threshold` (dBm) for YOUR hardware. Repo default is `-60`; `TESTING.md` says thresholds need per-hardware calibration, not a fixed number.

- [ ] 3.1 Read the laptop's Bluetooth id in OS settings. **[UNVERIFIED — not in repo]**: the repo says only "Find the ID in the laptop OS Bluetooth settings; the laptop must stay discoverable or paired" — the exact path below is Windows procedure. Windows 11: Settings → Bluetooth & devices → Devices → (your laptop's own adapter / paired-device details) and copy the address. Android testers copy the `AA:BB:CC:DD:EE:FF` MAC; iPhone testers copy the UUID-style id iOS shows. The laptop must stay discoverable (or paired with the phone) or the phone sees no advertisements.
- [ ] 3.2 Enter it on the phone: open the app → Pair tab → `Laptop Bluetooth ID (optional)` field (hint text: `AA:BB:CC:DD:EE:FF (Android) or UUID (iOS)`) → type the id exactly (case-insensitive match, but copy it verbatim) → `Test connection and save`. Blank disables the BLE watch (proximity then follows server responses only).
  PASS: pairing validates and saves; the app's `GET /proximity` fetch applies the server threshold. (App wiring: BLE watch starts only when server `mode` is `lan_plus_bluetooth` AND an id is saved — otherwise it stays off, fail-closed.)
- [ ] 3.3 Walk-away / walk-back protocol (needs `proximity.mode: "lan_plus_bluetooth"` in `config/security.yaml` — set it and restart `serve.ps1` if it still says `lan_only`):
  1. Stand next to the laptop (~0.5 m), Bluetooth on, app open. Note the header pill (see 3.4).
  2. Walk away in ~2 m steps to ~10 m / another room, pausing ~20 s at each stop (stale window is 15 s — wait it out so a stale→null→FAR transition can happen).
  3. Walk back the same way, same pauses.
  4. At each stop record: distance + pill state (NEAR/FAR) + what you were doing (door open/closed, phone in hand vs pocket).
  PASS: pill flips to FAR as you leave and back to NEAR when you return, consistently at roughly the same distance both directions.
- [ ] 3.4 Where the phone surfaces live RSSI. **[UNVERIFIED — not in repo — UI gap flagged]**: verified in `status_header.dart` / `proximity_service.dart` that the ONLY live surface is the 56px `StatusHeader` pill: `NEAR` (green, `lock_open`) vs `FAR` (amber, `lock_outline`), plus connection `ONLINE`/`OFFLINE`/`CONNECTING` and the `IDLE`/`N RUNNING` task summary. No screen in the current app displays the numeric dBm value (`lastRssi` is stored and sent as the decorative `X-RSSI` header on `/command`, never rendered). So "logged values" for calibration = YOUR walk-test notes from 3.3 (distance ↔ NEAR/FAR flip point), not an in-app log. If you need raw dBm, use a generic BLE-scanner app side by side (outside this repo) and note the dBm at the flip point.
- [ ] 3.5 Pick the threshold and set it. Rule: threshold = the dBm measured (or inferred) at the distance where you want the NEAR/FAR boundary, rounded 3–5 dB toward the weaker side so the boundary is stable (e.g. flips observed around −68 dBm → set `−65`). Edit `config/security.yaml` (copy from `config/security.yaml.example` if absent — `security.yaml` is gitignored, never commit it):
  `proximity: { mode: "lan_plus_bluetooth", rssi_near_threshold: <your value>, fail_mode: "far" }`
  (Keep `fail_mode: "far"` — never `"near"`.) Restart `serve.ps1`.
  PASS: `GET /proximity` (authenticated) returns your value, e.g. `{"mode": "lan_plus_bluetooth", "rssi_near_threshold": -65}`.
- [ ] 3.6 Re-verify: repeat the 3.3 walk test.
  PASS: boundary now sits where you want it (desk = NEAR, hallway/other room = FAR), no flapping between the two at a fixed spot. If it flaps, move the threshold 3 dB weaker and repeat.
- [ ] 3.7 Second-device confirmation (both platforms must be exercised — Android
  MAC matching and iOS UUID matching are different ID formats through the same
  `BleProximityReader` gate, and a format bug on one won't surface on the other).
  Full calibration (§3.3–§3.6) on whichever phone is more convenient first; then
  on the second phone: pair it (same LAN IP + token, its own BT id — MAC on
  Android, UUID on iOS), stand next to the laptop (~0.5 m) and confirm the header
  pill reads NEAR, walk ~8–10 m / another room, wait ~20 s (stale window is
  15 s), and confirm it flips to FAR, then walk back and confirm NEAR again.
  PASS: NEAR→FAR→NEAR transition fires at all on the second device. No separate
  threshold needed — same server `rssi_near_threshold` applies to both; this step
  proves the second ID-format path works, not that it shares the same boundary.

---

## 4. TLS cert rejection check (untrusted cert must warn; pin must match)

- [ ] 4.1 With the server from §2 running, on the phone browser open `https://<ip>:8443/health` fresh (new tab / clear the earlier exception if the browser offers "remember").
  PASS (untrusted-cert behavior): the browser BLOCKS with a full-page warning before showing anything — wording is browser-dependent **[UNVERIFIED — not in repo]**, e.g. Chrome `Your connection is not private / NET::ERR_CERT_AUTHORITY_INVALID`, Firefox `Warning: Potential Security Risk Ahead`, Safari `This Connection Is Not Private`. A silent load with no warning on a self-signed dev cert = FAIL (something is not serving your cert — check `serve.ps1` used the `certs\` files).
- [ ] 4.2 Confirm the pin/fingerprint verification is working: on the warning page open Advanced → view certificate → compare its SHA-256 fingerprint with the laptop output of `.\venv312\Scripts\python.exe scripts\pair_device.py` (`Cert SHA256: <hex>`).
  PASS: the two fingerprints match character-for-character (this is the trust decision: matching = this laptop, mismatch = stop, regenerate via `scripts\gen_cert.ps1` and re-pair). Note: `scripts\gen_cert.py` prints the fingerprint as raw hex while `gen_cert.ps1` prints the Windows thumbprint form — compare modulo formatting (ignore `:`/case), and treat `pair_device.py`'s `Cert SHA256:` line as canonical.
- [ ] 4.3 In the app: pair with a wrong token once → PASS = human error state (`Pairing failed`, e.g. wrong-token / unreachable guidance, never raw JSON). Then pair with the real IP + token → PASS = app pairs and Chat/Tasks connect.

---

## 5. Consent-gated stream check (`/screen` must NEVER autostart)

Exact tap sequence is verified in `preview_screen.dart` + `screen_preview.dart`; server rules in `server/main.py` (`consent_required` / `consent_denied` 403s) and `server/streams.py` (grant TTL 15 min, per-frame re-check). **[UNVERIFIED — not in repo — implementation gap flagged]**: the current phone build's `checkScreen()` performs `GET /screen` with NO `consent_id`, so against the current server it always gets `403 consent_required` and can never reach `200 available`; the app also has no `POST /screen/consent` button — the consent request below must be issued with `curl` (laptop side) until the app wires the consent endpoints. Test the GATE as written, not as wished.

- [ ] 5.1 No-autostart check: pair the app, keep it NEAR (same Wi-Fi; `lan_only` mode counts LAN arrival as near), bottom nav → `Screen` tab (title `Laptop screen`, subtitle `Near-only, consent-gated live view. Nothing starts until you ask it to.`).
  PASS: the tab shows the consent card with the button `I understand — start preview` and NO network/stream activity — no spinner, no image, no `Requesting preview…`. Opening the tab alone must never call `/screen`. (FAR state instead shows `Preview unavailable while FAR`; unpaired shows `No laptop paired yet` — both also prove no autostart.)
- [ ] 5.2 Consent request (laptop `curl` — replace `<ip>` and `<token>` with the §2 values; PowerShell quoting):
  `$h = @{"Authorization"="Bearer <token>"};`
  `Invoke-RestMethod -Uri "https://<ip>:8443/screen/consent" -Method Post -Headers $h -SkipCertificateCheck`
  PASS: `{"consent_id": "<hex>", "status": "pending"}`. Copy the `consent_id`. (Failing with `403 forbidden` = you are FAR — fix proximity first. This endpoint is near-only.)
- [ ] 5.3 Before-approval gate (must be empty): still on the laptop,
  `Invoke-RestMethod -Uri "https://<ip>:8443/screen?consent_id=<consent_id>" -Headers $h -SkipCertificateCheck`
  PASS: HTTP 403 with `{"error": {"code": "consent_required", ...}}` — ZERO `/screen` bytes flow before approval. Any image bytes here = FAIL (fail-closed broken).
- [ ] 5.4 Approve → stream starts. On the phone tap `I understand — start preview` (documents user intent), then on the laptop approve the SAME id:
  `Invoke-RestMethod -Uri "https://<ip>:8443/screen/consent/<consent_id>/approve" -Method Post -Headers $h -SkipCertificateCheck`
  PASS: `{"consent_id": "<same>", "status": "approved"}`, and re-running the §5.3 `GET /screen?consent_id=…` now returns 200 MJPEG bytes (`multipart/x-mixed-replace`). In the current app build the card may still read `Preview failed` (it never sends the id — the §5 gap above) — the SERVER gate passing (403→200 across approve) is the PASS criterion for this checklist.
- [ ] 5.5 Deny path (fresh request): create a second consent (`§5.2` again → `<id2>`), then
  `Invoke-RestMethod -Uri "https://<ip>:8443/screen/consent/<id2>/deny" -Method Post -Headers $h -SkipCertificateCheck`
  PASS: `{"status": "denied"}` and `GET /screen?consent_id=<id2>` → 403 `{"error": {"code": "consent_denied", ...}}`. The phone card must never show imagery for a denied id.
- [ ] 5.6 Expiry note: approved grants expire after 15 min (`GRANT_TTL_SECONDS = 900` in `server/streams.py`) and live streams re-check every frame — a stream that stops at ~15 min is correct behavior; re-request consent.
- [ ] 5.7 Revoke path (live grant): approve a fresh request (§5.2 → approve as in §5.4), confirm `GET /screen?consent_id=…` streams 200, then revoke it:
  `Invoke-RestMethod -Uri "https://<ip>:8443/screen/consent/<consent_id>/revoke" -Method Post -Headers $h -SkipCertificateCheck`
  PASS: `{"status": "revoked"}`, and re-running the same `GET /screen?consent_id=…` now returns 403 `{"error": {"code": "consent_denied", ...}}`. Revocation takes effect on the next frame re-check, so a live stream stops within ~1 frame interval. (Server-verified 2026-09-25 via curl: 403 → approved → revoked → 403; revoke is idempotent, revoke-on-pending is 409, unknown id is 404.)

---

## Sign-off

- [ ] All boxes in §0–§5 checked, or each unchecked box has a named owner + return date.
- [ ] `git status --short` still clean apart from untracked `HARDWARE_VERIFICATION.md` (this file). No code, config, or cert files modified/committed.
- [ ] Remaining v0.1.0 gates (outside this file): device run on a real phone, Phase 4 items above, final SECURITY.md + UI-audit pass, tag `v0.1.0`.
