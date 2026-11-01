"""Settings / sessions / admin-users / download-permission API.

  Any signed-in user : POST /session/start  /session/heartbeat  /session/end   GET /settings
                       POST /downloads/authorize
  Admin only         : GET  /admin/users   GET/PUT /admin/settings
Every route verifies the Firebase ID token; admin routes also check users/{uid}.role == 'admin' (see drive_agent.auth).
"""
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Path, Query

from drive_agent.auth import require_admin, require_user

from .logic import HEARTBEAT_SEC, SESSION_TTL_SEC
from .models import DownloadAuthReq, SessionReq, SettingsPatch, UserDownloadsReq
from .store import get_store

router = APIRouter(tags=["controls"])

DOWNLOADS_OFF = "Downloads are currently disabled by the administrator."
DOWNLOADS_OFF_USER = "Downloads are disabled for your account by the administrator."


def _limit_msg(limit: int) -> str:
    return (f"Login limit reached: the administrator allows {limit} user(s) online at the same time. "
            "Please try again in a few minutes.")


def _effective_downloads(user: dict, global_allow: bool, override) -> bool:
    """Admin: always. Otherwise the per-user choice (if the admin made one) beats the global switch."""
    if user["isAdmin"]:
        return True
    return override if isinstance(override, bool) else global_allow


def _session_reply(res, user: dict, store) -> dict:
    override = None if user["isAdmin"] else store.get_download_override(user["uid"])
    return {"ok": True, "heartbeatSec": HEARTBEAT_SEC, "ttlSec": SESSION_TTL_SEC,
            "isAdmin": user["isAdmin"],
            "allowDownloads": _effective_downloads(user, res.allow_downloads, override),
            "globalDownloads": res.allow_downloads, "downloadOverride": override}


# ---- sessions ---------------------------------------------------------------
@router.post("/session/start")
def session_start(req: SessionReq, user: dict = Depends(require_user), store=Depends(get_store)):
    res = store.start_session(user["uid"], req.deviceId, user["isAdmin"], req.platform)
    if not res.ok:
        raise HTTPException(429, _limit_msg(res.limit))
    return _session_reply(res, user, store)


@router.post("/session/heartbeat")
def session_heartbeat(req: SessionReq, user: dict = Depends(require_user), store=Depends(get_store)):
    res = store.touch_session(user["uid"], req.deviceId, user["isAdmin"], req.platform)
    if not res.ok:   # session had expired and the limit is full now -> the app signs the user out
        raise HTTPException(429, _limit_msg(res.limit))
    return _session_reply(res, user, store)


@router.post("/session/end")
def session_end(req: SessionReq, user: dict = Depends(require_user), store=Depends(get_store)):
    store.end_session(user["uid"], req.deviceId)
    return {"ok": True}


# ---- settings ---------------------------------------------------------------
@router.get("/settings")
def public_settings(user: dict = Depends(require_user), store=Depends(get_store)):
    """What an ordinary user may know. The login limit and user counts stay admin-only."""
    override = None if user["isAdmin"] else store.get_download_override(user["uid"])
    return {"allowDownloads": _effective_downloads(user, store.get_settings()["allowDownloads"], override)}


@router.get("/admin/settings")
def admin_get_settings(_: dict = Depends(require_admin), store=Depends(get_store)):
    return {**store.get_settings(), "activeUsers": store.count_active_users()}


@router.put("/admin/settings")
def admin_put_settings(patch: SettingsPatch, admin: dict = Depends(require_admin), store=Depends(get_store)):
    settings = store.update_settings(patch.model_dump(exclude_none=True), admin["uid"])
    return {**settings, "activeUsers": store.count_active_users()}


# ---- admin: users -----------------------------------------------------------
@router.get("/admin/users")
def admin_users(page_size: int = Query(100, ge=1, le=1000, alias="pageSize"),
                page_token: Optional[str] = Query(None, alias="pageToken", max_length=2000),
                _: dict = Depends(require_admin), store=Depends(get_store)):
    try:
        users, nxt = store.list_users(page_size, page_token)
    except ValueError:
        raise HTTPException(400, "Invalid page token.")
    return {"users": users, "nextPageToken": nxt,
            "activeUsers": store.count_active_users(),
            "maxConcurrentUsers": store.get_settings()["maxConcurrentUsers"]}


@router.put("/admin/users/{uid}/downloads")
def admin_set_user_downloads(req: UserDownloadsReq, uid: str = Path(..., pattern=r"^[A-Za-z0-9_-]{1,128}$"),
                             admin: dict = Depends(require_admin), store=Depends(get_store)):
    """Per-user download permission: allow=true / false, or null to follow the global switch again."""
    store.set_download_override(uid, req.allow, admin["uid"])
    return {"uid": uid, "downloadOverride": req.allow}


@router.delete("/admin/users/{uid}")
def admin_delete_user(uid: str = Path(..., pattern=r"^[A-Za-z0-9_-]{1,128}$"),
                      admin: dict = Depends(require_admin), store=Depends(get_store)):
    """Permanently delete a user's account and data. Admins (incl. yourself) cannot be deleted from here."""
    if uid == admin["uid"]:
        raise HTTPException(400, "You cannot delete your own account.")
    try:
        store.delete_user(uid)
    except PermissionError:
        raise HTTPException(400, "This user is an admin. Remove the admin role first.")
    except LookupError:
        raise HTTPException(404, "User not found.")
    except Exception:
        raise HTTPException(500, "Could not delete the account. Please try again.")
    return {"ok": True, "uid": uid}


# ---- downloads --------------------------------------------------------------
@router.post("/downloads/authorize")
def downloads_authorize(req: DownloadAuthReq, user: dict = Depends(require_user), store=Depends(get_store)):
    """The app must call this before starting a download. Refused when the admin switched downloads off."""
    if not user["isAdmin"]:
        override = store.get_download_override(user["uid"])
        if not _effective_downloads(user, store.get_settings()["allowDownloads"], override):
            raise HTTPException(403, DOWNLOADS_OFF_USER if override is False else DOWNLOADS_OFF)
        if not store.has_active_session(user["uid"], req.deviceId):
            raise HTTPException(401, "Session expired. Please sign in again.")
    title = store.video_title(req.videoId)
    if title is None:
        raise HTTPException(404, "Video not found.")
    return {"allowed": True, "videoId": req.videoId, "title": title}
