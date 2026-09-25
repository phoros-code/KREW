"""MJPEG screen streaming with explicit consent gating (Phase 2/3).

Security model (see SECURITY.md — Consent, Secrets & data handling):

- Frames live only in memory: captured via ``mss``, JPEG-encoded with
  Pillow into a ``BytesIO`` buffer, and yielded straight into the HTTP
  response. Frames are NEVER persisted to disk.
- The stream refuses to start until a consent grant has been explicitly
  approved (fail closed). Missing, unknown, pending, denied, or expired
  consent IDs all refuse. Consent IDs are unguessable (uuid4 hex).
- Proximity gating (near-only) is enforced by the route in
  ``server/main.py`` via the existing ``require_near`` dependency — this
  module only handles capture + consent + MJPEG framing.
- A live stream also re-checks its grant on every frame (``consent_valid``
  hook), so an expired grant stops the stream instead of running forever.

Adaptive frame rate: the generator is pull-based — each loop iteration
captures one fresh frame and yields it immediately. There is no queue, so a
slow client simply receives fewer frames (frames are dropped, never
buffered — memory stays bounded at a single frame). After yielding, the
generator sleeps only for the remainder of the target frame interval
(~2 fps idle), so it never busy-spins and never emits catch-up bursts.

v1 limitation (documented in main.py): consent approval is a simple
laptop-side HTTP endpoint. A real OS-level prompt is a v1.1 upgrade.

Response transport note: ``MJPEGResponse`` below subclasses Starlette's
``Response`` (so FastAPI serves it directly) but implements its own
``__call__`` instead of using ``StreamingResponse``. Rationale: Starlette ≥1.x
``StreamingResponse`` blocks on ``await receive()`` (listen_for_disconnect)
before emitting anything, which deadlocks against in-process ASGI test
transports that cannot deliver ``http.disconnect`` until the response
completes. Polling disconnect with a short timeout streams correctly on real
servers (uvicorn delivers disconnect promptly) AND under test transports.
"""

from __future__ import annotations

import asyncio
import logging
import threading
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from io import BytesIO
from typing import Callable, Iterator

from starlette.responses import Response as _StarletteResponse

try:
    from PIL import Image as _PILImage
except ImportError:  # Pillow is a hard dependency (see requirements.txt).
    _PILImage = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

# Multipart framing.
BOUNDARY = "frame"
MJPEG_MEDIA_TYPE = f"multipart/x-mixed-replace; boundary={BOUNDARY}"

# Streaming behaviour.
TARGET_FPS = 2.0  # idle target; slow clients transparently get fewer fps
MAX_CONSECUTIVE_FAILURES = 10  # then stop the stream instead of spinning
JPEG_SOI = b"\xff\xd8"  # every emitted frame must start with this

# Consent lifetimes (seconds, monotonic clock). Grants are deliberately
# short-lived: screen access must be re-approved, not granted forever.
PENDING_TTL_SECONDS = 300.0  # unactioned request expires after 5 min
GRANT_TTL_SECONDS = 900.0  # approved grant expires after 15 min

# Hard cap on consent records. TTL purging bounds lifetime but not count —
# an authenticated caller could otherwise spam /screen/consent to grow
# memory. Eviction is fail-closed (a dropped grant just stops a stream).
MAX_CONSENT_RECORDS = 256


class ConsentStatus(str, Enum):
    PENDING = "pending"
    APPROVED = "approved"
    DENIED = "denied"
    REVOKED = "revoked"  # was APPROVED, pulled back early — fail-closed like DENIED


@dataclass
class _ConsentRecord:
    status: ConsentStatus
    created_at: float


@dataclass
class ConsentManager:
    """Fail-closed consent gate for screen sharing. Thread-safe.

    ``now`` and ``new_id`` are injectable so expiry logic is unit-testable
    without sleeping or monkeypatching globals.
    """

    pending_ttl: float = PENDING_TTL_SECONDS
    grant_ttl: float = GRANT_TTL_SECONDS
    max_records: int = MAX_CONSENT_RECORDS
    now: Callable[[], float] = field(default_factory=lambda: time.monotonic)
    new_id: Callable[[], str] = field(default_factory=lambda: (lambda: uuid.uuid4().hex))
    _records: dict[str, _ConsentRecord] = field(default_factory=dict, init=False, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, init=False, repr=False)

    def start_consent_request(self) -> str:
        """Create a PENDING consent request; returns its unguessable ID."""
        consent_id = self.new_id()
        with self._lock:
            self._purge_locked()
            self._evict_if_full_locked()
            self._records[consent_id] = _ConsentRecord(
                status=ConsentStatus.PENDING, created_at=self.now()
            )
        logger.info("screen consent requested: %s…", consent_id[:8])
        return consent_id

    def approve(self, consent_id: str) -> bool:
        """Approve a pending request. Idempotent for live grants; else False."""
        with self._lock:
            self._purge_locked()
            record = self._records.get(consent_id)
            if record is None:
                return False
            if record.status is ConsentStatus.APPROVED:
                return True  # idempotent re-approve of a live grant
            if record.status is ConsentStatus.PENDING:
                record.status = ConsentStatus.APPROVED
                record.created_at = self.now()  # grant TTL starts at approval
                logger.info("screen consent approved: %s…", consent_id[:8])
                return True
            return False  # DENIED stays denied — must start a new request

    def deny(self, consent_id: str) -> bool:
        """Deny a pending request. Idempotent; False for unknown/approved."""
        with self._lock:
            self._purge_locked()
            record = self._records.get(consent_id)
            if record is None:
                return False
            if record.status is ConsentStatus.DENIED:
                return True
            if record.status is ConsentStatus.PENDING:
                record.status = ConsentStatus.DENIED
                record.created_at = self.now()
                logger.info("screen consent denied: %s…", consent_id[:8])
                return True
            return False  # already APPROVED — deny does not revoke; let it expire

    def revoke(self, consent_id: str) -> bool:
        """Pull back a live grant early (APPROVED → REVOKED). Idempotent.

        Returns False for unknown/expired IDs and for PENDING requests
        (use deny for those) — revocation is strictly a grant operation.
        """
        with self._lock:
            self._purge_locked()
            record = self._records.get(consent_id)
            if record is None:
                return False
            if record.status is ConsentStatus.REVOKED:
                return True
            if record.status is ConsentStatus.APPROVED:
                record.status = ConsentStatus.REVOKED
                record.created_at = self.now()
                logger.info("screen consent revoked: %s…", consent_id[:8])
                return True
            return False

    def status_of(self, consent_id: str) -> ConsentStatus | None:
        """Current status, or None for unknown/expired IDs (fail closed)."""
        if not consent_id:
            return None
        with self._lock:
            self._purge_locked()
            record = self._records.get(consent_id)
            return record.status if record is not None else None

    def is_approved(self, consent_id: str) -> bool:
        """True only for a live APPROVED grant. Everything else is False."""
        return self.status_of(consent_id) is ConsentStatus.APPROVED

    def _evict_if_full_locked(self) -> None:
        """Cap record count so consent-request spam can't grow memory.

        Caller holds _lock. Evicts the oldest non-live record first; only if
        every record is a live APPROVED grant is the oldest grant dropped
        (fail closed — its stream stops on the next per-frame re-check).
        """
        if len(self._records) < self.max_records:
            return
        oldest_pending: str | None = None
        oldest_pending_at = float("inf")
        oldest_at = float("inf")
        oldest_any: str | None = None
        for cid, record in self._records.items():
            if record.created_at < oldest_at:
                oldest_at = record.created_at
                oldest_any = cid
            if record.status is not ConsentStatus.APPROVED and record.created_at < oldest_pending_at:
                oldest_pending_at = record.created_at
                oldest_pending = cid
        victim = oldest_pending if oldest_pending is not None else oldest_any
        if victim is not None:
            del self._records[victim]

    def _purge_locked(self) -> None:
        """Drop expired records so state stays bounded. Caller holds _lock."""
        now = self.now()
        expired = [
            cid
            for cid, record in self._records.items()
            if now - record.created_at
            > (self.grant_ttl if record.status is ConsentStatus.APPROVED else self.pending_ttl)
        ]
        for cid in expired:
            del self._records[cid]


def encode_jpeg_rgb(
    width: int, height: int, rgb: bytes, quality: int = 70, max_width: int = 1280
) -> bytes:
    """Encode raw RGB pixels to JPEG bytes, entirely in memory.

    Downscales to ``max_width`` (aspect preserved) to bound bandwidth —
    a phone preview does not need a full 4K frame at 2 fps.
    """
    if _PILImage is None:
        raise RuntimeError("Pillow is required for JPEG encoding (pip install pillow)")
    if width <= 0 or height <= 0:
        raise ValueError(f"invalid frame size {width}x{height}")
    expected = width * height * 3
    if len(rgb) != expected:
        raise ValueError(f"expected {expected} RGB bytes, got {len(rgb)}")
    img = _PILImage.frombytes("RGB", (width, height), rgb)
    if max_width and width > max_width:
        img = img.resize((max_width, round(height * max_width / width)))
    buf = BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def capture_screen_jpeg(quality: int = 70, max_width: int = 1280) -> bytes:
    """Capture the primary display and return JPEG bytes. Never writes to disk."""
    try:
        import mss
    except ImportError as exc:
        raise RuntimeError("mss is required for screen capture (pip install mss)") from exc
    if _PILImage is None:
        raise RuntimeError("Pillow is required for JPEG encoding (pip install pillow)")
    with mss.mss() as sct:
        monitors = sct.monitors
        # monitors[0] is the virtual screen; monitors[1] is the primary display.
        monitor = monitors[1] if len(monitors) > 1 else monitors[0]
        shot = sct.grab(monitor)
        width, height = shot.width, shot.height
        # shot.raw is BGRA; the Pillow "BGRX" raw decoder ignores the 4th byte
        # (alpha/X) in C — no per-pixel Python loop.
        img = _PILImage.frombytes("RGB", (width, height), bytes(shot.raw), "raw", "BGRX")
        if max_width and width > max_width:
            img = img.resize((max_width, round(height * max_width / width)))
        buf = BytesIO()
        img.save(buf, format="JPEG", quality=quality)
        return buf.getvalue()


def format_frame(jpeg: bytes, boundary: str = BOUNDARY) -> bytes:
    """Wrap one JPEG frame as a multipart/x-mixed-replace chunk."""
    header = (
        f"--{boundary}\r\n"
        f"Content-Type: image/jpeg\r\n"
        f"Content-Length: {len(jpeg)}\r\n\r\n"
    ).encode("ascii")
    return header + jpeg + b"\r\n"


async def _client_gone(receive: Callable[[], object], timeout: float = 0.05) -> bool:
    """Non-blocking disconnect poll. Never hangs: a stalled transport reads as connected."""
    try:
        message = await asyncio.wait_for(receive(), timeout=timeout)
    except (asyncio.TimeoutError, TimeoutError):
        return False
    except Exception:
        return True  # fail closed on transport errors
    return isinstance(message, dict) and message.get("type") == "http.disconnect"


class MJPEGResponse(_StarletteResponse):
    """Multipart MJPEG response with per-frame disconnect + consent checks.

    Subclasses Starlette's Response so FastAPI serves it as-is; streams the
    body manually so no code path ever blocks unconditionally on ``receive()``.
    One frame is pulled per iteration (slow clients drop frames, memory stays
    bounded); the generator is closed on exit so capture stops promptly.
    """

    media_type = MJPEG_MEDIA_TYPE

    def __init__(self, gen_factory: Callable[[], Iterator[bytes]]) -> None:
        super().__init__(content=None, status_code=200, media_type=self.media_type)
        self.gen_factory = gen_factory

    async def __call__(self, scope: object, receive: Callable[[], object], send: Callable[[object], object]) -> None:
        if not isinstance(scope, dict) or scope.get("type") != "http":
            raise RuntimeError("MJPEGResponse requires an HTTP scope")
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [
                    (b"content-type", MJPEG_MEDIA_TYPE.encode("latin-1")),
                    (b"cache-control", b"no-cache"),
                ],
            }
        )
        gen = self.gen_factory()
        try:
            while True:
                if await _client_gone(receive):
                    logger.info("screen stream stopping: client disconnected")
                    break
                chunk = await asyncio.to_thread(next, gen, None)
                if chunk is None:  # exhausted: consent lapsed or capture failing
                    break
                await send({"type": "http.response.body", "body": chunk, "more_body": True})
        finally:
            try:
                gen.close()
            except Exception:
                pass
        await send({"type": "http.response.body", "body": b"", "more_body": False})


def mjpeg_generator(
    capture_fn: Callable[[], bytes] | None = None,
    *,
    target_fps: float | None = None,
    max_frames: int | None = None,
    boundary: str = BOUNDARY,
    consent_valid: Callable[[], bool] | None = None,
) -> Iterator[bytes]:
    """Yield MJPEG multipart chunks, one fresh frame per iteration.

    - Pull-based: no queue exists, so a slow client drops frames instead of
      growing memory. At most one frame is ever in flight.
    - Sleeps only the remainder of the frame interval (no catch-up bursts).
    - Stops (instead of spinning) after ``MAX_CONSECUTIVE_FAILURES``
      capture failures, or as soon as ``consent_valid`` returns False.
    - ``max_frames`` is a test/seeding hook; production callers leave it None.
    """
    fps = TARGET_FPS if target_fps is None else target_fps
    interval = 1.0 / fps if fps and fps > 0 else 0.0
    capture = capture_fn if capture_fn is not None else capture_screen_jpeg
    failures = 0
    sent = 0
    while max_frames is None or sent < max_frames:
        if consent_valid is not None and not consent_valid():
            logger.info("screen stream stopping: consent no longer valid")
            break
        start = time.monotonic()
        try:
            jpeg = capture()
            if not jpeg or not jpeg.startswith(JPEG_SOI):
                raise ValueError("capture did not return JPEG data")
        except Exception:
            failures += 1
            logger.warning("screen capture failed (%d/%d)", failures, MAX_CONSECUTIVE_FAILURES)
            if failures >= MAX_CONSECUTIVE_FAILURES:
                logger.error("screen stream stopping: too many capture failures")
                break
            time.sleep(interval if interval > 0 else 0.5)
            continue
        failures = 0
        yield format_frame(jpeg, boundary)
        sent += 1
        elapsed = time.monotonic() - start
        if interval > elapsed:
            time.sleep(interval - elapsed)
