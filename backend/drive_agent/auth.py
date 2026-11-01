"""Admin-only guard: verifies the Firebase ID token and users/{uid}.role == 'admin' (same rule as the app)."""
from __future__ import annotations
import os
import time

from fastapi import Depends, Header, HTTPException


_SA_KEYS = (
    "type", "project_id", "private_key_id", "private_key", "client_email",
    "client_id", "auth_uri", "token_uri", "auth_provider_x509_cert_url",
    "client_x509_cert_url", "universe_domain",
)


def _parse_sa(raw, json):
    """Tolerant parse: strict=False allows raw newlines in the key; also unwraps surrounding quotes / double-encoded JSON."""
    t = raw.strip()
    for _ in range(2):
        try:
            v = json.loads(t, strict=False)
        except ValueError:
            if len(t) > 1 and t[0] == t[-1] and t[0] in "'\"":
                t = t[1:-1].strip()
                continue
            return None
        if isinstance(v, str):   # JSON string containing JSON
            t = v
            continue
        return v if isinstance(v, dict) else None
    return None


def _json_from_env_file(json):
    """Fallback: pull the multi-line FIREBASE_SERVICE_ACCOUNT_JSON={...} block straight out of backend/.env."""
    import re
    from pathlib import Path
    try:
        text = (Path(__file__).resolve().parent.parent / ".env").read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(r"FIREBASE_SERVICE_ACCOUNT_JSON\s*=\s*['\"]?(\{.*?\})['\"]?\s*(?:\r?\n[A-Za-z_]+=|\Z)", text, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(1), strict=False)
    except ValueError:
        return None


def load_credentials():
    """Firebase service account, first match wins:
    1. FIREBASE_SERVICE_ACCOUNT_JSON  - the whole JSON text in one env var
    2. one env var per JSON field (project_id, private_key, client_email, ...)
    3. FIREBASE_SERVICE_ACCOUNT_FILE  - path to the JSON file (default serviceAccount.json)
    """
    import json
    from firebase_admin import credentials

    info = None
    raw = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    b64 = os.getenv("FIREBASE_SERVICE_ACCOUNT_B64", "").strip()
    if b64 and not raw:
        import base64
        try:
            raw = base64.b64decode(b64).decode("utf-8")
        except Exception:
            raise RuntimeError("FIREBASE_SERVICE_ACCOUNT_B64 is not valid base64.")
    if raw:
        info = _parse_sa(raw, json)
        if info is None:
            info = _json_from_env_file(json)
        if info is None:
            raise RuntimeError(
                "FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON "
                f"(got {len(raw)} chars, starts with {raw[:1]!r}). Paste the whole service-account JSON "
                "on one line, or set FIREBASE_SERVICE_ACCOUNT_B64 to its base64.")
    else:
        def env(k: str) -> str:
            return os.getenv(k) or os.getenv(k.upper()) or ""

        if env("private_key") and env("client_email"):
            info = {k: env(k) for k in _SA_KEYS if env(k)}
            info.setdefault("type", "service_account")

    if info is not None:
        key = info.get("private_key")
        if isinstance(key, str):
            info["private_key"] = key.strip().strip('"').replace("\\n", "\n")
        return credentials.Certificate(info)

    path = os.getenv("FIREBASE_SERVICE_ACCOUNT_FILE", "serviceAccount.json")
    if not os.path.isfile(path):
        raise RuntimeError(f"Server is missing the Firebase service account ({path}).")
    return credentials.Certificate(path)


def init_firebase() -> None:
    import firebase_admin
    if firebase_admin._apps:
        return
    try:
        firebase_admin.initialize_app(load_credentials())
    except RuntimeError as e:
        raise HTTPException(503, str(e))


_ADMIN_OK: dict[str, float] = {}   # uid -> expiry (skips Firestore read on every poll)


def verify_token(authorization: str | None) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Missing login token.")
    init_firebase()
    from firebase_admin import auth
    try:
        return auth.verify_id_token(authorization[7:].strip())
    except Exception:
        raise HTTPException(401, "Invalid or expired login token.")


def is_admin(uid: str) -> bool:
    """users/{uid}.role == 'admin' (cached for 60 s, only when true)."""
    if _ADMIN_OK.get(uid, 0) >= time.time():
        return True
    from firebase_admin import firestore
    snap = firestore.client().collection("users").document(uid).get()
    if snap.exists and (snap.to_dict() or {}).get("role") == "admin":
        _ADMIN_OK[uid] = time.time() + 60
        return True
    _ADMIN_OK.pop(uid, None)
    return False


def require_user(authorization: str | None = Header(default=None)) -> dict:
    """Any signed-in user. Returns {uid, email, isAdmin}."""
    decoded = verify_token(authorization)
    uid = decoded["uid"]
    return {"uid": uid, "email": decoded.get("email", ""), "isAdmin": is_admin(uid)}


def require_admin(user: dict = Depends(require_user)) -> dict:
    if not user["isAdmin"]:
        raise HTTPException(403, "Admin access required.")
    return {"uid": user["uid"], "email": user["email"]}
