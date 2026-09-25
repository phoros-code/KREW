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

## `GET /proximity`

**Proximity: near or far.** Authenticated, read-only proximity config for the
phone's near/far indicator (Phase 4): the phone fetches this once after
pairing and applies `rssi_near_threshold` locally to its BLE RSSI readings.
Non-sensitive by construction (mode + threshold only — never the token).
Readable in FAR mode on purpose: the indicator needs the threshold most
when far.

```json
{ "mode": "lan_plus_bluetooth", "rssi_near_threshold": -60 }
```

## `POST /proximity/threshold`

**Proximity: near only.** Updates the BLE RSSI near threshold (`dBm`).

Request (strict: must be JSON `int` type — floats, numeric strings, and
bools are rejected — and satisfy `-100 <= value <= -30`, else `400`):
```json
{ "rssi_near_threshold": -65 }
```

Response (persists to `security.yaml`; subsequent `GET /proximity`
returns the new value without a restart):
```json
{ "mode": "lan_plus_bluetooth", "rssi_near_threshold": -65 }
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

On connect, the server replays the **last 200 events** (bounded — a phone
reconnecting after days offline must not get the whole log dumped on it;
full-history-with-pagination is a v1.1 feature), then follows new lines
until the client disconnects. An attached stream counts as activity for the
idle timeout — passive followers don't get bricked mid-session.

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

Multipart MJPEG stream of the laptop's primary display, adaptive frame rate (see `PROJECT_SPEC.md` → Risks, battery drain mitigation). One `mss.mss()` handle per stream (opened once, closed on disconnect); caps: 1 concurrent stream per consent id + 4 per client IP (excess → 429 `stream_limit` + `Retry-After`).

Consent flow (Track A3, BREAKING — laptop-only approval):

- `POST /screen/consent` (phone-token + near) → `{"consent_id": "<hex>", "status": "pending"}`
- `POST /screen/consent/{id}/approve` (laptop-only: loopback `127.0.0.1`/`::1` OR `X-Buddy-Approval` matching `auth.consent_approval_secret` via constant-time compare; phone-token-only → 403 `approval_forbidden`) → `{"status": "approved"}` (409 if denied)
- `POST /screen/consent/{id}/deny` (same laptop-only rule as approve) → `{"status": "denied"}` (409 if already approved — deny does not revoke)
- `POST /screen/consent/{id}/revoke` (phone-token + near — stays phone-gated so fail-closed stop always works) → `{"status": "revoked"}` — pulls back a live grant early; takes effect on the next frame re-check. Idempotent; 409 if the request is still pending, 404 for unknown/expired ids.
- `GET /screen?consent_id=…` (or `X-Consent-Id` header) → 200 MJPEG while approved; 403 `consent_required` pre-approval/unknown, 403 `consent_denied` after deny **or revoke**. Grants expire after 15 min (`streams.grant_ttl_seconds`).

## `GET /webcam` (MJPEG)

**Proximity: near only.** Requires its own explicit on-device consent flow —
a `/screen` approval must NEVER authorize `/webcam` and vice versa (separate
consent scopes server-side; a grant from one flow returns 403
`consent_required` on the other stream).

Multipart MJPEG stream of the laptop webcam (one `cv2.VideoCapture` per
stream, opened once, released on disconnect; JPEG-encoded in memory, never
persisted — same transport and adaptive frame rate as `/screen`). Same
caps as `/screen`: 1 per consent id + 4 per IP (429 `stream_limit`).

Consent flow (Track A3, same laptop-only approval rule as `/screen`):

- `POST /webcam/consent` (phone-token + near) → `{"consent_id": "<hex>", "status": "pending"}`
- `POST /webcam/consent/{id}/approve` (laptop-only: loopback OR `X-Buddy-Approval`; phone-only → 403 `approval_forbidden`) → `{"status": "approved"}` (409 if denied)
- `POST /webcam/consent/{id}/deny` (same laptop-only rule) → `{"status": "denied"}` (409 if already approved — deny does not revoke)
- `POST /webcam/consent/{id}/revoke` (phone-token + near) → `{"status": "revoked"}` — pulls back a live grant early; takes effect on the next frame re-check. Idempotent; 409 if the request is still pending, 404 for unknown/expired ids.
- `GET /webcam?consent_id=…` (or `X-Consent-Id` header) → 200 MJPEG while approved; 403 `consent_required` pre-approval/unknown/cross-scope, 403 `consent_denied` after deny **or revoke**. Grants expire after 15 min.

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

429 carries either `locked_out` (too many bad tokens — wait out
`lockout_minutes`) or `rate_limited` (over `network.rate_limit_per_minute`
requests from your IP — wait per the `Retry-After` header and retry) or
`stream_limit` (too many concurrent MJPEG streams: 1 per consent id + 4
per IP — wait per `Retry-After` and retry; the existing stream keeps its
slot until it disconnects).

403 on approve/deny carries `approval_forbidden` when the caller has a valid
phone token but is not loopback and did not present the laptop-only
`X-Buddy-Approval` secret (Track A3) — approve from the laptop (loopback
curl or the secret header), not from the phone.

Design the phone app's error *states* for each of these — see `UI_UX_GUIDE.md`, "design real error states" — rather than surfacing the raw JSON.
