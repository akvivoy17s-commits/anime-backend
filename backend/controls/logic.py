"""Pure rules for settings + sessions (no Firebase / HTTP imports, so they are unit-testable)."""
from __future__ import annotations

from datetime import datetime
from typing import Any, Iterable, Optional

# ---- session timing --------------------------------------------------------
HEARTBEAT_SEC = 60        # the app pings every minute while it is open
SESSION_TTL_SEC = 180     # no ping for 3 minutes (3 missed pings) => session is expired/inactive
DOC_RETENTION_SEC = 86400  # `expireAt` on session docs (enable a Firestore TTL policy on it)

# ---- settings --------------------------------------------------------------
MIN_LIMIT = 1
MAX_LIMIT = 10000
DEFAULT_SETTINGS: dict[str, Any] = {"maxConcurrentUsers": 100, "allowDownloads": True}


def normalize_settings(raw: Optional[dict]) -> dict:
    """Stored doc -> safe settings. Missing / corrupt values fall back to the defaults."""
    raw = raw or {}
    limit = raw.get("maxConcurrentUsers")
    if isinstance(limit, bool) or not isinstance(limit, int) or not (MIN_LIMIT <= limit <= MAX_LIMIT):
        limit = DEFAULT_SETTINGS["maxConcurrentUsers"]
    allow = raw.get("allowDownloads")
    if not isinstance(allow, bool):
        allow = DEFAULT_SETTINGS["allowDownloads"]
    return {"maxConcurrentUsers": limit, "allowDownloads": allow}


# ---- sessions --------------------------------------------------------------
def session_key(uid: str, device_id: str) -> str:
    return f"{uid}_{device_id}"


def is_fresh(last_seen: Optional[datetime], cutoff: datetime) -> bool:
    return last_seen is not None and last_seen > cutoff


def active_user_ids(session_docs: Iterable[dict], exclude_uid: Optional[str] = None) -> set[str]:
    """Distinct NON-admin users that have an active session (admins are exempt from the limit)."""
    out: set[str] = set()
    for d in session_docs:
        uid = d.get("uid")
        if uid and not d.get("isAdmin") and uid != exclude_uid:
            out.add(uid)
    return out


def decide_start(is_admin: bool, own_session_active: bool, other_active_users: int, limit: int) -> bool:
    """May this device hold a session?

    * admins are always allowed (otherwise the admin could lock themselves out);
    * a session that is already active is only refreshed - lowering the limit never kicks anyone out;
    * otherwise there must be a free slot. Several devices of ONE user share that user's slot.
    """
    if is_admin or own_session_active:
        return True
    return other_active_users < limit
