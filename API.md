# API reference

Control server endpoints. Every endpoint except `/health` requires the pairing token — see `SECURITY.md` → Authentication. All traffic is TLS.

## Auth

Send the token as a bearer header on every request:

```
Authorization: Bearer <token>
```

Requests without a valid token get `401`. Requests from a device in "far" proximity mode to a "near"-only endpoint get `403` — see the proximity table below.

## `GET /health`

Unauthenticated. Returns only whether the server is up — nothing about the agent's state, tasks, or configuration.

```json
{ "status": "ok" }
```

## `POST /command`

**Proximity: near only.**

Submits a command to the orchestrator.

Request:
```json
{ "text": "research best free local LLMs for 16GB RAM" }
```

Response:
```json
{ "task_id": "b7e1...", "status": "queued" }
```

## `GET /events` (SSE)

**Proximity: near or far.** This is the one endpoint "far" mode still gets — notifications only, no control.

Streams agent lifecycle events as Server-Sent Events, tailing `logs/events.jsonl`.

```
event: task_started
data: {"task_id": "b7e1...", "text": "research best free local LLMs..."}

event: tool_call
data: {"task_id": "b7e1...", "tool": "web_search", "args": {"query": "..."}}

event: task_completed
data: {"task_id": "b7e1...", "result": "..."}

event: task_failed
data: {"task_id": "b7e1...", "error": "..."}
```

## `GET /screen` (MJPEG)

**Proximity: near only.** Requires the explicit on-device consent flow described in `SECURITY.md` before the stream starts — don't wire this to auto-start on connect.

Multipart MJPEG stream of the laptop's primary display, adaptive frame rate (see `PROJECT_SPEC.md` → Risks, battery drain mitigation).

## `GET /webcam` (MJPEG/WebRTC)

**Proximity: near only.** Same consent requirement as `/screen`. Optional feature — omit entirely if you don't need it for v1.

## Proximity gating summary

| Endpoint | Near | Far |
|---|---|---|
| `/health` | ✅ | ✅ |
| `/events` | ✅ | ✅ (notifications only) |
| `/command` | ✅ | ❌ |
| `/screen` | ✅ | ❌ |
| `/webcam` | ✅ | ❌ |

If proximity can't be determined, the server defaults to **far** — see `SECURITY.md` → Authorization: proximity gating.

## Error format

All error responses follow the same shape so the phone app can handle them uniformly:

```json
{ "error": { "code": "unauthorized", "message": "Invalid or expired token" } }
```

401 carries either `unauthorized` (bad/unknown token) or `token_expired`
(the pairing token reached its absolute age — re-pair from the laptop).
The phone app treats **any** 401 from `/command` or `/events` as "show the
re-pair prompt" directly, without waiting for a `token_expired` SSE frame
(which itself requires auth to receive).

Design the phone app's error *states* for each of these — see `UI_UX_GUIDE.md`, "design real error states" — rather than surfacing the raw JSON.
