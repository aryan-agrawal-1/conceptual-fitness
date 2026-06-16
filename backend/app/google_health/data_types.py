from __future__ import annotations

from dataclasses import dataclass


GOOGLE_HEALTH_API_BASE_URL = "https://health.googleapis.com/v4"
GOOGLE_OAUTH_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_OAUTH_REVOKE_URL = "https://oauth2.googleapis.com/revoke"


@dataclass(frozen=True)
class DataTypeSpec:
    data_type: str
    payload_key: str
    metric: str
    storage: str
    unit: str
    filter_time_path: str
    prefer_reconcile: bool = False

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
    ),
    "distance": DataTypeSpec(
        data_type="distance",
        payload_key="distance",
        metric="distance",
        storage="interval",
        unit="meters",
        filter_time_path="distance.interval.civil_start_time",
    ),
    "active-energy-burned": DataTypeSpec(
        data_type="active-energy-burned",
        payload_key="activeEnergyBurned",
        metric="active_calories",
        storage="interval",
        unit="kcal",
        filter_time_path="active_energy_burned.interval.civil_start_time",
    ),
    "total-calories": DataTypeSpec(
        data_type="total-calories",
        payload_key="totalCalories",
        metric="total_calories",
        storage="interval",
        unit="kcal",
        filter_time_path="total_calories.interval.civil_start_time",
    ),
    "heart-rate": DataTypeSpec(
        data_type="heart-rate",
        payload_key="heartRate",
        metric="heart_rate",
        storage="sample",
        unit="bpm",
        filter_time_path="heart_rate.sample_time.physical_time",
    ),
    "daily-resting-heart-rate": DataTypeSpec(
        data_type="daily-resting-heart-rate",
        payload_key="dailyRestingHeartRate",
        metric="resting_heart_rate",
        storage="sample",
        unit="bpm",
        filter_time_path="daily_resting_heart_rate.sample_time.physical_time",
    ),
    "heart-rate-variability": DataTypeSpec(
        data_type="heart-rate-variability",
        payload_key="heartRateVariability",
        metric="heart_rate_variability",
        storage="sample",
        unit="ms",
        filter_time_path="heart_rate_variability.sample_time.physical_time",
    ),
    "daily-heart-rate-variability": DataTypeSpec(
        data_type="daily-heart-rate-variability",
        payload_key="dailyHeartRateVariability",
        metric="heart_rate_variability",
        storage="sample",
        unit="ms",
        filter_time_path="daily_heart_rate_variability.sample_time.physical_time",
    ),
    "oxygen-saturation": DataTypeSpec(
        data_type="oxygen-saturation",
        payload_key="oxygenSaturation",
        metric="oxygen_saturation",
        storage="sample",
        unit="percent",
        filter_time_path="oxygen_saturation.sample_time.physical_time",
    ),
    "daily-oxygen-saturation": DataTypeSpec(
        data_type="daily-oxygen-saturation",
        payload_key="dailyOxygenSaturation",
        metric="oxygen_saturation",
        storage="sample",
        unit="percent",
        filter_time_path="daily_oxygen_saturation.sample_time.physical_time",
    ),
    "daily-respiratory-rate": DataTypeSpec(
        data_type="daily-respiratory-rate",
        payload_key="dailyRespiratoryRate",
        metric="respiratory_rate",
        storage="sample",
        unit="breaths_per_min",
        filter_time_path="daily_respiratory_rate.sample_time.physical_time",
    ),
    "respiratory-rate-sleep-summary": DataTypeSpec(
        data_type="respiratory-rate-sleep-summary",
        payload_key="respiratoryRateSleepSummary",
        metric="respiratory_rate",
        storage="sample",
        unit="breaths_per_min",
        filter_time_path="respiratory_rate_sleep_summary.sample_time.physical_time",
    ),
    "sleep": DataTypeSpec(
        data_type="sleep",
        payload_key="sleep",
        metric="sleep",
        storage="sleep",
        unit="minutes",
        filter_time_path="sleep.interval.civil_end_time",
        prefer_reconcile=True,
    ),
    "exercise": DataTypeSpec(
        data_type="exercise",
        payload_key="exercise",
        metric="workout",
        storage="workout",
        unit="session",
        filter_time_path="exercise.interval.civil_start_time",
        prefer_reconcile=True,
    ),
    "daily-vo2-max": DataTypeSpec(
        data_type="daily-vo2-max",
        payload_key="dailyVo2Max",
        metric="vo2_max",
        storage="sample",
        unit="ml_per_kg_min",
        filter_time_path="daily_vo2_max.sample_time.physical_time",
    ),
    "weight": DataTypeSpec(
        data_type="weight",
        payload_key="weight",
        metric="weight",
        storage="sample",
        unit="kg",
        filter_time_path="weight.sample_time.physical_time",
    ),
    "height": DataTypeSpec(
        data_type="height",
        payload_key="height",
        metric="height",
        storage="sample",
        unit="meters",
        filter_time_path="height.sample_time.physical_time",
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
    "oxygen-saturation",
    "daily-oxygen-saturation",
    "daily-respiratory-rate",
    "respiratory-rate-sleep-summary",
    "sleep",
    "exercise",
    "daily-vo2-max",
)


WEARABLES_DATA_SOURCE_FAMILY = "users/me/dataSourceFamilies/google-wearables"

