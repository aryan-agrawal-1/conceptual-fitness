from __future__ import annotations

from datetime import date
from zoneinfo import ZoneInfoNotFoundError, ZoneInfo

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, model_validator

from app.api.deps import CurrentUser, DbSession
from app.models import UserProfile
from app.services.health_dates import get_or_create_profile


router = APIRouter(prefix="/profile", tags=["profile"])


class ProfilePayload(BaseModel):
    user_id: str
    timezone: str
    date_of_birth: date | None
    birth_year: int | None
    sex: str | None
    height_cm: float | None
    weight_kg: float | None
    bmi: float | None
    fitness_goal: str | None
    sleep_target_minutes: int


class ProfileUpdate(BaseModel):
    timezone: str | None = Field(default=None, min_length=1, max_length=80)
    date_of_birth: date | None = None
    birth_year: int | None = Field(default=None, ge=1900, le=2100)
    sex: str | None = Field(default=None, max_length=32)
    height_cm: float | None = Field(default=None, gt=0, le=260)
    weight_kg: float | None = Field(default=None, gt=0, le=700)
    fitness_goal: str | None = Field(default=None, max_length=80)
    sleep_target_minutes: int | None = Field(default=None, ge=180, le=900)

    @model_validator(mode="after")
    def validate_age_fields(self) -> ProfileUpdate:
        if self.date_of_birth is not None and self.birth_year is not None:
            raise ValueError("Provide either date_of_birth or birth_year, not both")
        if self.timezone is not None:
            try:
                ZoneInfo(self.timezone)
            except ZoneInfoNotFoundError as exc:
                raise ValueError("Unknown timezone") from exc
        return self

# full profile get endpoint
@router.get("", response_model=ProfilePayload)
def get_profile(session: DbSession, user: CurrentUser) -> ProfilePayload:
    profile = get_or_create_profile(session, user.id)
    session.commit()
    return _profile_payload(profile)

# full profile update endpoint
@router.patch("", response_model=ProfilePayload)
def update_profile(
    payload: ProfileUpdate,
    session: DbSession,
    user: CurrentUser,
) -> ProfilePayload:
    profile = get_or_create_profile(session, user.id)
    updates = payload.model_dump(exclude_unset=True)
    if updates.get("date_of_birth") is not None:
        profile.birth_year = None
    if updates.get("birth_year") is not None:
        profile.date_of_birth = None
    for key, value in updates.items():
        setattr(profile, key, _clean_string(value) if isinstance(value, str) else value)
    session.add(profile)
    session.commit()
    session.refresh(profile)
    return _profile_payload(profile)


def _profile_payload(profile: UserProfile) -> ProfilePayload:
    return ProfilePayload(
        user_id=profile.user_id,
        timezone=profile.timezone,
        date_of_birth=profile.date_of_birth,
        birth_year=profile.birth_year,
        sex=profile.sex,
        height_cm=profile.height_cm,
        weight_kg=profile.weight_kg,
        bmi=_bmi(profile.height_cm, profile.weight_kg),
        fitness_goal=profile.fitness_goal,
        sleep_target_minutes=profile.sleep_target_minutes,
    )


def _clean_string(value: str) -> str | None:
    cleaned = value.strip()
    if not cleaned:
        raise HTTPException(status_code=422, detail="String fields cannot be blank")
    return cleaned


def _bmi(height_cm: float | None, weight_kg: float | None) -> float | None:
    if height_cm is None or weight_kg is None or height_cm <= 0:
        return None
    height_m = height_cm / 100
    return round(weight_kg / (height_m * height_m), 1)
