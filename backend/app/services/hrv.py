from __future__ import annotations

from typing import Any

HRV_METRIC = "heart_rate_variability"
RMSSD = "rmssd"
SDNN = "sdnn"
HRV_PAYLOAD_FIELDS = (
    ("rootMeanSquareOfSuccessiveDifferencesMilliseconds", RMSSD),
    ("averageHeartRateVariabilityMilliseconds", RMSSD),
    ("standardDeviationMilliseconds", SDNN),
)
APPROVED_HRV_PLATFORMS = {"FITBIT"}
RMSSD_CALIBRATED_NIGHTS = 28
RMSSD_CALIBRATION_WINDOW_DAYS = 60


def hrv_measurement(payload: dict[str, Any]) -> tuple[float | None, str | None]:
    for field, measurement_type in HRV_PAYLOAD_FIELDS:
        try:
            value = float(payload[field])
        except (KeyError, TypeError, ValueError):
            continue
        return value, measurement_type
    return None, None


def approved_hrv_platforms() -> set[str]:
    return APPROVED_HRV_PLATFORMS


def hrv_source_approved(source_platform: str | None) -> bool:
    return source_platform in approved_hrv_platforms()


def hrv_value_of_type(summary: Any, measurement_type: str | None) -> float | None:
    if summary is None or measurement_type is None:
        return None
    return summary.hrv_sdnn if measurement_type == SDNN else summary.hrv_rmssd


def selected_hrv_type(rmssd: float | None, sdnn: float | None, rmssd_nights: int) -> str | None:
    if rmssd is not None and (sdnn is None or rmssd_nights >= RMSSD_CALIBRATED_NIGHTS):
        return RMSSD
    if sdnn is not None:
        return SDNN
    return None
