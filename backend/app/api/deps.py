from __future__ import annotations

from typing import Annotated

from fastapi import Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.models import User


DbSession = Annotated[Session, Depends(get_db)]


def get_current_user(
    session: DbSession,
    user_id: str | None = Query(default=None, description="Temporary dev user selector."),
) -> User:
    if user_id:
        user = session.get(User, user_id)
    else:
        user = session.scalar(select(User).order_by(User.created_at.desc()))
    if user is None:
        raise HTTPException(status_code=404, detail="No local user exists yet. Connect Google Health first.")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]

