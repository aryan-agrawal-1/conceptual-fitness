from __future__ import annotations


SAFETY_VERSION = "behaviour_safety_v1"
NOT_ADVICE = "This is an observation from your own logs, not medical advice."
URGENT_HELP = "If you feel seriously unwell, contact a doctor or emergency services."
SENSITIVE_INPUTS = dict(
    usual_medication="medication", supplements="medication",
    headache="symptom", muscle_soreness="symptom", pain="symptom", digestive_symptoms="symptom",
    allergy_symptoms="symptom", feeling_unwell="symptom", fever="symptom",
    mood="mental_health", stress="mental_health",
    menstrual_bleeding="reproductive", menstrual_cramps="reproductive",
    alcohol="substance", nicotine="substance", cannabis="substance", other_substances="substance",
)
MENTAL_HEALTH_OUTCOMES = ("mood_next", "stress_next", "mood_morning", "stress_morning")
SAFETY_NOTES = dict(
    medication=f"{NOT_ADVICE} Do not start, stop or change a medication or supplement because of it. "
               "Talk to your doctor or pharmacist before making any change.",
    symptom=f"{NOT_ADVICE} It cannot diagnose anything, and a symptom can be a result of changes in your "
            f"body as well as a cause. {URGENT_HELP}",
    mental_health=f"{NOT_ADVICE} It is not a mental health assessment. If low mood or stress is affecting "
                  "your daily life, talk to a doctor.",
    reproductive=f"{NOT_ADVICE} Cycle-related changes vary between people and from month to month. "
                 "Talk to a doctor about any symptoms that worry you.",
    substance=f"{NOT_ADVICE} It is not a reason to drink, smoke or use more.",
)
SUBSTANCE_NOUNS = dict(alcohol="drank", nicotine="used nicotine")
FAVOURABLE_LIMITATIONS = dict(
    alcohol="People often drink on days that are already going well. This passed extra checks for that, "
            "but they cannot rule it out.",
    nicotine="Nicotine use often follows how a day is already going. This passed extra checks for that, "
             "but they cannot rule it out.",
)
FAILED_CHECK_TEXT = dict(
    before_exposure="the difference was already there before you {noun}",
    sick_days="it changed when sick days were counted",
    weekend="it changed once weekends were accounted for",
    unavailable="the checks could not be run on your data yet",
)
MEDICATION_LIMITATION = "Only whether you took it is recorded, not what it was or how much."
GENERAL_NOTE = "Patterns are observations from your own data, not medical advice."


def category_for(input_id, outcome_ids=()):
    if input_id in SENSITIVE_INPUTS:
        return SENSITIVE_INPUTS[input_id]
    if any(outcome in MENTAL_HEALTH_OUTCOMES for outcome in outcome_ids):
        return "mental_health"
    return None


def note_for(input_id, outcome_ids=()):
    category = category_for(input_id, outcome_ids)
    return SAFETY_NOTES[category] if category else None


def held_back_text(input_id, failed):
    noun = SUBSTANCE_NOUNS.get(input_id, "logged it")
    reasons = [FAILED_CHECK_TEXT[name].format(noun=noun) for name in failed if name in FAILED_CHECK_TEXT]
    if not reasons:
        return "This result is not shown because it did not pass extra safety checks."
    return "This result is not shown because " + " and ".join(reasons) + "."
