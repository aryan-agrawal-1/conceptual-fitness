from __future__ import annotations

import json

import pytest
from pydantic import TypeAdapter, ValidationError

from app.journal import (
    AutomaticJournalContext,
    CountValue,
    JournalObservation,
    JournalValue,
    ManualJournalResponse,
    QuantityValue,
)
from app.services.journal_catalogue import (
    CATALOGUE_V1,
    JournalContractError,
    SENSITIVE_CATEGORIES,
    normalize_journal_response,
)


def response_for(behaviour="caffeine", answer=None, **updates):
    return ManualJournalResponse.model_validate({
        "journal_date": "2026-10-27",
        "timezone": "Europe/London",
        "recorded_at": "2026-10-28T08:00:00Z",
        "behaviour_id": behaviour,
        "answer": answer,
        **updates,
    })


def normalize(response):
    return normalize_journal_response(response, opted_in_categories=SENSITIVE_CATEGORIES)


def test_catalogue_preserves_the_agreed_scope_and_discreet_policy():
    catalogue = CATALOGUE_V1
    ids = {item.id for item in catalogue.behaviours}
    assert ids == {
        "caffeine", "alcohol", "nicotine", "cannabis", "other_substances", "feeling_unwell",
        "fever", "headache", "muscle_soreness", "pain", "digestive_symptoms", "allergy_symptoms",
        "mood", "stress", "energy", "worked_late", "night_shift", "travel", "screen_in_bed",
        "sleep_mask", "sauna", "cold_exposure", "usual_medication", "supplements",
        "menstrual_bleeding", "menstrual_cramps", "daily_note",
    }
    assert len(ids) == len(catalogue.behaviours)
    assert SENSITIVE_CATEGORIES == {
        "substances", "symptoms", "medication_supplements", "reproductive_health", "reflection",
    }
    categories = {item.id for item in catalogue.categories}
    units = {item.id for item in catalogue.units}
    assert {item.canonical_unit for item in catalogue.units} <= units
    for behaviour in catalogue.behaviours:
        assert behaviour.category_id in categories
        assert bool(behaviour.question.strip())
        assert behaviour.reference_period == "journal_day"
        assert (behaviour.presentation == "discreet") == (
            behaviour.category_id in SENSITIVE_CATEGORIES
        )
        assert behaviour.discreet_label == "Private journal item"
        fields = (behaviour.answer, *behaviour.details)
        assert len({field.id for field in fields}) == len(fields)
        for field in fields:
            assert set(field.units) <= units
            if field.input_type == "rating":
                assert len(field.rating_labels) == field.maximum - field.minimum + 1
            if field.input_type in {"quantity", "duration"}:
                assert field.units and field.minimum is not None and field.maximum is not None
    note = next(item for item in catalogue.behaviours if item.id == "daily_note")
    assert note.statistical_input is False
    assert all(item.statistical_input for item in catalogue.behaviours if item != note)


@pytest.mark.parametrize("value", [
    {"type": "boolean", "value": False},
    {"type": "count", "value": 0},
    {"type": "quantity", "value": 0, "unit": "mg"},
    {"type": "duration", "value": 0, "unit": "s"},
    {"type": "rating", "value": 1},
    {"type": "time", "value": "00:00"},
    {"type": "text", "value": "  Keep the entered text  "},
])
def test_typed_values_round_trip_without_losing_false_zero_or_entered_text(value):
    adapter = TypeAdapter(JournalValue)
    assert adapter.validate_json(json.dumps(value)).model_dump() == value


@pytest.mark.parametrize("value", [
    {"type": "boolean", "value": "false"},
    {"type": "boolean", "value": 0},
    {"type": "count", "value": False},
    {"type": "count", "value": 1.5},
    {"type": "count", "value": -1},
    {"type": "quantity", "value": True, "unit": "mg"},
    {"type": "quantity", "value": "10", "unit": "mg"},
    {"type": "quantity", "value": float("nan"), "unit": "mg"},
    {"type": "quantity", "value": float("inf"), "unit": "mg"},
    {"type": "duration", "value": -1, "unit": "s"},
    {"type": "duration", "value": 1, "unit": "days"},
    {"type": "rating", "value": True},
    {"type": "rating", "value": 2.5},
    {"type": "time", "value": "24:00"},
    {"type": "time", "value": "12:60"},
    {"type": "time", "value": "1:00"},
    {"type": "text", "value": "  "},
    {"type": "text", "value": "x" * 2001},
    {"type": "boolean", "value": False, "extra": True},
    {"type": "unknown", "value": 1},
])
def test_invalid_or_coercible_values_are_rejected(value):
    with pytest.raises(ValidationError):
        TypeAdapter(JournalValue).validate_python(value)


def test_missing_is_unknown_and_false_and_zero_remain_explicit():
    unanswered = normalize(response_for())
    assert unanswered.entered.missing_reason == "not_answered"
    assert unanswered.canonical_answer is None
    for reason in ("skipped", "not_applicable", "unavailable"):
        missing = normalize(response_for(missing_reason=reason))
        assert missing.entered.missing_reason == reason
        assert missing.canonical_answer is None
    negative = normalize(response_for(answer={"type": "boolean", "value": False}))
    assert negative.entered.missing_reason is None
    assert negative.canonical_answer.value is False
    zero = normalize(response_for(answer={"type": "boolean", "value": True}, details={
        "servings": {"type": "count", "value": 0},
        "amount": {"type": "quantity", "value": 0, "unit": "mg"},
    }))
    assert zero.canonical_details["servings"].value == 0
    assert zero.canonical_details["amount"].value == 0
    with pytest.raises(ValidationError):
        response_for(answer={"type": "boolean", "value": False}, missing_reason="skipped")
    with pytest.raises(ValidationError):
        response_for(details={"servings": {"type": "count", "value": 1}})


@pytest.mark.parametrize("behaviour,unit,amount,canonical_unit,expected", [
    ("caffeine", "g", 0.2, "mg", 200),
    ("caffeine", "mg", 200, "mg", 200),
    ("alcohol", "uk_alcohol_unit", 2.5, "mL_ethanol", 25),
    ("alcohol", "mL_ethanol", 25, "mL_ethanol", 25),
    ("sauna", "min", 20, "s", 1200),
    ("cold_exposure", "h", 0.5, "s", 1800),
])
def test_normalization_preserves_entered_units_and_provenance(
    behaviour, unit, amount, canonical_unit, expected,
):
    field = "duration" if behaviour in {"sauna", "cold_exposure"} else "amount"
    input_type = "duration" if field == "duration" else "quantity"
    entered = response_for(behaviour, {"type": "boolean", "value": True}, details={
        field: {"type": input_type, "value": amount, "unit": unit},
    }, observed_at="2026-10-27T15:00:00+00:00")
    normalized = normalize(entered)
    assert normalized.canonical_details[field].value == pytest.approx(expected)
    assert normalized.canonical_details[field].unit == canonical_unit
    assert normalized.entered == entered
    assert normalized.entered.details[field].unit == unit
    assert normalized.entered.observed_at.isoformat() == "2026-10-27T15:00:00+00:00"
    assert normalized.entered.recorded_at.isoformat() == "2026-10-28T08:00:00+00:00"
    assert normalized.entered.journal_date.isoformat() == "2026-10-27"
    assert normalized.entered.timezone == "Europe/London"


@pytest.mark.parametrize("behaviour,answer,updates,code", [
    ("unknown", {"type": "boolean", "value": True}, {}, "unknown_behaviour"),
    ("caffeine", None, {"catalogue_version": 2}, "unsupported_catalogue_version"),
    ("caffeine", {"type": "count", "value": 1}, {}, "input_type_mismatch"),
    ("mood", {"type": "rating", "value": 0}, {}, "value_out_of_range"),
    ("stress", {"type": "rating", "value": 6}, {}, "value_out_of_range"),
    ("caffeine", {"type": "boolean", "value": True}, {"details": {
        "amount": {"type": "quantity", "value": 1, "unit": "uk_alcohol_unit"},
    }}, "unsupported_unit"),
    ("caffeine", {"type": "boolean", "value": True}, {"details": {
        "amount": {"type": "quantity", "value": 101, "unit": "g"},
    }}, "value_out_of_range"),
    ("sauna", {"type": "boolean", "value": True}, {"details": {
        "duration": {"type": "duration", "value": 25, "unit": "h"},
    }}, "value_out_of_range"),
    ("caffeine", {"type": "boolean", "value": True}, {"details": {
        "dose": {"type": "count", "value": 1},
    }}, "unknown_detail"),
    ("caffeine", {"type": "boolean", "value": False}, {"details": {
        "amount": {"type": "quantity", "value": 200, "unit": "mg"},
    }}, "details_require_yes"),
    ("pain", {"type": "boolean", "value": True}, {"details": {
        "severity": {"type": "rating", "value": 0},
    }}, "value_out_of_range"),
])
def test_catalogue_bound_validation(behaviour, answer, updates, code):
    with pytest.raises(JournalContractError) as error:
        normalize(response_for(behaviour, answer, **updates))
    assert error.value.code == code


def test_every_sensitive_category_requires_its_own_opt_in():
    for behaviour in CATALOGUE_V1.behaviours:
        if behaviour.category_id not in SENSITIVE_CATEGORIES:
            continue
        response = response_for(behaviour.id)
        for opt_ins in ((), SENSITIVE_CATEGORIES - {behaviour.category_id}):
            with pytest.raises(JournalContractError, match="opt_in_required"):
                normalize_journal_response(response, opted_in_categories=opt_ins)
        assert normalize_journal_response(
            response, opted_in_categories={behaviour.category_id},
        ).canonical_answer is None
    assert normalize_journal_response(response_for("worked_late", {
        "type": "boolean", "value": False,
    })).canonical_answer.value is False


def test_contract_errors_never_log_values_prose_or_sensitive_behaviour_names(caplog):
    secret = "private reflection that must not appear in diagnostics"
    with pytest.raises(JournalContractError):
        normalize(response_for("caffeine", {"type": "text", "value": secret}))
    assert "reason=input_type_mismatch" in caplog.text
    assert secret not in caplog.text
    assert "caffeine" not in caplog.text
    with pytest.raises(ValidationError) as error:
        response_for("daily_note", {"type": "text", "value": secret, "extra": secret})
    assert secret not in str(error.value)


@pytest.mark.parametrize("updates", [
    {"schema_version": 2}, {"schema_version": True}, {"catalogue_version": "1"},
    {"timezone": "Unknown/Place"}, {"timezone": "../UTC"},
    {"recorded_at": "2026-10-28T08:00:00"}, {"observed_at": "2026-10-27T15:00:00"},
    {"journal_date": "2026-02-30"}, {"consent": True},
    {"journal_date": 1793059200}, {"journal_date": "1793059200"},
    {"journal_date": "2026-10-27T00:00:00Z"},
    {"recorded_at": 1793174400}, {"recorded_at": "1793174400"},
    {"observed_at": 1793174400},
])
def test_record_metadata_rejects_invalid_dates_versions_and_untrusted_consent(updates):
    with pytest.raises(ValidationError):
        response_for(**updates)


def test_normalization_revalidates_edited_details_and_snapshots_the_entered_response():
    unanswered = response_for()
    unanswered.details["servings"] = CountValue(value=2)
    with pytest.raises(ValidationError):
        normalize(unanswered)

    answered = response_for(answer={"type": "boolean", "value": True})
    normalized = normalize(answered)
    answered.details["servings"] = CountValue(value=2)
    assert normalized.entered.details == normalized.canonical_details == {}

    answered.details["amount"] = QuantityValue(value=1, unit="mg").model_copy(
        update={"value": float("nan")},
    )
    with pytest.raises(ValidationError):
        normalize(answered)


@pytest.mark.parametrize("field", ["source_name", "record_id"])
def test_automatic_references_reject_whitespace_identifiers(field):
    with pytest.raises(ValidationError):
        AutomaticJournalContext.model_validate({
            "journal_date": "2026-10-27", "timezone": "UTC",
            "recorded_at": "2026-10-28T08:00:00Z", "source": "provider",
            "source_name": "google_health", "record_type": "workout", "record_id": "workout-1",
            field: " \t\n ",
        })


def test_automatic_context_references_existing_records_and_cannot_be_a_manual_answer():
    payload = {
        "kind": "automatic", "schema_version": 1, "journal_date": "2026-10-27",
        "timezone": "Europe/London", "recorded_at": "2026-10-28T08:00:00Z",
        "observed_at": "2026-10-27T23:00:00Z", "source": "provider",
        "source_name": "google_health", "record_type": "sleep_session", "record_id": "sleep-1",
    }
    adapter = TypeAdapter(JournalObservation)
    context = adapter.validate_json(json.dumps(payload))
    assert isinstance(context, AutomaticJournalContext)
    assert adapter.validate_json(context.model_dump_json()) == context
    with pytest.raises(ValidationError):
        adapter.validate_python({**payload, "answer": {"type": "boolean", "value": True}})
    with pytest.raises(ValidationError):
        ManualJournalResponse.model_validate(payload)
    with pytest.raises(ValidationError):
        response_for(answer=payload)
    manual = response_for("worked_late", {"type": "boolean", "value": False})
    assert isinstance(adapter.validate_json(manual.model_dump_json()), ManualJournalResponse)
