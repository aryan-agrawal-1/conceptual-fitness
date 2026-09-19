from __future__ import annotations

from datetime import date, datetime
from typing import Literal
from zoneinfo import ZoneInfoNotFoundError, ZoneInfo

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.api.deps import CurrentUser, DbSession
from app.core.security import utcnow
from app.models import MetricSample, UserProfile
from app.services.body_metrics import preferred_body_sample
from app.services.health_dates import get_or_create_profile


router = APIRouter(prefix="/profile", tags=["profile"])


class ProfileConstraints(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schedule: list[str] = Field(default_factory=list, max_length=20)
    equipment: list[str] = Field(default_factory=list, max_length=50)
    injuries: list[str] = Field(default_factory=list, max_length=20)
    dietary_preferences: list[str] = Field(default_factory=list, max_length=20)
    sleep_schedule: str | None = Field(default=None, max_length=160)

    @field_validator("schedule", "equipment", "injuries", "dietary_preferences")
    @classmethod
    def clean_items(cls, values: list[str]) -> list[str]:
        cleaned = [value.strip() for value in values]
        if any(not value or len(value) > 160 for value in cleaned):
            raise ValueError("Constraint values must contain 1 to 160 characters")
        return list(dict.fromkeys(cleaned))

    @field_validator("sleep_schedule")
    @classmethod
    def clean_sleep_schedule(cls, value: str | None) -> str | None:
        return _clean_string(value) if value is not None else None


class ProfileConstraintsUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schedule: list[str] | None = Field(default=None, max_length=20)
    equipment: list[str] | None = Field(default=None, max_length=50)
    injuries: list[str] | None = Field(default=None, max_length=20)
    dietary_preferences: list[str] | None = Field(default=None, max_length=20)
    sleep_schedule: str | None = Field(default=None, max_length=160)

    @field_validator("schedule", "equipment", "injuries", "dietary_preferences")
    @classmethod
    def clean_items(cls, values: list[str] | None) -> list[str] | None:
        return ProfileConstraints.clean_items(values) if values is not None else None

    @field_validator("sleep_schedule")
    @classmethod
    def clean_sleep_schedule(cls, value: str | None) -> str | None:
        return ProfileConstraints.clean_sleep_schedule(value)


class FieldProvenance(BaseModel):
    preference: Literal["google", "manual"]
    active_source: str | None
    updated_at: datetime | None


class ProfilePayload(BaseModel):
    user_id: str
    timezone: str
    date_of_birth: date | None
    birth_year: int | None
    sex: str | None
    height_cm: float | None
    weight_kg: float | None
    bmi: float | None
    weather_enabled: bool
    location_permission_status: str | None
    height_source_preference: str
    weight_source_preference: str
    fitness_goal: str | None
    primary_goal: str | None
    secondary_goals: list[str]
    constraints: ProfileConstraints
    unit_system: Literal["metric", "imperial"]
    height_provenance: FieldProvenance
    weight_provenance: FieldProvenance
    sleep_target_minutes: int
    onboarding_completed_at: datetime | None


class ProfileUpdate(BaseModel):
    timezone: str | None = Field(default=None, min_length=1, max_length=80)
    date_of_birth: date | None = None
    birth_year: int | None = Field(default=None, ge=1900, le=2100)
    sex: Literal["female", "male", "not_specified"] | None = None
    height_cm: float | None = Field(default=None, gt=0, le=260)
    weight_kg: float | None = Field(default=None, gt=0, le=700)
    weather_enabled: bool | None = None
    location_permission_status: (
        Literal["not_determined", "authorized", "denied", "restricted", "manual"] | None
    ) = None
    height_source_preference: Literal["google", "manual"] | None = None
    weight_source_preference: Literal["google", "manual"] | None = None
    fitness_goal: str | None = Field(default=None, max_length=80)
    primary_goal: str | None = Field(default=None, max_length=80)
    secondary_goals: list[str] | None = Field(default=None, max_length=10)
    constraints: ProfileConstraintsUpdate | None = None
    unit_system: Literal["metric", "imperial"] | None = None
    sleep_target_minutes: int | None = Field(default=None, ge=180, le=900)
    onboarding_completed: bool | None = None

    @model_validator(mode="after")
    def validate_age_fields(self) -> ProfileUpdate:
        if self.date_of_birth is not None and self.birth_year is not None:
            raise ValueError("Provide either date_of_birth or birth_year, not both")
        if self.timezone is not None:
            try:
                ZoneInfo(self.timezone)
            except ZoneInfoNotFoundError as exc:
                raise ValueError("Unknown timezone") from exc
        if {"fitness_goal", "primary_goal"}.issubset(self.model_fields_set):
            if self.fitness_goal != self.primary_goal:
                raise ValueError("fitness_goal and primary_goal must match")
        if "unit_system" in self.model_fields_set and self.unit_system is None:
            raise ValueError("unit_system cannot be null")
        return self

    @field_validator("secondary_goals")
    @classmethod
    def clean_secondary_goals(cls, values: list[str] | None) -> list[str] | None:
        if values is None:
            return None
        cleaned = [value.strip() for value in values]
        if any(not value or len(value) > 80 for value in cleaned):
            raise ValueError("Goals must contain 1 to 80 characters")
        return list(dict.fromkeys(cleaned))


# full profile get endpoint
@router.get("", response_model=ProfilePayload)
def get_profile(session: DbSession, user: CurrentUser) -> ProfilePayload:
    profile = get_or_create_profile(session, user.id)
    session.commit()
    return _profile_payload(session, profile)


# full profile update endpoint
@router.patch("", response_model=ProfilePayload)
def update_profile(
    payload: ProfileUpdate,
    session: DbSession,
    user: CurrentUser,
) -> ProfilePayload:
    profile = get_or_create_profile(session, user.id)
    updates = payload.model_dump(exclude_unset=True)
    onboarding_completed = updates.pop("onboarding_completed", None)
    primary_goal = updates.pop("primary_goal", None)
    constraints = updates.pop("constraints", None)
    if "primary_goal" in payload.model_fields_set:
        updates["fitness_goal"] = primary_goal
    if "secondary_goals" in payload.model_fields_set and updates.get("secondary_goals") is None:
        updates["secondary_goals"] = []
    if constraints is not None:
        for key in ("schedule", "equipment", "injuries", "dietary_preferences"):
            if constraints.get(key) is None and key in constraints:
                constraints[key] = []
        profile.constraints = {**(profile.constraints or {}), **constraints}
    elif "constraints" in payload.model_fields_set:
        profile.constraints = {}
    if updates.get("date_of_birth") is not None:
        profile.birth_year = None
    if updates.get("birth_year") is not None:
        profile.date_of_birth = None
    for key, value in updates.items():
        setattr(profile, key, _clean_string(value) if isinstance(value, str) else value)
    for metric in ("height", "weight"):
        if f"{metric}_source_preference" not in updates:
            continue
        sample = preferred_body_sample(
            session,
            user_id=profile.user_id,
            metric=metric,
            preference=getattr(profile, f"{metric}_source_preference"),
        )
        if sample is not None:
            setattr(
                profile,
                f"{metric}_cm" if metric == "height" else "weight_kg",
                sample.value * 100 if metric == "height" else sample.value,
            )
    if onboarding_completed is True:
        profile.onboarding_completed_at = utcnow()
    elif onboarding_completed is False:
        profile.onboarding_completed_at = None
    session.add(profile)
    session.commit()
    session.refresh(profile)
    return _profile_payload(session, profile)


def _profile_payload(session: DbSession, profile: UserProfile) -> ProfilePayload:
    height_sample = preferred_body_sample(
        session,
        user_id=profile.user_id,
        metric="height",
        preference=profile.height_source_preference,
    )
    weight_sample = preferred_body_sample(
        session,
        user_id=profile.user_id,
        metric="weight",
        preference=profile.weight_source_preference,
    )
    height_cm = height_sample.value * 100 if height_sample is not None else profile.height_cm
    weight_kg = weight_sample.value if weight_sample is not None else profile.weight_kg
    return ProfilePayload(
        user_id=profile.user_id,
        timezone=profile.timezone,
        date_of_birth=profile.date_of_birth,
        birth_year=profile.birth_year,
        sex=profile.sex,
        height_cm=height_cm,
        weight_kg=weight_kg,
        bmi=_bmi(height_cm, weight_kg),
        weather_enabled=profile.weather_enabled,
        location_permission_status=profile.location_permission_status,
        height_source_preference=profile.height_source_preference,
        weight_source_preference=profile.weight_source_preference,
        fitness_goal=profile.fitness_goal,
        primary_goal=profile.fitness_goal,
        secondary_goals=profile.secondary_goals or [],
        constraints=ProfileConstraints.model_validate(profile.constraints or {}),
        unit_system=profile.unit_system,
        height_provenance=_provenance(profile, height_sample, "height"),
        weight_provenance=_provenance(profile, weight_sample, "weight"),
        sleep_target_minutes=profile.sleep_target_minutes,
        onboarding_completed_at=profile.onboarding_completed_at,
    )


def _provenance(
    profile: UserProfile,
    sample: MetricSample | None,
    metric: Literal["height", "weight"],
) -> FieldProvenance:
    preference = getattr(profile, f"{metric}_source_preference")
    if sample is not None:
        return FieldProvenance(
            preference=preference,
            active_source=sample.source_platform or "provider",
            updated_at=sample.observed_at,
        )
    value = getattr(profile, f"{metric}_cm" if metric == "height" else "weight_kg")
    return FieldProvenance(
        preference=preference,
        active_source="manual" if value is not None and preference == "manual" else None,
        updated_at=profile.updated_at if value is not None and preference == "manual" else None,
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
