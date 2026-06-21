from __future__ import annotations

from celery import Celery
from celery.schedules import crontab

from app.core.config import get_settings


settings = get_settings()

celery_app = Celery(
    "personal_health",
    broker=settings.redis_url,
    backend=settings.redis_url,
    include=["app.tasks.sync"],
)

celery_app.conf.timezone = settings.celery_timezone
celery_app.conf.beat_schedule = {
    "sync-google-health-hourly": {
        "task": "app.tasks.sync.sync_all_connected_accounts",
        "schedule": crontab(minute=settings.celery_sync_minute, hour=settings.celery_sync_hour),
    }
}
