from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.models import UserProfile


DEFAULT_TIMEZONE = "UTC"
DEFAULT_SLEEP_TARGET_MINUTES = 480


def get_or_create_profile(session: Session, user_id: str) -> UserProfile:
    profile = session.scalar(select(UserProfile).where(UserProfile.user_id == user_id))
    if profile is not None:
        return profile
    profile = UserProfile(
        user_id=user_id,
        timezone=DEFAULT_TIMEZONE,
        sleep_target_minutes=DEFAULT_SLEEP_TARGET_MINUTES,
    )
    session.add(profile)
    session.flush()
    return profile


def timezone_for_profile(profile: UserProfile) -> ZoneInfo:
    try:
        return ZoneInfo(profile.timezone or DEFAULT_TIMEZONE)
    except ZoneInfoNotFoundError:
        return ZoneInfo(DEFAULT_TIMEZONE)


def local_date_for_profile(profile: UserProfile, instant: datetime | None = None) -> date:
    value = instant or utcnow()
    if value.tzinfo is None:
        value = value.replace(tzinfo=ZoneInfo(DEFAULT_TIMEZONE))
    return value.astimezone(timezone_for_profile(profile)).date()


def local_week_start(day: date) -> date:
    return date.fromordinal(day.toordinal() - day.weekday())


def age_on(profile: UserProfile, day: date) -> int | None:
    if profile.date_of_birth:
        years = day.year - profile.date_of_birth.year
        birthday_passed = (day.month, day.day) >= (
            profile.date_of_birth.month,
            profile.date_of_birth.day,
        )
        return years if birthday_passed else years - 1
    if profile.birth_year:
        return day.year - profile.birth_year
    return None

# estimate max heart rate (HUNT Fitness Study)
def estimated_max_heart_rate(profile: UserProfile, day: date) -> tuple[float | None, str]:
    age = age_on(profile, day)
    if age is None or age <= 0:
        return None, "missing_age"
    return 211 - 0.64 * age, "hunt_age_formula"
