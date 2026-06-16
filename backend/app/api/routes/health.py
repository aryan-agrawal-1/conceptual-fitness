from __future__ import annotations

from fastapi import APIRouter


router = APIRouter(tags=["health"])

# apparently we're supposed to have api health checks
@router.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}

