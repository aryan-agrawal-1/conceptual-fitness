from __future__ import annotations

import enum
from datetime import date, datetime
from typing import Any
from uuid import uuid4

from sqlalchemy import (
    Boolean,
    Date,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    JSON,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.security import utcnow
from app.db.session import Base


def new_uuid() -> str:
    return str(uuid4())


class ConnectionStatus(str, enum.Enum):
    connected = "connected"
    disconnected = "disconnected"
    errored = "errored"


class SyncStatus(str, enum.Enum):
    pending = "pending"
    running = "running"
    succeeded = "succeeded"
    failed = "failed"


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    email: Mapped[str | None] = mapped_column(String(320), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

    google_accounts: Mapped[list[GoogleAccount]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class GoogleAccount(Base):
    __tablename__ = "google_accounts"
    __table_args__ = (
        UniqueConstraint("health_user_id", name="uq_google_accounts_health_user_id"),
        UniqueConstraint("legacy_user_id", name="uq_google_accounts_legacy_user_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    health_user_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    legacy_user_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    granted_scopes: Mapped[list[str]] = mapped_column(JSON, default=list)
    encrypted_refresh_token: Mapped[str | None] = mapped_column(Text, nullable=True)
    access_token_expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    status: Mapped[ConnectionStatus] = mapped_column(
        Enum(ConnectionStatus), default=ConnectionStatus.connected
    )
    connected_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    disconnected_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_token_refresh_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_sync_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

    user: Mapped[User] = relationship(back_populates="google_accounts")


class OAuthState(Base):
    __tablename__ = "oauth_states"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    state_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    redirect_after: Mapped[str | None] = mapped_column(Text, nullable=True)
    scopes: Mapped[list[str]] = mapped_column(JSON, default=list)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

# Original imported data from google health api
class RawHealthRecord(Base):
    __tablename__ = "raw_health_records"
    __table_args__ = (
        UniqueConstraint("google_account_id", "data_type", "source_record_id", name="uq_raw_record"),
        Index("ix_raw_records_user_data_type_date", "user_id", "data_type", "civil_date"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    google_account_id: Mapped[str] = mapped_column(
        ForeignKey("google_accounts.id", ondelete="CASCADE"), index=True
    )
    data_type: Mapped[str] = mapped_column(String(80))
    source_record_id: Mapped[str] = mapped_column(Text)
    source_platform: Mapped[str | None] = mapped_column(String(80), nullable=True)
    source_device: Mapped[str | None] = mapped_column(String(160), nullable=True)
    start_time: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    end_time: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    civil_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    raw_json: Mapped[dict[str, Any]] = mapped_column(JSON)
    content_hash: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

# normalised measurements from the raw record
class MetricSample(Base):
    __tablename__ = "metric_samples"
    __table_args__ = (
        UniqueConstraint("raw_record_id", "metric", "observed_at", name="uq_metric_sample"),
        Index("ix_metric_samples_user_metric_time", "user_id", "metric", "observed_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    raw_record_id: Mapped[str | None] = mapped_column(
        ForeignKey("raw_health_records.id", ondelete="SET NULL"), nullable=True
    )
    metric: Mapped[str] = mapped_column(String(80))
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    civil_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    value: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(32))
    source_platform: Mapped[str | None] = mapped_column(String(80), nullable=True)
    source_device: Mapped[str | None] = mapped_column(String(160), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

# normalised measirements in a certain time range
class MetricInterval(Base):
    __tablename__ = "metric_intervals"
    __table_args__ = (
        UniqueConstraint("raw_record_id", "metric", "start_time", "end_time", name="uq_metric_interval"),
        Index("ix_metric_intervals_user_metric_date", "user_id", "metric", "civil_date"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    raw_record_id: Mapped[str | None] = mapped_column(
        ForeignKey("raw_health_records.id", ondelete="SET NULL"), nullable=True
    )
    metric: Mapped[str] = mapped_column(String(80))
    start_time: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    end_time: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    civil_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    value: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(32))
    source_platform: Mapped[str | None] = mapped_column(String(80), nullable=True)
    source_device: Mapped[str | None] = mapped_column(String(160), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class SleepSession(Base):
    __tablename__ = "sleep_sessions"
    __table_args__ = (UniqueConstraint("raw_record_id", name="uq_sleep_session_raw_record"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    raw_record_id: Mapped[str | None] = mapped_column(
        ForeignKey("raw_health_records.id", ondelete="SET NULL"), nullable=True
    )
    start_time: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    end_time: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    civil_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    minutes_asleep: Mapped[int | None] = mapped_column(Integer, nullable=True)
    minutes_awake: Mapped[int | None] = mapped_column(Integer, nullable=True)
    minutes_in_sleep_period: Mapped[int | None] = mapped_column(Integer, nullable=True)
    stages_summary: Mapped[list[dict[str, Any]]] = mapped_column(JSON, default=list)
    stages: Mapped[list[dict[str, Any]]] = mapped_column(JSON, default=list)
    is_main_sleep: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Workout(Base):
    __tablename__ = "workouts"
    __table_args__ = (UniqueConstraint("raw_record_id", name="uq_workout_raw_record"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    raw_record_id: Mapped[str | None] = mapped_column(
        ForeignKey("raw_health_records.id", ondelete="SET NULL"), nullable=True
    )
    workout_type: Mapped[str | None] = mapped_column(String(120), nullable=True)
    start_time: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    end_time: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    civil_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    duration_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)
    raw_summary: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class DailySummary(Base):
    __tablename__ = "daily_summaries"
    __table_args__ = (UniqueConstraint("user_id", "summary_date", name="uq_daily_summary_user_date"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    summary_date: Mapped[date] = mapped_column(Date, index=True)
    steps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    active_calories: Mapped[float | None] = mapped_column(Float, nullable=True)
    total_calories: Mapped[float | None] = mapped_column(Float, nullable=True)
    distance_meters: Mapped[float | None] = mapped_column(Float, nullable=True)
    resting_heart_rate: Mapped[float | None] = mapped_column(Float, nullable=True)
    heart_rate_variability: Mapped[float | None] = mapped_column(Float, nullable=True)
    oxygen_saturation: Mapped[float | None] = mapped_column(Float, nullable=True)
    respiratory_rate: Mapped[float | None] = mapped_column(Float, nullable=True)
    sleep_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    workout_count: Mapped[int] = mapped_column(Integer, default=0)
    data_quality: Mapped[str] = mapped_column(String(32), default="weak")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

# so i know where the last sync was
class SyncCursor(Base):
    __tablename__ = "sync_cursors"
    __table_args__ = (UniqueConstraint("google_account_id", "data_type", name="uq_sync_cursor"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    google_account_id: Mapped[str] = mapped_column(
        ForeignKey("google_accounts.id", ondelete="CASCADE"), index=True
    )
    data_type: Mapped[str] = mapped_column(String(80))
    last_successful_start: Mapped[date | None] = mapped_column(Date, nullable=True)
    last_successful_end: Mapped[date | None] = mapped_column(Date, nullable=True)
    status: Mapped[SyncStatus] = mapped_column(Enum(SyncStatus), default=SyncStatus.pending)
    last_page_token: Mapped[str | None] = mapped_column(Text, nullable=True)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

