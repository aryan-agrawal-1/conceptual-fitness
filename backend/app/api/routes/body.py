from __future__ import annotations

from datetime import date as date_type, datetime, time
from typing import Literal

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.core.security import utcnow
from app.models import MetricSample, UserProfile
from app.services.health_dates import get_or_create_profile, local_date_for_profile, timezone_for_profile


router = APIRouter(prefix="/body-metrics", tags=["body-metrics"])


class BodySamplePayload(BaseModel):
    metric: Literal["height", "weight"]
    observed_at: datetime
    date: date_type | None
    value: float
    unit: str
    source_platform: str | None
    source_device: str | None


class BmiSamplePayload(BaseModel):
    observed_at: datetime
    date: date_type | None
    bmi: float
    weight_kg: float
    height_cm: float


class BodyMetricsPayload(BaseModel):
    height_cm: float | None
    weight_kg: float | None
    bmi: float | None
    latest_height_at: datetime | None
    latest_weight_at: datetime | None
    samples: list[BodySamplePayload]
    bmi_history: list[BmiSamplePayload]


class ManualBodyMetricsUpdate(BaseModel):
    date: date_type | None = None
    observed_at: datetime | None = None
    height_cm: float | None = Field(default=None, gt=0, le=260)
    weight_kg: float | None = Field(default=None, gt=0, le=700)

    @model_validator(mode="after")
    def require_metric(self) -> ManualBodyMetricsUpdate:
        if self.height_cm is None and self.weight_kg is None:
            raise ValueError("Provide height_cm, weight_kg, or both")
        return self


@router.get("", response_model=BodyMetricsPayload)
def body_metrics(
    session: DbSession,
    user: CurrentUser,
    start: date_type | None = Query(default=None),
    end: date_type | None = Query(default=None),
) -> BodyMetricsPayload:
    profile = get_or_create_profile(session, user.id)
    session.commit()
    return _body_metrics_payload(session, user_id=user.id, profile=profile, start=start, end=end)


@router.post("", response_model=BodyMetricsPayload)
def update_body_metrics(
    payload: ManualBodyMetricsUpdate,
    session: DbSession,
    user: CurrentUser,
) -> BodyMetricsPayload:
    profile = get_or_create_profile(session, user.id)
    observed_at = _manual_observed_at(profile, payload)
    civil_date = payload.date or local_date_for_profile(profile, observed_at)
    if payload.height_cm is not None:
        sample = _upsert_manual_sample(
            session,
            user_id=user.id,
            metric="height",
            observed_at=observed_at,
            civil_date=civil_date,
            value=payload.height_cm / 100,
            unit="meters",
        )
        if _latest_sample(session, user_id=user.id, metric="height") == sample:
            profile.height_cm = payload.height_cm
        profile.height_source_preference = "manual"
    if payload.weight_kg is not None:
        sample = _upsert_manual_sample(
            session,
            user_id=user.id,
            metric="weight",
            observed_at=observed_at,
            civil_date=civil_date,
            value=payload.weight_kg,
            unit="kg",
        )
        if _latest_sample(session, user_id=user.id, metric="weight") == sample:
            profile.weight_kg = payload.weight_kg
        profile.weight_source_preference = "manual"
    session.add(profile)
    session.commit()
    session.refresh(profile)
    return _body_metrics_payload(session, user_id=user.id, profile=profile, start=None, end=None)


def _body_metrics_payload(
    session: DbSession,
    *,
    user_id: str,
    profile: UserProfile,
    start: date_type | None,
    end: date_type | None,
) -> BodyMetricsPayload:
    samples = _body_samples(session, user_id=user_id, start=start, end=end)
    latest_height = _latest_sample(session, user_id=user_id, metric="height")
    latest_weight = _latest_sample(session, user_id=user_id, metric="weight")
    height_cm = profile.height_cm
    weight_kg = profile.weight_kg
    if latest_height is not None and _sample_can_update_current(
        latest_height,
        preference=profile.height_source_preference,
    ):
        height_cm = latest_height.value * 100
    if latest_weight is not None and _sample_can_update_current(
        latest_weight,
        preference=profile.weight_source_preference,
    ):
        weight_kg = latest_weight.value
    return BodyMetricsPayload(
        height_cm=height_cm,
        weight_kg=weight_kg,
        bmi=_bmi(height_cm, weight_kg),
        latest_height_at=latest_height.observed_at if latest_height is not None else None,
        latest_weight_at=latest_weight.observed_at if latest_weight is not None else None,
        samples=[_sample_payload(sample) for sample in samples],
        bmi_history=_bmi_history(samples, fallback_height_cm=height_cm),
    )


def _body_samples(
    session: DbSession,
    *,
    user_id: str,
    start: date_type | None,
    end: date_type | None,
) -> list[MetricSample]:
    statement = select(MetricSample).where(
        MetricSample.user_id == user_id,
        MetricSample.metric.in_(("height", "weight")),
    )
    if start is not None:
        statement = statement.where(MetricSample.civil_date >= start)
    if end is not None:
        statement = statement.where(MetricSample.civil_date <= end)
    return session.scalars(statement.order_by(MetricSample.observed_at)).all()


def _latest_sample(session: DbSession, *, user_id: str, metric: str) -> MetricSample | None:
    return session.scalar(
        select(MetricSample)
        .where(MetricSample.user_id == user_id, MetricSample.metric == metric)
        .order_by(MetricSample.observed_at.desc())
        .limit(1)
    )


def _sample_can_update_current(sample: MetricSample, *, preference: str) -> bool:
    return preference != "manual" or sample.source_platform == "manual"


def _upsert_manual_sample(
    session: DbSession,
    *,
    user_id: str,
    metric: Literal["height", "weight"],
    observed_at: datetime,
    civil_date: date_type,
    value: float,
    unit: str,
) -> MetricSample:
    sample = session.scalar(
        select(MetricSample)
        .where(
            MetricSample.user_id == user_id,
            MetricSample.metric == metric,
            MetricSample.civil_date == civil_date,
            MetricSample.source_platform == "manual",
        )
        .order_by(MetricSample.observed_at.desc())
        .limit(1)
    )
    if sample is None:
        sample = MetricSample(
            user_id=user_id,
            metric=metric,
            observed_at=observed_at,
            civil_date=civil_date,
            value=value,
            unit=unit,
            source_platform="manual",
        )
    else:
        sample.observed_at = observed_at
        sample.value = value
        sample.unit = unit
    session.add(sample)
    session.flush()
    return sample


def _manual_observed_at(profile: UserProfile, payload: ManualBodyMetricsUpdate) -> datetime:
    if payload.observed_at is not None:
        return payload.observed_at
    if payload.date is not None:
        return datetime.combine(payload.date, time(), tzinfo=timezone_for_profile(profile))
    return utcnow()


def _sample_payload(sample: MetricSample) -> BodySamplePayload:
    return BodySamplePayload(
        metric=sample.metric,
        observed_at=sample.observed_at,
        date=sample.civil_date,
        value=sample.value * 100 if sample.metric == "height" else sample.value,
        unit="cm" if sample.metric == "height" else sample.unit,
        source_platform=sample.source_platform,
        source_device=sample.source_device,
    )


def _bmi_history(
    samples: list[MetricSample],
    *,
    fallback_height_cm: float | None,
) -> list[BmiSamplePayload]:
    height_cm = fallback_height_cm
    history: list[BmiSamplePayload] = []
    for sample in samples:
        if sample.metric == "height":
            height_cm = sample.value * 100
            continue
        if sample.metric == "weight" and height_cm is not None:
            bmi = _bmi(height_cm, sample.value)
            if bmi is None:
                continue
            history.append(
                BmiSamplePayload(
                    observed_at=sample.observed_at,
                    date=sample.civil_date,
                    bmi=bmi,
                    weight_kg=sample.value,
                    height_cm=height_cm,
                )
            )
    return history


def _bmi(height_cm: float | None, weight_kg: float | None) -> float | None:
    if height_cm is None or weight_kg is None or height_cm <= 0:
        return None
    height_m = height_cm / 100
    return round(weight_kg / (height_m * height_m), 1)
