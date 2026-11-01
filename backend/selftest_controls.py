"""Offline check of sessions / settings / admin API (no Firebase, no network): python selftest_controls.py
Uses an in-memory store that follows the same rules (controls.logic) as FirestoreStore.
The Firestore transaction itself needs a real project or the emulator - see the live checklist in the phase notes."""
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from controls import logic
from controls.api import router
from controls.store import SessionResult, get_store
from drive_agent.auth import require_user
from fastapi import FastAPI

# ---------- pure rules ----------
assert logic.normalize_settings(None) == logic.DEFAULT_SETTINGS
assert logic.normalize_settings({"maxConcurrentUsers": True, "allowDownloads": "yes"}) == logic.DEFAULT_SETTINGS
assert logic.normalize_settings({"maxConcurrentUsers": 0})["maxConcurrentUsers"] == 100
assert logic.normalize_settings({"maxConcurrentUsers": 5, "allowDownloads": False}) == {"maxConcurrentUsers": 5, "allowDownloads": False}
assert logic.decide_start(False, False, 2, 3) and not logic.decide_start(False, False, 3, 3)
assert logic.decide_start(True, False, 99, 1) and logic.decide_start(False, True, 99, 1)
assert logic.active_user_ids([{"uid": "a"}, {"uid": "a"}, {"uid": "b", "isAdmin": True}, {"uid": "c"}], exclude_uid="c") == {"a"}


class MemStore:
    def __init__(self):
        self.settings = dict(logic.DEFAULT_SETTINGS)
        self.sessions = {}   # key -> doc
        self.now = datetime(2026, 11, 1, tzinfo=timezone.utc)
        self.videos = {"vid1": "Episode 1"}
        self.overrides = {}
        self.known_uids = {"user4", "user5"}
        self.admin_uids = {"adm2"}

    def _cut(self): return self.now - timedelta(seconds=logic.SESSION_TTL_SEC)
    def _active(self): return [d for d in self.sessions.values() if logic.is_fresh(d["lastSeenAt"], self._cut())]
    def get_settings(self): return logic.normalize_settings(self.settings)
    def update_settings(self, patch, by): self.settings.update(patch); return self.get_settings()
    def count_active_users(self): return len(logic.active_user_ids(self._active()))

    def start_session(self, uid, dev, is_admin, platform):
        k = logic.session_key(uid, dev); s = self.get_settings()
        own = k in self.sessions and logic.is_fresh(self.sessions[k]["lastSeenAt"], self._cut())
        others = logic.active_user_ids(self._active(), exclude_uid=uid)
        ok = logic.decide_start(is_admin, own, len(others), s["maxConcurrentUsers"])
        if ok: self.sessions[k] = {"uid": uid, "isAdmin": is_admin, "lastSeenAt": self.now}
        return SessionResult(ok, s["maxConcurrentUsers"], s["allowDownloads"])

    def touch_session(self, uid, dev, is_admin, platform): return self.start_session(uid, dev, is_admin, platform)
    def end_session(self, uid, dev): self.sessions.pop(logic.session_key(uid, dev), None)
    def has_active_session(self, uid, dev):
        d = self.sessions.get(logic.session_key(uid, dev)); return bool(d and logic.is_fresh(d["lastSeenAt"], self._cut()))
    def get_download_override(self, uid): return self.overrides.get(uid)
    def set_download_override(self, uid, allow, by):
        if allow is None: self.overrides.pop(uid, None)
        else: self.overrides[uid] = allow
    def delete_user(self, uid):
        if uid in self.admin_uids: raise PermissionError(uid)
        if uid not in self.known_uids: raise LookupError(uid)
        self.known_uids.discard(uid); self.overrides.pop(uid, None)
    def video_title(self, vid): return self.videos.get(vid)
    def list_users(self, size, token):
        if token == "bad": raise ValueError("bad token")
        return [{"uid": "u1", "email": "a@b.c", "online": True}], None


app = FastAPI(); app.include_router(router)
store = MemStore()
app.dependency_overrides[get_store] = lambda: store
who = {"u": None}
app.dependency_overrides[require_user] = lambda: who["u"]
c = TestClient(app)
ADMIN = {"uid": "adm", "email": "adm@x.y", "isAdmin": True}
def U(n): return {"uid": f"user{n}", "email": f"u{n}@x.y", "isAdmin": False}
D = lambda n: {"deviceId": f"device-{n:04d}"}
def as_(u): who["u"] = u

# no token at all -> 401 (real dependency, not overridden)
raw = FastAPI(); raw.include_router(router); raw.dependency_overrides[get_store] = lambda: store
r = TestClient(raw)
for m, p in [("get", "/settings"), ("get", "/admin/users"), ("get", "/admin/settings"), ("put", "/admin/settings"),
             ("post", "/session/start"), ("post", "/downloads/authorize")]:
    assert getattr(r, m)(p).status_code == 401, p

# ordinary user can't touch admin routes
as_(U(1))
assert c.get("/admin/users").status_code == 403
assert c.get("/admin/settings").status_code == 403
assert c.put("/admin/settings", json={"allowDownloads": False}).status_code == 403
assert c.get("/settings").json() == {"allowDownloads": True}

# admin settings: validation
as_(ADMIN)
for bad in [{}, {"maxConcurrentUsers": 0}, {"maxConcurrentUsers": -3}, {"maxConcurrentUsers": 10001}, {"maxConcurrentUsers": "5"},
            {"maxConcurrentUsers": 2.5}, {"maxConcurrentUsers": True}, {"allowDownloads": "yes"}, {"allowDownloads": 1}, {"x": 1}]:
    assert c.put("/admin/settings", json=bad).status_code == 422, bad
r1 = c.put("/admin/settings", json={"maxConcurrentUsers": 2}); assert r1.status_code == 200 and r1.json()["maxConcurrentUsers"] == 2
assert c.put("/admin/settings", json={"allowDownloads": False}).json() == {"maxConcurrentUsers": 2, "allowDownloads": False, "activeUsers": 0}

# bad device id
assert c.post("/session/start", json={"deviceId": "x"}).status_code == 422
assert c.post("/session/start", json={"deviceId": "bad id with spaces!"}).status_code == 422

# concurrent limit = 2 users
as_(U(1)); assert c.post("/session/start", json=D(1)).status_code == 200
as_(U(2)); assert c.post("/session/start", json=D(2)).status_code == 200
as_(U(3)); r3 = c.post("/session/start", json=D(3)); assert r3.status_code == 429 and "limit" in r3.json()["detail"].lower()
as_(U(1)); assert c.post("/session/start", json=D(9)).status_code == 200      # 2nd device of an online user shares the slot
as_(ADMIN); assert c.post("/session/start", json=D(7)).status_code == 200     # admin exempt
assert c.get("/admin/settings").json()["activeUsers"] == 2                     # admin not counted
as_(U(2)); assert c.post("/session/end", json=D(2)).status_code == 200
as_(U(3)); assert c.post("/session/start", json=D(3)).status_code == 200      # slot freed
# inactive sessions expire
store.now += timedelta(seconds=logic.SESSION_TTL_SEC + 5)
assert store.count_active_users() == 0
as_(U(4)); assert c.post("/session/heartbeat", json=D(4)).status_code == 200
# lowering the limit never kicks an active session (heartbeat of live session still ok)
as_(ADMIN); c.put("/admin/settings", json={"maxConcurrentUsers": 1})
as_(U(4)); assert c.post("/session/heartbeat", json=D(4)).status_code == 200
as_(U(5)); assert c.post("/session/start", json=D(5)).status_code == 429
as_(ADMIN); c.put("/admin/settings", json={"maxConcurrentUsers": 5})
as_(U(5)); assert c.post("/session/start", json=D(5)).status_code == 200      # raised limit applies immediately

# download permission
as_(ADMIN); c.put("/admin/settings", json={"allowDownloads": True})
as_(U(4))
ok = c.post("/downloads/authorize", json={"videoId": "vid1", **D(4)}); assert ok.status_code == 200 and ok.json()["title"] == "Episode 1"
assert c.post("/downloads/authorize", json={"videoId": "nope", **D(4)}).status_code == 404
assert c.post("/downloads/authorize", json={"videoId": "vid1", **D(8)}).status_code == 401   # no session on that device
assert c.post("/downloads/authorize", json={"videoId": "../x", **D(4)}).status_code == 422
as_(ADMIN); c.put("/admin/settings", json={"allowDownloads": False})
as_(U(4))
off = c.post("/downloads/authorize", json={"videoId": "vid1", **D(4)}); assert off.status_code == 403 and "disabled" in off.json()["detail"]
assert c.get("/settings").json() == {"allowDownloads": False}
as_(ADMIN); assert c.post("/downloads/authorize", json={"videoId": "vid1", **D(7)}).status_code == 200   # admin still allowed

# per-user download permission (global switch is OFF here)
as_(ADMIN)
assert c.put("/admin/users/user4/downloads", json={"allow": True}).json() == {"uid": "user4", "downloadOverride": True}
assert c.put("/admin/users/bad%20id/downloads", json={"allow": True}).status_code == 422
assert c.put("/admin/users/user4/downloads", json={"allow": "yes"}).status_code == 422
assert c.put("/admin/users/user4/downloads", json={}).status_code == 422
as_(U(4))
assert c.get("/settings").json() == {"allowDownloads": True}
assert c.post("/downloads/authorize", json={"videoId": "vid1", **D(4)}).status_code == 200   # allowed although global OFF
as_(U(9)); assert c.get("/settings").json() == {"allowDownloads": False}                     # others still follow global
as_(U(4)); assert c.post("/session/start", json=D(4)).json()["downloadOverride"] is True
as_(ADMIN); c.put("/admin/settings", json={"allowDownloads": True})
c.put("/admin/users/user4/downloads", json={"allow": False})
as_(U(4))
blocked = c.post("/downloads/authorize", json={"videoId": "vid1", **D(4)})
assert blocked.status_code == 403 and "your account" in blocked.json()["detail"]
assert c.get("/settings").json() == {"allowDownloads": False}                                 # blocked although global ON
as_(U(9)); assert c.get("/settings").json() == {"allowDownloads": True}
as_(ADMIN); c.put("/admin/users/user4/downloads", json={"allow": None})
as_(U(4)); assert c.get("/settings").json() == {"allowDownloads": True}                       # back to following global

# delete account
as_(ADMIN)
assert c.delete("/admin/users/adm").status_code == 400            # yourself
assert c.delete("/admin/users/adm2").status_code == 400           # another admin
assert c.delete("/admin/users/nobody1").status_code == 404
assert c.delete("/admin/users/bad%20id").status_code == 422
assert c.delete("/admin/users/user5").json() == {"ok": True, "uid": "user5"}
assert c.delete("/admin/users/user5").status_code == 404          # already gone
as_(U(4)); assert c.delete("/admin/users/user4").status_code == 403   # ordinary users cannot

# users list
assert c.get("/admin/users?pageSize=0").status_code == 422 and c.get("/admin/users?pageSize=1001").status_code == 422
assert c.get("/admin/users?pageToken=bad").status_code == 400
u = c.get("/admin/users").json(); assert u["users"][0]["email"] == "a@b.c" and "maxConcurrentUsers" in u
assert "password" not in str(u).lower()
print("controls selftest: all checks passed")
