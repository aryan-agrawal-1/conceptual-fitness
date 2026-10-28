"""Version 1 journal wire types. Persistence and synchronization belong to issue #16."""

from __future__ import annotations

from datetime import date, datetime
from re import fullmatch
from typing import Annotated, Any, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    StrictBool,
    StrictInt,
    field_validator,
    model_validator,
)


class JournalModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid", frozen=True, hide_input_in_errors=True, revalidate_instances="always",
    )


class BooleanValue(JournalModel):
    type: Literal["boolean"] = "boolean"
    value: StrictBool


class CountValue(JournalModel):
    type: Literal["count"] = "count"
    value: StrictInt = Field(ge=0, le=1000000)


class QuantityValue(JournalModel):
    type: Literal["quantity"] = "quantity"
    value: float = Field(strict=True, ge=0, le=1000000000, allow_inf_nan=False)
    unit: str = Field(min_length=1, max_length=32)


class DurationValue(JournalModel):
    type: Literal["duration"] = "duration"
    value: float = Field(strict=True, ge=0, le=86400, allow_inf_nan=False)
    unit: Literal["s", "min", "h"]


class RatingValue(JournalModel):
    type: Literal["rating"] = "rating"
    value: StrictInt = Field(ge=0, le=10)


class TimeValue(JournalModel):
    type: Literal["time"] = "time"
    value: str = Field(pattern=r"^([01][0-9]|2[0-3]):[0-5][0-9]$")


class TextValue(JournalModel):
    type: Literal["text"] = "text"
    value: str = Field(min_length=1, max_length=2000)

    @field_validator("value")
    @classmethod
    def reject_blank_text(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Text must not be blank")
        return value


JournalValue = Annotated[
    BooleanValue | CountValue | QuantityValue | DurationValue | RatingValue | TimeValue | TextValue,
    Field(discriminator="type"),
]
InputType = Literal["boolean", "count", "quantity", "duration", "rating", "time", "text"]
MissingReason = Literal["not_answered", "skipped", "not_applicable", "unavailable"]


class JournalRecord(JournalModel):
    schema_version: int = Field(default=1, strict=True, json_schema_extra={"const": 1})
    journal_date: date
    timezone: str = Field(min_length=1, max_length=80)
    recorded_at: AwareDatetime
    observed_at: AwareDatetime | None = None

    @field_validator("journal_date", mode="before")
    @classmethod
    def calendar_date(cls, value: Any) -> Any:
        if type(value) is date or (
            isinstance(value, str) and fullmatch(r"\d{4}-\d{2}-\d{2}", value)
        ):
            return value
        raise ValueError("Journal date must be an ISO calendar date")

    @field_validator("recorded_at", "observed_at", mode="before")
    @classmethod
    def explicit_timestamp(cls, value: Any) -> Any:
        if value is None or isinstance(value, datetime) or (
            isinstance(value, str) and "T" in value
        ):
            return value
        raise ValueError("Timestamp must be an ISO datetime with an offset")

    @field_validator("schema_version")
    @classmethod
    def supported_schema(cls, value: int) -> int:
        if value != 1:
            raise ValueError("Unsupported journal schema version")
        return value

    @field_validator("timezone")
    @classmethod
    def known_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("Unknown timezone") from exc
        return value


class ManualJournalResponse(JournalRecord):
    kind: Literal["manual"] = "manual"
    catalogue_version: int = Field(default=1, strict=True, ge=1)
    behaviour_id: str = Field(min_length=1, max_length=80)
    answer: JournalValue | None = None
    details: dict[str, JournalValue] = Field(default_factory=dict, max_length=3)
    missing_reason: MissingReason | None = None

    @model_validator(mode="before")
    @classmethod
    def consistent_missingness(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        if data.get("answer") is None:
            if data.get("details"):
                raise ValueError("Details require an answer")
            if data.get("missing_reason") is None:
                return {**data, "missing_reason": "not_answered"}
        elif data.get("missing_reason") is not None:
            raise ValueError("Answered responses cannot have a missing reason")
        return data


class AutomaticJournalContext(JournalRecord):
    """A reference, never a copied metric or an intentional manual response."""

    kind: Literal["automatic"] = "automatic"
    source: Literal["provider", "derived"]
    source_name: str = Field(min_length=1, max_length=80, pattern=r"\S")
    record_type: Literal[
        "metric_sample", "metric_daily_rollup", "sleep_session", "workout",
        "daily_summary", "daily_score",
    ]
    record_id: str = Field(min_length=1, max_length=80, pattern=r"\S")


JournalObservation = Annotated[
    ManualJournalResponse | AutomaticJournalContext, Field(discriminator="kind")
]


class UnitDefinition(JournalModel):
    id: str
    label: str
    canonical_unit: str
    multiplier: float


class JournalField(JournalModel):
    """Numeric bounds apply after conversion into canonical units."""

    id: str
    label: str
    input_type: InputType
    minimum: float | None = None
    maximum: float | None = None
    units: tuple[str, ...] = ()
    rating_labels: tuple[str, ...] = ()


class JournalCategory(JournalModel):
    id: str
    label: str
    requires_opt_in: bool = False


class JournalBehaviour(JournalModel):
    id: str
    category_id: str
    label: str
    question: str
    answer: JournalField
    details: tuple[JournalField, ...] = ()
    presentation: Literal["standard", "discreet"] = "standard"
    discreet_label: str = "Private journal item"
    statistical_input: bool = True
    reference_period: Literal["journal_day"] = "journal_day"


class JournalCatalogue(JournalModel):
    version: int
    schema_version: int
    categories: tuple[JournalCategory, ...]
    behaviours: tuple[JournalBehaviour, ...]
    units: tuple[UnitDefinition, ...]
    observation_schema: dict


class NormalizedJournalResponse(JournalModel):
    entered: ManualJournalResponse
    canonical_answer: JournalValue | None
    canonical_details: dict[str, JournalValue]
