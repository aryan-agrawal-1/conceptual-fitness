from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Query

from app.api.deps import CurrentUser
from app.journal import JournalCatalogue
from app.services.journal_catalogue import CATALOGUES


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/journal", tags=["journal"])


@router.get("/catalogue", response_model=JournalCatalogue)
def get_catalogue(user: CurrentUser, version: int = Query(default=1, ge=1)) -> JournalCatalogue:
    catalogue = CATALOGUES.get(version)
    if catalogue is None:
        logger.warning("Journal catalogue unavailable reason=unsupported_version")
        raise HTTPException(status_code=404, detail="Journal catalogue version is unavailable")
    return catalogue
