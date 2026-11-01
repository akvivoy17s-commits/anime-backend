"""Firestore access for settings, sessions and the admin user list.

Collections (all written ONLY by this backend via the Admin SDK; see firestore.rules):
  settings/app                     maxConcurrentUsers, allowDownloads, updatedAt, updatedBy
  sessions/{uid}_{deviceId}        uid, deviceId, isAdmin, platform, startedAt, lastSeenAt, expireAt
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

from drive_agent.auth import init_firebase

from .logic import (
    DOC_RETENTION_SEC, SESSION_TTL_SEC, active_user_ids, decide_start,
    is_fresh, normalize_settings, session_key,
)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


@dataclass
class SessionResult:
    ok: bool
    limit: int
    allow_downloads: bool
    active: Optional[int] = None   # distinct non-admin users online (None when not computed)


def _iso(v) -> Optional[str]:
    return v.isoformat() if hasattr(v, "isoformat") else None


def _ms_iso(ms) -> Optional[str]:
    if not ms:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()


class FirestoreStore:
    def _db(self):
        init_firebase()
        from firebase_admin import firestore
        return firestore.client()

    @staticmethod
    def _active_query(db, cutoff):
        col = db.collection("sessions")
        try:
            from google.cloud.firestore_v1.base_query import FieldFilter
            return col.where(filter=FieldFilter("lastSeenAt", ">", cutoff))
        except ImportError:  # older client library
            return col.where("lastSeenAt", ">", cutoff)

    # ---- settings -----------------------------------------------------
    def get_settings(self) -> dict:
        snap = self._db().document("settings/app").get()
        return normalize_settings(snap.to_dict() if snap.exists else None)

    def update_settings(self, patch: dict, by_uid: str) -> dict:
        from google.cloud import firestore as gcf
        ref = self._db().document("settings/app")
        # merge=True: only the sent fields change, so concurrent edits of different fields both survive
        ref.set({**patch, "updatedAt": gcf.SERVER_TIMESTAMP, "updatedBy": by_uid}, merge=True)
        return self.get_settings()

    # ---- sessions -----------------------------------------------------
    def start_session(self, uid: str, device_id: str, is_admin: bool,
                      platform: Optional[str], now: Optional[datetime] = None) -> SessionResult:
        """Admit or refuse a device, atomically (a transaction, so two simultaneous logins can't both take the last slot)."""
        from google.cloud import firestore as gcf
        now = now or utcnow()
        db = self._db()
        sref = db.collection("sessions").document(session_key(uid, device_id))
        settings_ref = db.document("settings/app")
        cutoff = now - timedelta(seconds=SESSION_TTL_SEC)

        @gcf.transactional
        def run(txn) -> SessionResult:
            # all reads first, then writes
            s_snap = settings_ref.get(transaction=txn)
            settings = normalize_settings(s_snap.to_dict() if s_snap.exists else None)
            own = sref.get(transaction=txn)
            own_active = own.exists and is_fresh((own.to_dict() or {}).get("lastSeenAt"), cutoff)
            docs = [d.to_dict() or {} for d in self._active_query(db, cutoff).stream(transaction=txn)]
            others = active_user_ids(docs, exclude_uid=uid)
            limit = settings["maxConcurrentUsers"]
            ok = decide_start(is_admin, own_active, len(others), limit)
            active = len(others) + (0 if is_admin else 1)
            if ok:
                payload = {
                    "uid": uid, "deviceId": device_id, "isAdmin": is_admin, "platform": platform,
                    "lastSeenAt": now, "expireAt": now + timedelta(seconds=DOC_RETENTION_SEC),
                }
                if not own_active:
                    payload["startedAt"] = now
                txn.set(sref, payload, merge=True)
            else:
                active = len(others)
            return SessionResult(ok, limit, settings["allowDownloads"], active)

        return run(db.transaction())

    def touch_session(self, uid: str, device_id: str, is_admin: bool,
                      platform: Optional[str], now: Optional[datetime] = None) -> SessionResult:
        """Heartbeat. Cheap path (1 read + 1 write) while the session is alive; an expired one is re-admitted like a login."""
        now = now or utcnow()
        sref = self._db().collection("sessions").document(session_key(uid, device_id))
        snap = sref.get()
        cutoff = now - timedelta(seconds=SESSION_TTL_SEC)
        if snap.exists and is_fresh((snap.to_dict() or {}).get("lastSeenAt"), cutoff):
            sref.update({"lastSeenAt": now, "expireAt": now + timedelta(seconds=DOC_RETENTION_SEC)})
            s = self.get_settings()
            return SessionResult(True, s["maxConcurrentUsers"], s["allowDownloads"])
        return self.start_session(uid, device_id, is_admin, platform, now)

    def end_session(self, uid: str, device_id: str) -> None:
        self._db().collection("sessions").document(session_key(uid, device_id)).delete()

    def has_active_session(self, uid: str, device_id: str, now: Optional[datetime] = None) -> bool:
        now = now or utcnow()
        snap = self._db().collection("sessions").document(session_key(uid, device_id)).get()
        return snap.exists and is_fresh((snap.to_dict() or {}).get("lastSeenAt"),
                                        now - timedelta(seconds=SESSION_TTL_SEC))

    def _active_docs(self, now: datetime) -> list[dict]:
        db = self._db()
        cutoff = now - timedelta(seconds=SESSION_TTL_SEC)
        return [d.to_dict() or {} for d in self._active_query(db, cutoff).stream()]

    def count_active_users(self, now: Optional[datetime] = None) -> int:
        return len(active_user_ids(self._active_docs(now or utcnow())))

    # ---- admin: users -------------------------------------------------
    def list_users(self, page_size: int, page_token: Optional[str]):
        """Registered accounts (Firebase Auth = source of truth) + role from Firestore + live online flag."""
        from firebase_admin import auth
        db = self._db()
        page = auth.list_users(page_token=page_token or None, max_results=page_size)
        users = list(page.users)
        refs = [db.collection("users").document(u.uid) for u in users]
        profiles = {s.id: (s.to_dict() or {}) for s in db.get_all(refs)} if refs else {}
        online = {d.get("uid") for d in self._active_docs(utcnow())}
        ov_refs = [db.collection("downloadAccess").document(u.uid) for u in users]
        overrides = {s.id: (s.to_dict() or {}).get("allow") for s in db.get_all(ov_refs)} if ov_refs else {}
        out = []
        for u in users:
            p = profiles.get(u.uid, {})
            meta = u.user_metadata
            out.append({
                "uid": u.uid,
                "email": u.email or p.get("email") or "",
                "displayName": u.display_name or p.get("displayName") or "",
                "photoUrl": u.photo_url or p.get("photoUrl") or "",
                "providers": [x.provider_id for x in (u.provider_data or [])],
                "role": "admin" if p.get("role") == "admin" else "user",
                "emailVerified": bool(u.email_verified),
                "disabled": bool(u.disabled),
                "createdAt": _ms_iso(meta.creation_timestamp) if meta else None,
                "lastSignInAt": _ms_iso(meta.last_sign_in_timestamp) if meta else None,
                "lastLoginAt": _iso(p.get("lastLoginAt")),
                "online": u.uid in online,
                "downloadOverride": overrides.get(u.uid) if isinstance(overrides.get(u.uid), bool) else None,
            })
        return out, page.next_page_token or None

    # ---- per-user download permission (backend-only collection downloadAccess/{uid}) ----
    def get_download_override(self, uid: str) -> Optional[bool]:
        """True = allowed, False = blocked, None = follow the global switch."""
        v = (self._db().collection("downloadAccess").document(uid).get().to_dict() or {}).get("allow")
        return v if isinstance(v, bool) else None

    def set_download_override(self, uid: str, allow: Optional[bool], by_uid: str) -> None:
        from google.cloud import firestore as gcf
        ref = self._db().collection("downloadAccess").document(uid)
        if allow is None:
            ref.delete()
        else:
            ref.set({"allow": allow, "updatedAt": gcf.SERVER_TIMESTAMP, "updatedBy": by_uid})

    # ---- admin: delete an account completely --------------------------
    def _wipe(self, db, query) -> None:
        """Delete every document of a collection / query in batches."""
        while True:
            docs = list(query.limit(400).stream())
            if not docs:
                return
            batch = db.batch()
            for d in docs:
                batch.delete(d.reference)
            batch.commit()

    def delete_user(self, uid: str) -> None:
        """Firebase Auth account + users/{uid} (and saved/state) + sessions + download permission.
        PermissionError: the target is an admin. LookupError: no such user."""
        from firebase_admin import auth
        db = self._db()
        uref = db.collection("users").document(uid)
        snap = uref.get()
        if snap.exists and (snap.to_dict() or {}).get("role") == "admin":
            raise PermissionError(uid)
        found = snap.exists
        try:
            auth.revoke_refresh_tokens(uid)
            auth.delete_user(uid)
            found = True
        except auth.UserNotFoundError:
            pass
        if not found:
            raise LookupError(uid)
        for sub in ("saved", "state"):
            self._wipe(db, uref.collection(sub))
        uref.delete()
        try:
            from google.cloud.firestore_v1.base_query import FieldFilter
            sessions = db.collection("sessions").where(filter=FieldFilter("uid", "==", uid))
        except ImportError:
            sessions = db.collection("sessions").where("uid", "==", uid)
        self._wipe(db, sessions)
        db.collection("downloadAccess").document(uid).delete()

    # ---- downloads ----------------------------------------------------
    def video_title(self, video_id: str) -> Optional[str]:
        """None when the video doesn't exist."""
        snap = self._db().collection("videos").document(video_id).get()
        if not snap.exists:
            return None
        d = snap.to_dict() or {}
        for k in ("title", "name", "videoTitle"):
            if str(d.get(k) or "").strip():
                return str(d[k]).strip()
        return "Untitled Video"


_store: Optional[FirestoreStore] = None


def get_store() -> FirestoreStore:
    global _store
    if _store is None:
        _store = FirestoreStore()
    return _store
