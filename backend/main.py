import os

from dotenv import load_dotenv

load_dotenv()  # must run before the imports below read env vars

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from controls.api import router as controls_router
from drive_agent.api import router as drive_router

app = FastAPI(title="Anime Portal Backend")

# Web builds need CORS. Production: ALLOWED_ORIGINS=https://your-web-domain.com
_origins = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "*").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Content-Type", "Authorization"],
)

app.include_router(drive_router)  # admin-only Drive upload agent
app.include_router(controls_router)  # sessions, admin settings/users, download permission


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/")
def root():
    """Open this URL in a browser to confirm which routes the DEPLOYED server has."""
    paths = sorted({r.path for r in app.routes if getattr(r, "path", "").startswith(("/admin", "/session", "/settings", "/downloads", "/drive"))})
    return {"ok": True, "routes": paths}
