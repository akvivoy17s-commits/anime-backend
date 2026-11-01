"""Request bodies (validated on the server; the app is never trusted)."""
from typing import Optional

from pydantic import BaseModel, Field, StrictBool, StrictInt, model_validator

from .logic import MAX_LIMIT, MIN_LIMIT

DEVICE_ID = Field(pattern=r"^[A-Za-z0-9_-]{8,64}$")


class SessionReq(BaseModel):
    deviceId: str = DEVICE_ID
    platform: Optional[str] = Field(default=None, max_length=24)


class SettingsPatch(BaseModel):
    """Partial update: only the fields that are sent change (two admins can't overwrite each other's field)."""
    model_config = {"extra": "forbid"}

    maxConcurrentUsers: Optional[StrictInt] = Field(default=None, ge=MIN_LIMIT, le=MAX_LIMIT)
    allowDownloads: Optional[StrictBool] = None

    @model_validator(mode="after")
    def _not_empty(self):
        if self.maxConcurrentUsers is None and self.allowDownloads is None:
            raise ValueError("Send maxConcurrentUsers and/or allowDownloads.")
        return self


class UserDownloadsReq(BaseModel):
    """allow: true = always allowed, false = blocked, null = follow the global switch."""
    model_config = {"extra": "forbid"}

    allow: Optional[StrictBool]


class DownloadAuthReq(BaseModel):
    videoId: str = Field(min_length=1, max_length=200, pattern=r"^[A-Za-z0-9_-]+$")
    deviceId: str = DEVICE_ID
