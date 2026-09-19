# Testing strategy

## What must have automated tests (no exceptions)

These are the modules where "it worked when I tried it" isn't good enough — see `SECURITY.md` for why.

- `buddy_core/tools/shell.py` — allowlist matches, denylist blocks (including denylist winning over an allowlist match), command injection attempts via crafted arguments
- `buddy_core/tools/files.py` — path traversal attempts (`../`, absolute paths, symlink tricks) all rejected; writes outside `~/buddy-workspace` rejected
- `server/auth.py` — valid token accepted, invalid/expired token rejected, rate limiting kicks in after N failed attempts, idle timeout actually expires a session
- `server/main.py` proximity gating — a "far" mode request to a near-only endpoint returns 403, not 200
- `buddy_core/agents/planner.py` — plan size cap and recursion depth cap are actually enforced, not just configured

## What gets tested with mocks, not live services

- `buddy_core/tools/web_search.py` — mock the HTTP call; also test that a page containing "ignore previous instructions"–style text is treated as plain content, not followed
- `voice/stt.py` — use a fixture `.wav` file with known expected transcription, no live mic needed
- `voice/tts.py` — assert the output file is non-empty and plausible-duration for the input text length
- `server/main.py` — FastAPI's `TestClient` covers routing/auth/proximity logic without a real network

## What needs manual or hardware-in-the-loop testing

Don't try to force these into pytest — verify them by hand, but track that you did:

- `voice/wake.py` — real wake-word detection with your actual mic, in your actual room
- The full voice loop end to end, out loud
- Bluetooth RSSI thresholds — these need calibration against your specific phone and laptop hardware, not a fixed number
- MJPEG screen/webcam streaming — verify visually, and verify the consent prompt actually blocks the stream until accepted
- TLS setup — verify the phone app actually rejects an untrusted cert, don't just assume `mkcert` wired correctly

## UI testing

- Run the self-audit checklist in `UI_UX_GUIDE.md` against every screen before merging — treat it like a lint pass, not optional polish.
- Verify empty and error states actually render correctly, not just the happy path — this is easy to skip and it's specifically the thing that gives away an unfinished/AI-generated feel.

## Before each phase checkpoint (from `PROMPTS.md`)

Run the **full** test suite, not just tests for what you just built — regressions in `shell.py` or `auth.py` from an unrelated change are exactly the kind of thing that's easy to miss otherwise.

## CI suggestion

A minimal GitHub Actions workflow: `pytest` on every push, plus a `pip-audit` step. Add a Flutter `flutter test` step once the mobile app exists. Keep it fast enough that you actually run it before every phase checkpoint, not just before a release.
