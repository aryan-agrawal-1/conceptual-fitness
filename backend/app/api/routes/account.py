from __future__ import annotations

import logging
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.core.security import token_digest
from app.models import User
from app.services.account_deletion import schedule_account_deletion
from app.services.account_recovery import AccountRecoveryError, recover_account
from app.services.app_auth import TokenPair, create_session_for_device
from app.services.rate_limit import CONNECTION_MUTATION_LIMIT, client_ip, enforce_rate_limit
from app.services.sensitive_actions import SensitiveActionError, consume_sensitive_action_grant


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/account/deletion", tags=["account"])


class DeletionStatus(BaseModel):
    status: Literal["active", "pending"]
    requested_at: datetime | None
    scheduled_for: datetime | None


class ScheduleDeletionRequest(BaseModel):
    confirmation: Literal["DELETE"]
    sensitive_action_grant: str = Field(min_length=1)
    device_id: str = Field(min_length=16)


class RecoverDeletionRequest(BaseModel):
    sensitive_action_grant: str = Field(min_length=1)
    device_id: str = Field(min_length=16)


class RecoveryResponse(BaseModel):
    status: Literal["recovered"]
    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int


@router.get("", response_model=DeletionStatus)
def deletion_status(user: CurrentUser) -> DeletionStatus:
    return status_payload(user)


@router.post("", response_model=DeletionStatus)
def schedule_deletion(
    payload: ScheduleDeletionRequest,
    request: Request,
    session: DbSession,
    user: CurrentUser,
) -> DeletionStatus:
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, user.id)
    try:
        consume_sensitive_action_grant(
            session,
            token=payload.sensitive_action_grant,
            purpose="delete_account",
            user_id=user.id,
            device_id=payload.device_id,
        )
    except SensitiveActionError as exc:
        raise HTTPException(status_code=403, detail="Reauthentication is required") from exc

    schedule_account_deletion(session, user)
    logger.info("Account deletion scheduled user=%s", token_digest(user.id)[:12])
    return status_payload(user)


@router.post("/recover", response_model=RecoveryResponse)
def recover_deletion(
    payload: RecoverDeletionRequest,
    request: Request,
    session: DbSession,
) -> RecoveryResponse:
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, client_ip(request), payload.device_id)
    try:
        grant = consume_sensitive_action_grant(
            session,
            token=payload.sensitive_action_grant,
            purpose="recover_deletion",
            device_id=payload.device_id,
        )
        user = session.scalar(select(User).where(User.id == grant.user_id).with_for_update())
        if user is None:
            raise AccountRecoveryError("Account was not found")
        recover_account(session, user)
        token_pair = create_session_for_device(
            session,
            user_id=user.id,
            device_id=payload.device_id,
            user_agent=request.headers.get("user-agent"),
        )
    except (AccountRecoveryError, SensitiveActionError) as exc:
        raise HTTPException(status_code=403, detail="Account recovery is unavailable") from exc

    logger.info("Account deletion recovered user=%s", token_digest(user.id)[:12])
    return recovery_payload(token_pair)


def status_payload(user: User) -> DeletionStatus:
    return DeletionStatus(
        status="pending" if user.deletion_scheduled_for else "active",
        requested_at=user.deletion_requested_at,
        scheduled_for=user.deletion_scheduled_for,
    )


def recovery_payload(token_pair: TokenPair) -> RecoveryResponse:
    return RecoveryResponse(
        status="recovered",
        access_token=token_pair.access_token,
        refresh_token=token_pair.refresh_token,
        token_type=token_pair.token_type,
        expires_in=token_pair.expires_in,
    )
