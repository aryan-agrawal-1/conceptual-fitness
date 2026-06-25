from __future__ import annotations

from dataclasses import dataclass


GOOGLE_HEALTH_API_BASE_URL = "https://health.googleapis.com/v4"
GOOGLE_OAUTH_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_OAUTH_REVOKE_URL = "https://oauth2.googleapis.com/revoke"
GOOGLE_OAUTH_USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo"


@dataclass(frozen=True)
class DataTypeSpec:
    data_type: str
    payload_key: str
    metric: str
    storage: str
    unit: str
    filter_time_path: str
    prefer_reconcile: bool = False
    prefer_daily_rollup: bool = False
    supports_filter: bool = True
    chunk_days: int | None = None
    page_size: int | None = None
    fail_sync_on_error: bool = True
    resume_page_tokens: bool = True
    use_timestamp_cursor: bool = False
    timestamp_overlap_minutes: int = 60

    @property
    def list_filter_start(self) -> str:
        return f'{self.filter_time_path} >= "{{start}}"'

    @property
    def list_filter_end(self) -> str:
        return f'{self.filter_time_path} < "{{end}}"'


DATA_TYPE_SPECS: dict[str, DataTypeSpec] = {
    "steps": DataTypeSpec(
        data_type="steps",
        payload_key="steps",
        metric="steps",
        storage="interval",
        unit="count",
        filter_time_path="steps.interval.civil_start_time",
        page_size=10000,
    ),
    "distance": DataTypeSpec(
        data_type="distance",
        payload_key="distance",
        metric="distance",
        storage="interval",
        unit="meters",
        filter_time_path="distance.interval.civil_start_time",
        page_size=10000,
    ),
    "active-energy-burned": DataTypeSpec(
        data_type="active-energy-burned",
        payload_key="activeEnergyBurned",
        metric="active_calories",
        storage="interval",
        unit="kcal",
        filter_time_path="active_energy_burned.interval.civil_start_time",
        page_size=10000,
        use_timestamp_cursor=True,
    ),
    "total-calories": DataTypeSpec(
        data_type="total-calories",
        payload_key="totalCalories",
        metric="total_calories",
        storage="interval",
        unit="kcal",
        filter_time_path="total_calories.interval.civil_start_time",
        prefer_daily_rollup=True,
    ),
    "heart-rate": DataTypeSpec(
        data_type="heart-rate",
        payload_key="heartRate",
        metric="heart_rate",
        storage="sample",
        unit="bpm",
        filter_time_path="heart_rate.sample_time.physical_time",
        prefer_reconcile=True,
        chunk_days=1,
        page_size=10000,
        fail_sync_on_error=False,
        use_timestamp_cursor=True,
    ),
    "daily-resting-heart-rate": DataTypeSpec(
        data_type="daily-resting-heart-rate",
        payload_key="dailyRestingHeartRate",
        metric="resting_heart_rate",
        storage="sample",
        unit="bpm",
        filter_time_path="daily_resting_heart_rate.date",
        page_size=10000,
    ),
    "heart-rate-variability": DataTypeSpec(
        data_type="heart-rate-variability",
        payload_key="heartRateVariability",
        metric="heart_rate_variability",
        storage="sample",
        unit="ms",
        filter_time_path="heart_rate_variability.sample_time.physical_time",
        page_size=10000,
    ),
    "daily-heart-rate-variability": DataTypeSpec(
        data_type="daily-heart-rate-variability",
        payload_key="dailyHeartRateVariability",
        metric="heart_rate_variability",
        storage="sample",
        unit="ms",
        filter_time_path="daily_heart_rate_variability.date",
        page_size=10000,
    ),
    "daily-heart-rate-zones": DataTypeSpec(
        data_type="daily-heart-rate-zones",
        payload_key="dailyHeartRateZones",
        metric="daily_heart_rate_zones",
        storage="raw",
        unit="zones",
        filter_time_path="daily_heart_rate_zones.date",
        page_size=10000,
        fail_sync_on_error=False,
        resume_page_tokens=False,
    ),
    "time-in-heart-rate-zone": DataTypeSpec(
        data_type="time-in-heart-rate-zone",
        payload_key="timeInHeartRateZone",
        metric="time_in_heart_rate_zone",
        storage="interval",
        unit="seconds",
        filter_time_path="time_in_heart_rate_zone.interval.civil_start_time",
        page_size=10000,
        fail_sync_on_error=False,
        use_timestamp_cursor=True,
    ),
    "oxygen-saturation": DataTypeSpec(
        data_type="oxygen-saturation",
        payload_key="oxygenSaturation",
        metric="oxygen_saturation",
        storage="sample",
        unit="percent",
        filter_time_path="oxygen_saturation.sample_time.physical_time",
        page_size=10000,
    ),
    "daily-oxygen-saturation": DataTypeSpec(
        data_type="daily-oxygen-saturation",
        payload_key="dailyOxygenSaturation",
        metric="oxygen_saturation",
        storage="sample",
        unit="percent",
        filter_time_path="daily_oxygen_saturation.date",
        page_size=10000,
    ),
    "daily-respiratory-rate": DataTypeSpec(
        data_type="daily-respiratory-rate",
        payload_key="dailyRespiratoryRate",
        metric="respiratory_rate",
        storage="sample",
        unit="breaths_per_min",
        filter_time_path="daily_respiratory_rate.date",
        page_size=10000,
    ),
    "respiratory-rate-sleep-summary": DataTypeSpec(
        data_type="respiratory-rate-sleep-summary",
        payload_key="respiratoryRateSleepSummary",
        metric="respiratory_rate",
        storage="sample",
        unit="breaths_per_min",
        filter_time_path="respiratory_rate_sleep_summary.sample_time.physical_time",
        page_size=10000,
    ),
    "sleep": DataTypeSpec(
        data_type="sleep",
        payload_key="sleep",
        metric="sleep",
        storage="sleep",
        unit="minutes",
        filter_time_path="sleep.interval.civil_end_time",
        prefer_reconcile=True,
        page_size=25,
    ),
    "exercise": DataTypeSpec(
        data_type="exercise",
        payload_key="exercise",
        metric="workout",
        storage="workout",
        unit="session",
        filter_time_path="exercise.interval.civil_start_time",
        page_size=25,
    ),
    "daily-vo2-max": DataTypeSpec(
        data_type="daily-vo2-max",
        payload_key="dailyVo2Max",
        metric="vo2_max",
        storage="sample",
        unit="ml_per_kg_min",
        filter_time_path="daily_vo2_max.date",
        page_size=10000,
    ),
    "run-vo2-max": DataTypeSpec(
        data_type="run-vo2-max",
        payload_key="runVo2Max",
        metric="run_vo2_max",
        storage="sample",
        unit="ml_per_kg_min",
        filter_time_path="run_vo2_max.sample_time.physical_time",
        page_size=10000,
        fail_sync_on_error=False,
    ),
    "daily-sleep-temperature-derivations": DataTypeSpec(
        data_type="daily-sleep-temperature-derivations",
        payload_key="dailySleepTemperatureDerivations",
        metric="sleep_temperature_derivation",
        storage="raw",
        unit="celsius",
        filter_time_path="daily_sleep_temperature_derivations.date",
        page_size=10000,
        fail_sync_on_error=False,
    ),
    "active-zone-minutes": DataTypeSpec(
        data_type="active-zone-minutes",
        payload_key="activeZoneMinutes",
        metric="active_zone_minutes",
        storage="interval",
        unit="minutes",
        filter_time_path="active_zone_minutes.interval.civil_start_time",
        page_size=10000,
        fail_sync_on_error=False,
    ),
    "nutrition-log": DataTypeSpec(
        data_type="nutrition-log",
        payload_key="nutritionLog",
        metric="nutrition_log",
        storage="raw",
        unit="log",
        filter_time_path="nutrition_log.interval.civil_start_time",
        page_size=10000,
        fail_sync_on_error=False,
    ),
    "blood-glucose": DataTypeSpec(
        data_type="blood-glucose",
        payload_key="bloodGlucose",
        metric="blood_glucose",
        storage="sample",
        unit="mg_dl",
        filter_time_path="blood_glucose.sample_time.physical_time",
        page_size=10000,
        fail_sync_on_error=False,
    ),
    "weight": DataTypeSpec(
        data_type="weight",
        payload_key="weight",
        metric="weight",
        storage="sample",
        unit="kg",
        filter_time_path="weight.sample_time.physical_time",
        page_size=10000,
    ),
    "height": DataTypeSpec(
        data_type="height",
        payload_key="height",
        metric="height",
        storage="sample",
        unit="meters",
        filter_time_path="height.sample_time.physical_time",
        page_size=10000,
    ),
}


MVP_SYNC_DATA_TYPES: tuple[str, ...] = (
    "steps",
    "distance",
    "active-energy-burned",
    "total-calories",
    "heart-rate",
    "daily-resting-heart-rate",
    "heart-rate-variability",
    "daily-heart-rate-variability",
    "daily-heart-rate-zones",
    "time-in-heart-rate-zone",
    "oxygen-saturation",
    "daily-oxygen-saturation",
    "daily-respiratory-rate",
    "respiratory-rate-sleep-summary",
    "sleep",
    "exercise",
    "daily-vo2-max",
    "run-vo2-max",
    "daily-sleep-temperature-derivations",
    "active-zone-minutes",
    "nutrition-log",
    "blood-glucose",
    "weight",
    "height",
)


WEARABLES_DATA_SOURCE_FAMILY = "users/me/dataSourceFamilies/google-wearables"
