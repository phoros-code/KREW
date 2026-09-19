# Everyday Buddy — Project Specification

Version: 1.1 (corrected) · Original: v1.0, Sept 19, 2026
License recommendation: MIT or Apache 2.0 (fully free, permissive)
Project identity: "Everyday Buddy" (codename: `buddy-core`) — a personal, local-first, multi-agent AI assistant.

> This is a corrected markdown version of the original PDF spec. Changes from v1.0 are noted inline as `> Correction:` blocks — mainly license-table fixes and two prior-art claims that needed softening after verification. Nothing about the architecture or roadmap changed.

## Executive summary

Everyday Buddy is a free, open-source, local-first multi-agent AI assistant designed to run on your laptop and be controlled/notified from your phone. Inspired by the general concept of a personal AI assistant, it intentionally avoids cloud dependency. It combines:

- Local LLM inference (Ollama) with multi-agent orchestration (CrewAI / LangGraph / AutoGen)
- Fully offline voice interface (wake word → STT → LLM → TTS)
- Phone companion app for remote command, task monitoring, notifications, and optional screen/webcam viewing
- Proximity-aware access control (LAN-only + optional Bluetooth RSSI gating)
- Tool-using agents for coding, research, automation, and system tasks

**Key differentiator:** an action-taking assistant that can open apps, type, browse, code, execute commands, and recover from failures — while staying 100% local and free.

---

## 1. Prior art & competitive analysis

### 1.1 Has anyone built this before?

Yes. Several 2025–2026 projects overlap with parts of this design.

**AnovaX** (arXiv:2607.15367, submitted 16 Jul 2026) — the closest relative. A local, multi-agent voice assistant:
- Runs entirely on the user's computer
- Wake-word gate → speech pipeline → LLM planner (Gemini) → safety filter → multi-agent orchestrator with typed child agents (AppAgent, TypingAgent, BrowserAgent, and others)
- Adaptive recovery loop for failed steps
- Flask server mirroring agent events to phone via SSE, streaming the laptop screen via MJPEG
- PIN-based auth
- Author-noted limitations: the executor is "blind" (no screen-content verification, uses pyautogui without checking effects); it depends on Gemini and Google speech recognition (not fully local); the MJPEG stream leaks full screen content to any authenticated phone; multi-agent scope is deliberately small (bounded worker/agent counts, capped recursion depth)

**Relevance:** proves the core pattern works. Everyday Buddy adapts it but replaces the cloud LLM/STT with fully local models, strengthens security (TLS, per-session tokens, rate limiting), and adds explicit proximity gating.

**OpenAkita** (GitHub, AGPL-3.0-only) — a broader multi-agent AI assistant framework with desktop/web/mobile apps, 30+ LLM providers (including local options), a plugin architecture (89+ tools), and messaging-platform integration (WeChat, Feishu, Telegram, etc. via QR pairing). More complex and geared toward multi-agent "AI company" orchestration and IM integration than a single-user local buddy.

**AI Assistant for Android** (`souravanand001/ai-assistant-android`, GitHub) — an offline-capable Android voice assistant using on-device ML (MediaPipe text classification, TensorFlow Lite, Sherpa-ONNX for VAD/STT/TTS), encrypted local storage, and screen-context capture.
> Correction: the repo's default LLM backend is Groq (cloud); it exposes a pluggable LLM adapter that may support custom/local endpoints, but Ollama support specifically is not confirmed as of this writing — treat it as "likely possible," not settled. Focuses on phone-only assistance; Everyday Buddy extends the same on-device pattern to laptop-centric agents with the phone as remote.

**OpenClaw** (self-hosted personal AI, GitHub) — an open-source personal AI assistant with a local **Gateway** (WebSocket control plane) and companion apps for macOS/iOS/Android, reachable through the messaging platforms you already use (WhatsApp, Telegram, Slack, Discord, etc.).
> Correction: OpenClaw's Gateway is local-first in that it runs on your own machine and holds session/config state locally, but by default it routes conversations to **cloud LLM providers** (Claude, GPT, etc.) via API rather than running local inference — it is not "local inference" in the same sense as Everyday Buddy. The original spec's claim of mDNS/Bonjour-based companion-app pairing is unconfirmed; treat that detail as unverified rather than a documented feature. It remains genuinely more messaging-centric than Everyday Buddy, which is the useful point of comparison.

**Local AI agent resources & frameworks:** CrewAI, LangGraph, AutoGen, OpenHands, Goose, and others are all open-source agent harnesses that run with local LLMs via Ollama. Multiple public guides exist for fully-local voice stacks (Whisper/faster-whisper + Piper/Kokoro + Ollama).

**Conclusion:** the core ideas are validated by multiple 2025–2026 projects, especially AnovaX. No single project matches this exact combination (fully free, fully local, laptop-centric, phone-controlled, proximity-aware, multi-agent) — but every building block exists and is open source.

---

## 2. System architecture

### 2.1 High-level components

```
+-------------------+          +---------------------------+
|   Phone (iOS/     |  Wi-Fi   |   Laptop (buddy-core)      |
|   Android)        | <------> |                            |
|                    |  LAN     |  - Ollama (LLM server)     |
| - Companion App    |  + BT    |  - Agent Orchestrator      |
| - Chat/voice UI    |          |    (CrewAI/LangGraph)      |
| - Task dashboard   |          |  - Voice loop              |
| - Screen preview   |          |    (wake, STT, TTS)        |
| - Webcam preview   |          |  - Tool executors          |
| - Proximity UI     |          |    (code, browser, shell)  |
+-------------------+          |  - FastAPI server           |
                                |    (commands, events,      |
                                |     screen/webcam stream)   |
                                +---------------------------+
```

### 2.2 Core modules (laptop)

1. **LLM runtime** — Ollama running a local model (e.g. `llama3.1:8b`, `qwen2.5:7b`, or smaller if hardware requires). Exposes `http://localhost:11434` for agent frameworks.
2. **Multi-agent orchestrator** — Framework: CrewAI (recommended) or LangGraph/AutoGen. Agent roles: `PlannerAgent` (decomposes tasks, coordinates others), `CoderAgent` (writes/refactors code, runs linters/tests), `ResearchAgent` (web search, page fetch, summarization), `ExecutorAgent` (safe shell commands, file ops, app launching). Tools: web search, file I/O, restricted shell, browser automation (Playwright), screen capture.
3. **Voice interface** — Wake word: openWakeWord or ViolaWake. STT: faster-whisper or whisper.cpp. TTS: Piper (recommended) or Kokoro. Loop: listen for wake word → record → transcribe → send to agent → speak response.
4. **Control server (phone ↔ laptop)** — FastAPI or Flask with `POST /command`, `WS /events` or `SSE`, `GET /screen` (MJPEG), `GET /webcam` (MJPEG/WebRTC). Token-based auth, optional PIN. LAN-only by default; firewall restricts to local subnet. Full reference: `API.md`.
5. **Proximity & security layer** — LAN-only access as coarse proximity. Optional Bluetooth RSSI: phone and laptop measure RSSI, thresholds define "near" vs. "far"; "far" mode is notifications-only. TLS (self-signed certs) on all endpoints, token rotation, rate limiting, idle timeouts. Full detail: `SECURITY.md`.

### 2.3 Phone companion app

Platform: Flutter or React Native (cross-platform), or native Kotlin/Swift. Features: pairing screen (laptop IP + token), chat/voice UI, task dashboard (live status, logs), screen preview (MJPEG), webcam preview (optional), proximity indicator (Wi-Fi + BT status), notifications (in-app, optional FCM for background). UI/UX standards for this app: `UI_UX_GUIDE.md` and `DESIGN.md`.

---

## 3. Feature specification

### 3.1 Core capabilities

- **Task completion** — e.g. "Research best free local LLMs for a 16 GB RAM laptop and summarize," "Create a Python script that fetches weather and saves to CSV," "Open VS Code, create a new file, scaffold a FastAPI app."
- **Internet access** — web search via DuckDuckGo HTML or self-hosted SearXNG; page fetch and summarization.
- **Laptop automation** — open apps, type text, press keys, take screenshots; run allowlisted shell commands; manage files in designated directories.
- **Coding** — generate, refactor, debug code; run tests/linters in a sandbox.
- **Voice & text control** — wake word + voice commands; typed commands from desktop UI or phone.
- **Phone control & notifications** — send commands from phone; live task progress and logs; notifications on task start/complete/fail; optional screen/webcam view.
- **Proximity-aware access** — full control when "near" (same LAN + BT threshold); notifications-only when "far."

### 3.2 Non-goals (for v1)

- True human-level general intelligence
- Multi-user / org orchestration
- Cloud fallback (must be 100% local in v1)
- Complex UI automation beyond basic `pyautogui` (no deep accessibility-tree integration initially)

---

## 4. Technology stack (100% free)

| Layer | Technology | License | Notes |
|---|---|---|---|
| LLM runtime | Ollama | MIT | Local model server |
| Agent framework | CrewAI (or LangGraph/AutoGen) | MIT | Multi-agent orchestration |
| Wake word | openWakeWord / ViolaWake | **Apache 2.0** | Custom wake words, offline |
| STT | faster-whisper / whisper.cpp | MIT | Local transcription |
| TTS | Piper / Kokoro | MIT | Local speech synthesis |
| Control server | FastAPI / Flask | **MIT** (FastAPI) / BSD (Flask) | REST + WS/SSE + MJPEG |
| Mobile app | Flutter / React Native | BSD | Cross-platform UI |
| Screen capture | mss / pyautogui | **MIT** (mss) / BSD (pyautogui) | Periodic screenshots |
| Webcam | OpenCV | Apache 2.0 | Frame capture & streaming |
| Browser automation | Playwright | Apache 2.0 | Web research & actions |

> Correction from v1.0: openWakeWord and ViolaWake are Apache 2.0, not MIT. FastAPI is MIT, not BSD. `mss` is MIT, not BSD. All corrected licenses remain fully permissive — this doesn't change the "100% free" claim, just the exact terms.

All components are open source with permissive licenses; no paid APIs required.

---

## 5. Security & privacy model

Full detail lives in `SECURITY.md` — this section is the summary.

- **Data locality** — all inference, logs, and memory stored on the laptop; the phone holds no persistent conversation history (optional cache only).
- **Authentication** — one-time pairing generates a token on the laptop, stored on the phone; required on every `/command`, `/events`, `/screen`, `/webcam` request.
- **Transport** — TLS (self-signed or mkcert) on all HTTP/WS/MJPEG traffic.
- **Authorization** — proximity mode gates access: "near" = full API access, "far" = `/events` (notifications) only.
- **Safety filters** — tool whitelist (only allowlisted tools callable), command denylist (blocks destructive patterns), plan size caps (max steps, max recursion depth).
- **User consent** — explicit prompts before screen sharing, webcam access, or destructive file/shell operations.

---

## 6. Implementation roadmap

See `PROMPTS.md` for the fully expanded, prompt-by-prompt version of this roadmap.

- **Phase 0 — Foundations (1–2 days):** Ollama + a single CrewAI agent with web search, restricted shell, and file tools. Deliverable: `buddy "research local LLMs"` prints a summary.
- **Phase 1 — Voice loop (2–3 days):** openWakeWord + faster-whisper + Piper wired into `voice_loop.py`. Deliverable: speak "Hey Buddy, what's the weather?" → hear a spoken answer.
- **Phase 2 — Control server (2–3 days):** FastAPI server with `/command`, `/events` (SSE), `/screen` (MJPEG), token auth, TLS, JSONL event logging. Deliverable: send a command from a phone browser on the same Wi-Fi and see live logs.
- **Phase 3 — Mobile app MVP (3–5 days):** Flutter app with pairing, chat, task list, MJPEG screen preview. Deliverable: phone app sends commands and views the laptop screen.
- **Phase 4 — Proximity & polish (2–3 days):** Bluetooth RSSI near/far logic, notifications, security hardening (rate limits, idle timeouts). Deliverable: full MVP.

---

## 7. File structure (suggested)

```
everyday-buddy/
├── buddy_core/
│   ├── agents/
│   │   ├── planner.py
│   │   ├── coder.py
│   │   ├── researcher.py
│   │   └── executor.py
│   ├── tools/
│   │   ├── web_search.py
│   │   ├── shell.py
│   │   ├── files.py
│   │   └── screen.py
│   ├── memory/
│   │   └── memory.py
│   └── orchestrator.py
├── voice/
│   ├── wake.py
│   ├── stt.py
│   ├── tts.py
│   └── voice_loop.py
├── server/
│   ├── main.py       # FastAPI
│   ├── auth.py
│   └── streams.py    # screen/webcam
├── mobile/
│   └── (Flutter app)
├── config/
│   ├── models.yaml
│   ├── tools.yaml
│   └── security.yaml
├── scripts/
│   ├── setup.sh
│   └── pair_device.py
├── CLAUDE.md
├── PROJECT_SPEC.md
├── ARCHITECTURE.md
├── SECURITY.md
├── UI_UX_GUIDE.md
├── DESIGN.md
├── CONFIG.md
├── API.md
├── TESTING.md
├── PROMPTS.md
├── CONTRIBUTING.md
└── README.md
```

---

## 8. Risks & mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Local models too slow on your hardware | High | Use smaller models (3B–8B), quantized; offload heavy research to batch mode |
| `pyautogui` fragility (wrong window focus) | Medium | Add focus checks, small delays, optional window-title polling |
| Security on untrusted networks | High | Enforce LAN-only by default; require TLS; document risks clearly (see `SECURITY.md`) |
| Battery drain on phone (continuous streaming) | Medium | Let the user pause screen/webcam streams; use adaptive frame rates |
| Complexity creep | Medium | Stick to MVP scope; defer advanced features (full UI perception) to v2 |

---

## 9. How this differs from existing projects

- **vs. AnovaX:** fully local (no Gemini/Google STT); stronger security model (TLS, token rotation, proximity gating); explicit phone-first UX.
- **vs. OpenAkita:** simpler, single-user, local-first; no org orchestration or IM scan-to-bind; focused on laptop automation + phone remote, not multi-IM chat.
- **vs. AI Assistant Android:** laptop-centric agents with phone as remote, not phone-only assistant; multi-agent orchestration for complex tasks.
- **vs. OpenClaw:** local inference by default rather than routing to a cloud LLM provider; direct laptop automation + phone remote rather than multi-channel messaging.

## 10. Next steps

1. Confirm your hardware (OS, CPU/GPU, RAM) to choose the right model size.
2. Decide on agent framework (CrewAI recommended for simplicity).
3. Start with Phase 0 (`PROMPTS.md`) and iterate.
