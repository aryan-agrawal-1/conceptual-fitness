from __future__ import annotations

import logging
from collections.abc import Collection

from pydantic import TypeAdapter

from app.journal import (
    BooleanValue,
    DurationValue,
    JournalBehaviour,
    JournalCatalogue,
    JournalCategory,
    JournalField,
    JournalObservation,
    JournalValue,
    ManualJournalResponse,
    NormalizedJournalResponse,
    QuantityValue,
    UnitDefinition,
)


logger = logging.getLogger(__name__)

CATEGORIES = (
    JournalCategory(id="substances", label="Substances", requires_opt_in=True),
    JournalCategory(id="symptoms", label="Symptoms", requires_opt_in=True),
    JournalCategory(id="wellbeing", label="Wellbeing"),
    JournalCategory(id="work_travel", label="Work and travel"),
    JournalCategory(id="habits", label="Optional habits"),
    JournalCategory(id="medication_supplements", label="Medication and supplements", requires_opt_in=True),
    JournalCategory(id="reproductive_health", label="Reproductive health", requires_opt_in=True),
    JournalCategory(id="reflection", label="Reflection", requires_opt_in=True),
)
SENSITIVE_CATEGORIES = frozenset(item.id for item in CATEGORIES if item.requires_opt_in)

UNITS = (
    UnitDefinition(id="mg", label="Milligrams", canonical_unit="mg", multiplier=1),
    UnitDefinition(id="g", label="Grams", canonical_unit="mg", multiplier=1000),
    UnitDefinition(id="uk_alcohol_unit", label="UK units (10 mL pure alcohol)",
                   canonical_unit="mL_ethanol", multiplier=10),
    UnitDefinition(id="mL_ethanol", label="Millilitres of pure alcohol",
                   canonical_unit="mL_ethanol", multiplier=1),
    UnitDefinition(id="s", label="Seconds", canonical_unit="s", multiplier=1),
    UnitDefinition(id="min", label="Minutes", canonical_unit="s", multiplier=60),
    UnitDefinition(id="h", label="Hours", canonical_unit="s", multiplier=3600),
)


def boolean_behaviour(
    id: str,
    category: str,
    label: str,
    question: str,
    *details: JournalField,
) -> JournalBehaviour:
    return JournalBehaviour(
        id=id, category_id=category, label=label, question=question,
        answer=JournalField(id="answer", label=label, input_type="boolean"),
        details=details,
        presentation="discreet" if category in SENSITIVE_CATEGORIES else "standard",
    )


SEVERITY = JournalField(
    id="severity", label="Severity", input_type="rating", minimum=1, maximum=4,
    rating_labels=("Mild", "Moderate", "Severe", "Very severe"),
)
DURATION = JournalField(
    id="duration", label="Total duration", input_type="duration", minimum=0, maximum=86400,
    units=("s", "min", "h"),
)
LAST_USE = JournalField(id="last_use", label="Last use time", input_type="time")

BEHAVIOURS = (
    boolean_behaviour("caffeine", "substances", "Caffeine", "Did you have caffeine?",
                      JournalField(id="amount", label="Caffeine amount", input_type="quantity",
                                   minimum=0, maximum=100000, units=("mg", "g")),
                      JournalField(id="servings", label="Caffeinated drinks", input_type="count",
                                   minimum=0, maximum=1000), LAST_USE),
    boolean_behaviour("alcohol", "substances", "Alcohol", "Did you drink alcohol?",
                      JournalField(id="amount", label="Alcohol amount", input_type="quantity",
                                   minimum=0, maximum=10000,
                                   units=("uk_alcohol_unit", "mL_ethanol")), LAST_USE),
    boolean_behaviour("nicotine", "substances", "Nicotine", "Did you use nicotine?"),
    boolean_behaviour("cannabis", "substances", "Cannabis", "Did you use cannabis?"),
    boolean_behaviour("other_substances", "substances", "Other recreational substances",
                      "Did you use other recreational substances?"),
    boolean_behaviour("feeling_unwell", "symptoms", "Feeling unwell", "Did you feel unwell?"),
    boolean_behaviour("fever", "symptoms", "Fever", "Did you have a fever?"),
    boolean_behaviour("headache", "symptoms", "Headache", "Did you have a headache?", SEVERITY),
    boolean_behaviour("muscle_soreness", "symptoms", "Muscle soreness",
                      "Did you have muscle soreness?", SEVERITY),
    boolean_behaviour("pain", "symptoms", "Pain", "Did you have pain?", SEVERITY),
    boolean_behaviour("digestive_symptoms", "symptoms", "Digestive symptoms",
                      "Did you have digestive symptoms?", SEVERITY),
    boolean_behaviour("allergy_symptoms", "symptoms", "Allergy symptoms",
                      "Did you have allergy symptoms?", SEVERITY),
    JournalBehaviour(
        id="mood", category_id="wellbeing", label="Mood", question="How was your mood?",
        answer=JournalField(id="answer", label="Mood", input_type="rating", minimum=1, maximum=5,
                            rating_labels=("Very low", "Low", "Okay", "Good", "Very good")),
    ),
    JournalBehaviour(
        id="stress", category_id="wellbeing", label="Perceived stress",
        question="How stressed did you feel?",
        answer=JournalField(id="answer", label="Stress", input_type="rating", minimum=1, maximum=5,
                            rating_labels=("Not at all", "A little", "Moderately", "Very", "Extremely")),
    ),
    JournalBehaviour(
        id="energy", category_id="wellbeing", label="Energy", question="How was your energy?",
        answer=JournalField(id="answer", label="Energy", input_type="rating", minimum=1, maximum=5,
                            rating_labels=("Very low", "Low", "Moderate", "High", "Very high")),
    ),
    boolean_behaviour("worked_late", "work_travel", "Worked late", "Did you work late?"),
    boolean_behaviour("night_shift", "work_travel", "Night shift", "Did you work a night shift?"),
    boolean_behaviour("travel", "work_travel", "Travel", "Did you travel?"),
    boolean_behaviour("screen_in_bed", "habits", "Screen use in bed", "Did you use a screen in bed?"),
    boolean_behaviour("sleep_mask", "habits", "Sleep mask", "Did you use a sleep mask?"),
    boolean_behaviour("sauna", "habits", "Sauna", "Did you use a sauna?", DURATION),
    boolean_behaviour("cold_exposure", "habits", "Cold exposure",
                      "Did you have deliberate cold exposure?", DURATION),
    boolean_behaviour("usual_medication", "medication_supplements", "Usual medication taken",
                      "Did you take all your usual planned medication?"),
    boolean_behaviour("supplements", "medication_supplements", "Supplements taken",
                      "Did you take supplements?"),
    boolean_behaviour("menstrual_bleeding", "reproductive_health", "Menstrual bleeding",
                      "Did you have menstrual bleeding?",
                      JournalField(id="intensity", label="Flow", input_type="rating",
                                   minimum=1, maximum=4,
                                   rating_labels=("Spotting", "Light", "Moderate", "Heavy"))),
    boolean_behaviour("menstrual_cramps", "reproductive_health", "Menstrual cramps",
                      "Did you have menstrual cramps?", SEVERITY),
    JournalBehaviour(
        id="daily_note", category_id="reflection", label="Daily note",
        question="What would you like to note about this day?",
        answer=JournalField(id="answer", label="Daily note", input_type="text"),
        presentation="discreet", statistical_input=False,
    ),
)

CATALOGUE_V1 = JournalCatalogue(
    version=1, schema_version=1, categories=CATEGORIES, behaviours=BEHAVIOURS,
    units=UNITS, observation_schema=TypeAdapter(JournalObservation).json_schema(),
)
CATALOGUES = {1: CATALOGUE_V1}


class JournalContractError(ValueError):
    def __init__(self, code: str):
        self.code = code
        # Behaviour IDs, values and prose must never enter diagnostics.
        logger.warning("Journal response rejected reason=%s", code)
        super().__init__(code)


def normalize_field(
    value: JournalValue, field: JournalField, units: tuple[UnitDefinition, ...],
) -> JournalValue:
    if value.type != field.input_type:
        raise JournalContractError("input_type_mismatch")
    if isinstance(value, (QuantityValue, DurationValue)):
        if value.unit not in field.units:
            raise JournalContractError("unsupported_unit")
        unit = next(item for item in units if item.id == value.unit)
        value = value.model_copy(update={"value": value.value * unit.multiplier,
                                         "unit": unit.canonical_unit})
    if field.minimum is not None and value.value < field.minimum:
        raise JournalContractError("value_out_of_range")
    if field.maximum is not None and value.value > field.maximum:
        raise JournalContractError("value_out_of_range")
    return value


def normalize_journal_response(
    response: ManualJournalResponse,
    *,
    opted_in_categories: Collection[str] = (),
) -> NormalizedJournalResponse:
    """Resolve against the exact version; callers supply trusted, saved consent."""
    response = ManualJournalResponse.model_validate(response)
    catalogue = CATALOGUES.get(response.catalogue_version)
    if catalogue is None:
        raise JournalContractError("unsupported_catalogue_version")
    behaviour = next((item for item in catalogue.behaviours
                      if item.id == response.behaviour_id), None)
    if behaviour is None:
        raise JournalContractError("unknown_behaviour")
    category = next(item for item in catalogue.categories if item.id == behaviour.category_id)
    if category.requires_opt_in:
        if behaviour.category_id not in opted_in_categories:
            raise JournalContractError("opt_in_required")
    fields = {item.id: item for item in behaviour.details}
    if response.details.keys() - fields.keys():
        raise JournalContractError("unknown_detail")
    if isinstance(response.answer, BooleanValue) and not response.answer.value and response.details:
        raise JournalContractError("details_require_yes")
    answer = (
        normalize_field(response.answer, behaviour.answer, catalogue.units)
        if response.answer is not None else None
    )
    return NormalizedJournalResponse(
        entered=response,
        canonical_answer=answer,
        canonical_details={key: normalize_field(value, fields[key], catalogue.units)
                           for key, value in response.details.items()},
    )
