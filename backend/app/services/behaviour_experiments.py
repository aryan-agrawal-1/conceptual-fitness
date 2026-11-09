from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import time, timedelta
from statistics import mean, median

from sqlalchemy import select

from app.core.security import utcnow
from app.models import BehaviourExperiment
from app.services.behaviour_map import BEHAVIOUR_MAP_V1
from app.services.behaviour_presentation import (
    BETTER_DIRECTION, FINDING_STATES, NEUTRAL_BANDS, OUTCOME_NOUNS, OUTCOME_SUBJECTS, UNIT_TEXT, direction_word,
    number,
)
from app.services.behaviour_safety import note_for
from app.services.behaviour_series import detail_value, dose_value, load_user_data, outcome_for, sick_days


logger = logging.getLogger(__name__)

EXPERIMENT_DAYS = 28
BLOCK_DAYS = 7
WASHOUT_DAYS = 2
MIN_VALID_DAYS = 6
RESULT_DELAY_DAYS = 2
USUAL_WINDOW_DAYS = 28
USUAL_TEXT = "Usual week: do what you normally do"
ONE_PERSON_TEXT = "This is one person's result over a short period. It is not proof that the change caused " \
                  "the difference, and other things in your life may have changed too."


@dataclass(frozen=True)
class ExperimentBehaviour:
    id: str
    input_id: str
    title: str
    change_text: str
    option_title: str = ""
    detail: str = ""
    slip: str = ""
    latest_use: time | None = None
    weekly_units: float | None = None


WEEKLY_UNIT_BUDGETS = (4, 7, 10, 14)
TESTABLE_BEHAVIOURS = (
    ExperimentBehaviour("caffeine_free", "caffeine", "Caffeine-free weeks", "Change week: no caffeine",
                        "No caffeine", "No coffee, tea, energy drinks or other caffeine all week.", "caffeine"),
    ExperimentBehaviour("caffeine_before_noon", "caffeine", "No caffeine after noon",
                        "Change week: no caffeine after noon", "Finish caffeine by noon",
                        "Have your last caffeine before 12pm each day. Log the time in your check-in.",
                        "caffeine after noon", latest_use=time(12)),
    ExperimentBehaviour("caffeine_before_2pm", "caffeine", "No caffeine after 2pm",
                        "Change week: no caffeine after 2pm", "Finish caffeine by 2pm",
                        "Have your last caffeine before 2pm each day. Log the time in your check-in.",
                        "caffeine after 2pm", latest_use=time(14)),
    ExperimentBehaviour("alcohol_free", "alcohol", "Alcohol-free weeks", "Change week: no alcohol",
                        "No alcohol", "No alcohol all week.", "alcohol"),
    *(ExperimentBehaviour(f"alcohol_week_{units}", "alcohol", f"Up to {units} units a week",
                          f"Change week: no more than {units} units of alcohol this week",
                          f"Up to {units} units a week",
                          f"Up to {units} units in total across the week, whichever days you drink. "
                          "Log how much in your check-in.",
                          f"more than {units} units of alcohol for the week", weekly_units=float(units))
      for units in WEEKLY_UNIT_BUDGETS),
    ExperimentBehaviour("no_screens_in_bed", "screen_in_bed", "No screens in bed",
                        "Change week: no screens in bed", "No screens in bed",
                        "Keep your phone, tablet and laptop out of bed every night.", "screens in bed"),
)
TESTABLE_BY_INPUT = {
    input_id: [item for item in TESTABLE_BEHAVIOURS if item.input_id == input_id]
    for input_id in dict.fromkeys(item.input_id for item in TESTABLE_BEHAVIOURS)
}
TESTABLE_BY_ID = {item.id: item for item in TESTABLE_BEHAVIOURS}
USUAL_NOUNS = dict(alcohol="alcohol", caffeine="caffeine", screen_in_bed="screens in bed")


class ExperimentError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def input_of(pair_id):
    return pair_id.split(":", 1)[0]


def finding_testable(finding):
    return (finding["state"] in FINDING_STATES and finding["stratum"] == "all"
            and input_of(finding["pair_id"]) in TESTABLE_BY_INPUT)


def mark_testable(presented):
    for story in presented["stories"]:
        for finding in story["findings"]:
            finding["testable"] = finding_testable(finding)
        story["testable"] = any(finding["testable"] for finding in story["findings"])
    return presented


def kind_on(experiment, day):
    offset = (day - experiment.start_date).days
    if offset < 0 or offset >= EXPERIMENT_DAYS:
        return None
    block = offset // BLOCK_DAYS
    return dict(
        date=day, day_number=offset + 1, week=block + 1,
        kind="change" if block % 2 == 0 else "usual",
        washout=offset % BLOCK_DAYS < WASHOUT_DAYS,
    )


def schedule(experiment):
    return [kind_on(experiment, experiment.start_date + timedelta(days=offset)) for offset in range(EXPERIMENT_DAYS)]


def plan_text(experiment, kind):
    return TESTABLE_BY_ID[experiment.behaviour_id].change_text if kind == "change" else USUAL_TEXT


def clock(value):
    if not isinstance(value, str) or ":" not in value:
        return None
    try:
        hour, minute = (int(part) for part in value.split(":")[:2])
        return time(hour, minute)
    except ValueError:
        return None


def followed_change(behaviour, answer):
    if answer is None or answer.value is None:
        return None
    if not answer.value:
        return True
    if behaviour.latest_use is None:
        return False
    last_use = clock(detail_value(answer, "last_use"))
    return None if last_use is None else last_use < behaviour.latest_use


def minutes_of(moment):
    return moment.hour * 60 + moment.minute


def clock_text(minutes):
    rounded = int(round(minutes / 30) * 30) % (24 * 60)
    hour, minute = divmod(rounded, 60)
    suffix = "am" if hour < 12 else "pm"
    shown = hour % 12 or 12
    if hour == 12 and minute == 0:
        return "noon"
    return f"{shown}{suffix}" if minute == 0 else f"{shown}:{minute:02d}{suffix}"


def per_week_text(used, logged, unit):
    if used == 0:
        return f"on none of the {logged} {unit}s you logged"
    rate = used / logged * 7
    if rate < 1:
        return f"less than 1 {unit} a week"
    count = round(rate)
    return f"about {count} {unit}{'' if count == 1 else 's'} a week"


def usual_for(session, user_id, input_id, today):
    first = today - timedelta(days=USUAL_WINDOW_DAYS)
    data = load_user_data(session, user_id, first, today - timedelta(days=1))
    answers = [answer for (day, key), answer in data.answers.items()
               if key == input_id and answer.value is not None and first <= day < today]
    used = [answer for answer in answers if answer.value]
    usual = dict(logged_days=len(answers), used_days=len(used), typical_units=None, weekly_units=None,
                 typical_last_use=None)
    noun = USUAL_NOUNS[input_id]
    if not answers:
        usual["lines"] = [f"You haven’t logged {noun} in the last 4 weeks, so there’s no usual to show yet."]
        usual["basis"] = None
        return usual
    usual["basis"] = f"Based on the {len(answers)} days you logged in the last 4 weeks."
    if input_id == "alcohol":
        lines = [f"You drank {per_week_text(len(used), len(answers), 'day')}."]
        units = [value for value in (dose_value("alcohol", answer, "amount") for answer in used) if value]
        if units:
            usual["typical_units"] = mean(units)
            usual["weekly_units"] = usual["typical_units"] * len(used) / len(answers) * 7
            lines.append(f"Averaging around {max(round(usual['weekly_units']), 1)} units per week in total.")
    elif input_id == "caffeine":
        lines = [f"You had caffeine {per_week_text(len(used), len(answers), 'day')}."]
        times = [minutes_of(moment) for moment in (clock(detail_value(answer, "last_use")) for answer in used)
                 if moment is not None]
        if times:
            usual["typical_last_use"] = median(times)
            lines.append(f"Your last caffeine was usually around {clock_text(usual['typical_last_use'])}.")
    else:
        lines = [f"You used screens in bed {per_week_text(len(used), len(answers), 'night')}."]
    usual["lines"] = lines
    return usual


def option_available(behaviour, usual):
    if behaviour.weekly_units is not None:
        return usual["weekly_units"] is not None and usual["weekly_units"] > behaviour.weekly_units
    if behaviour.latest_use is not None:
        return usual["typical_last_use"] is not None and usual["typical_last_use"] > minutes_of(behaviour.latest_use)
    return True


def options_for(input_id, usual):
    available = [behaviour for behaviour in TESTABLE_BY_INPUT[input_id] if option_available(behaviour, usual)]
    budgets = [behaviour for behaviour in available if behaviour.weekly_units is not None][-2:]
    return [behaviour for behaviour in available if behaviour.weekly_units is None or behaviour in budgets]


def followed_by_day(behaviour, experiment, data, last):
    followed = {}
    total = 0.0
    for item in schedule(experiment):
        day = item["date"]
        if day > last:
            break
        if item["kind"] != "change":
            continue
        if (item["day_number"] - 1) % BLOCK_DAYS == 0:
            total = 0.0
        answer = data.answers.get((day, behaviour.input_id))
        if behaviour.weekly_units is None or answer is None or not answer.value:
            followed[day] = followed_change(behaviour, answer)
            continue
        units = dose_value("alcohol", answer, "amount")
        if units is None:
            followed[day] = None
            continue
        total += units
        followed[day] = total <= behaviour.weekly_units
    return followed


def setup_for(session, user_id, finding, today):
    if not finding_testable(finding):
        raise ExperimentError("not_testable")
    input_id = input_of(finding["pair_id"])
    usual = usual_for(session, user_id, input_id, today)
    start = today + timedelta(days=1)
    end = start + timedelta(days=EXPERIMENT_DAYS - 1)
    return dict(
        pair_id=finding["pair_id"], stratum=finding["stratum"], input_id=input_id,
        outcome_label=OUTCOME_SUBJECTS[finding["outcome_id"]], usual=usual,
        options=[dict(id=item.id, title=item.option_title, change_text=item.change_text, detail=item.detail)
                 for item in options_for(input_id, usual)],
        start_date=start, end_date=end, result_date=end + timedelta(days=RESULT_DELAY_DAYS),
        weeks=EXPERIMENT_DAYS // BLOCK_DAYS, washout_days=WASHOUT_DAYS, safety_note=note_for(input_id),
    )


def first_slip(session, experiment, today):
    last = min(experiment.end_date, today)
    if last < experiment.start_date:
        return None
    behaviour = TESTABLE_BY_ID[experiment.behaviour_id]
    data = load_user_data(session, experiment.user_id, experiment.start_date, last)
    followed = followed_by_day(behaviour, experiment, data, last)
    return next((day for day, kept in followed.items() if kept is False), None)


def latest_experiment(session, user_id):
    return session.scalar(select(BehaviourExperiment).where(
        BehaviourExperiment.user_id == user_id,
    ).order_by(BehaviourExperiment.started_at.desc()).limit(1))


def active_experiment(session, user_id, today):
    experiment = latest_experiment(session, user_id)
    if experiment is None or experiment.status != "active":
        return experiment
    if first_slip(session, experiment, today) is not None:
        experiment.status = "off_track"
        experiment.stopped_at = utcnow()
        session.commit()
        logger.info("Behaviour experiment off track experiment=%s", experiment.id)
        return experiment
    if today >= experiment.end_date + timedelta(days=RESULT_DELAY_DAYS):
        experiment.status = "completed"
        experiment.completed_at = utcnow()
        session.commit()
        logger.info("Behaviour experiment completed experiment=%s", experiment.id)
    return experiment


def start_experiment(session, user_id, finding, today, behaviour_id=None, restart=False):
    if not finding_testable(finding):
        raise ExperimentError("not_testable")
    current = active_experiment(session, user_id, today)
    if current is not None and current.status == "active":
        raise ExperimentError("experiment_active")
    input_id = input_of(finding["pair_id"])
    choices = TESTABLE_BY_INPUT[input_id]
    if behaviour_id is not None and not restart:
        choices = options_for(input_id, usual_for(session, user_id, input_id, today))
    behaviour = next((item for item in choices if behaviour_id in (None, item.id)), None)
    if behaviour is None:
        raise ExperimentError("change_not_available")
    start = today + timedelta(days=1)
    experiment = BehaviourExperiment(
        user_id=user_id, behaviour_id=behaviour.id, input_id=behaviour.input_id, pair_id=finding["pair_id"],
        outcome_id=finding["outcome_id"], stratum=finding["stratum"], status="active",
        start_date=start, end_date=start + timedelta(days=EXPERIMENT_DAYS - 1),
    )
    session.add(experiment)
    session.commit()
    logger.info("Behaviour experiment started experiment=%s behaviour=%s", experiment.id, behaviour.id)
    return experiment


def restartable(session, user_id, today):
    experiment = active_experiment(session, user_id, today)
    if experiment is None or experiment.status != "off_track":
        raise ExperimentError("nothing_to_restart")
    return experiment


def stop_experiment(session, user_id, today):
    experiment = active_experiment(session, user_id, today)
    if experiment is None or experiment.status != "active":
        raise ExperimentError("no_active_experiment")
    experiment.status = "stopped"
    experiment.stopped_at = utcnow()
    session.commit()
    logger.info("Behaviour experiment stopped experiment=%s", experiment.id)
    return experiment


def pair_for(experiment):
    return next(pair for pair in BEHAVIOUR_MAP_V1.pairs if pair.id == experiment.pair_id)


def last_counted_day(experiment, today):
    if experiment.status in ("stopped", "off_track") and experiment.stopped_at is not None:
        return min(experiment.end_date, experiment.stopped_at.date() - timedelta(days=1), today - timedelta(days=1))
    return min(experiment.end_date, today - timedelta(days=1))


def collect(session, experiment, today):
    behaviour = TESTABLE_BY_ID[experiment.behaviour_id]
    pair = pair_for(experiment)
    last = last_counted_day(experiment, today)
    values = dict(change=[], usual=[])
    adherence = dict(change_days=0, logged_days=0, followed_days=0)
    if last < experiment.start_date:
        return values, adherence
    data = load_user_data(session, experiment.user_id, experiment.start_date, last)
    sick = sick_days(data, BEHAVIOUR_MAP_V1)
    followed_days = followed_by_day(behaviour, experiment, data, last)
    for item in schedule(experiment):
        day = item["date"]
        if day > last:
            break
        answer = data.answers.get((day, behaviour.input_id))
        if item["kind"] == "change":
            adherence["change_days"] += 1
            followed = followed_days.get(day)
            adherence["logged_days"] += followed is not None
            adherence["followed_days"] += bool(followed)
        if item["washout"] or day in sick:
            continue
        outcome = outcome_for(data, pair, day, pair.lag_days, answer.recorded_at if answer else None)
        if outcome is not None:
            values[item["kind"]].append(outcome)
    return values, adherence


def adherence_text(adherence):
    if adherence["change_days"] == 0:
        return None
    return f"You logged sticking to the change on {adherence['followed_days']} of the " \
           f"{adherence['change_days']} days in change weeks."


def result_for(experiment, values, adherence):
    outcome_id = experiment.outcome_id
    noun = OUTCOME_NOUNS[outcome_id]
    unit = UNIT_TEXT.get(BEHAVIOUR_MAP_V1.outcome(outcome_id).unit, "")
    notes = [*filter(None, [note_for(experiment.input_id)]), ONE_PERSON_TEXT,
             f"The first {WASHOUT_DAYS} days of each week, sick days and days without {noun} data were left out."]
    if adherence["followed_days"] < adherence["change_days"]:
        notes.append("Days in change weeks where sticking to the change was not logged still counted towards "
                     "change weeks, which can make any difference look smaller.")
    counts = dict(change_days=len(values["change"]), usual_days=len(values["usual"]))
    if min(counts.values()) < MIN_VALID_DAYS:
        return dict(
            status="too_few_days", **counts, minimum_days=MIN_VALID_DAYS, difference=None, unit=unit,
            benefit=None,
            summary=f"Not enough days to compare: {counts['change_days']} days in change weeks and "
                    f"{counts['usual_days']} in usual weeks had {noun} data, and at least {MIN_VALID_DAYS} of each "
                    f"are needed.",
            adherence_text=adherence_text(adherence), notes=notes,
        )
    difference = mean(values["change"]) - mean(values["usual"])
    band = NEUTRAL_BANDS[outcome_id]
    subject = OUTCOME_SUBJECTS[outcome_id]
    if abs(difference) <= band:
        benefit = "none"
        summary = f"{subject} differed by less than {number(band)} {unit} between change weeks and usual weeks, " \
                  f"so no clear difference was seen."
    else:
        benefit = "helps" if difference * BETTER_DIRECTION.get(outcome_id, 0) > 0 else "hurts"
        summary = f"{subject} was about {number(difference)} {unit} " \
                  f"{direction_word(outcome_id, difference)} in change weeks than in usual weeks."
    return dict(
        status="ready", **counts, minimum_days=MIN_VALID_DAYS, difference=difference, unit=unit,
        benefit=benefit, summary=summary, adherence_text=adherence_text(adherence), notes=notes,
    )


def off_track_for(session, experiment, today):
    if experiment.status != "off_track":
        return None
    behaviour = TESTABLE_BY_ID[experiment.behaviour_id]
    slip = first_slip(session, experiment, today)
    when = f"On {slip.strftime('%A')} {slip.day} {slip.strftime('%B')}, in a change week" if slip \
        else "In a change week"
    return dict(
        date=slip,
        summary=f"{when}, you logged {behaviour.slip}, so this experiment has ended.",
        restart_text="You can restart it from tomorrow with the same change, or pick a different change "
                     "from the pattern.",
    )


def describe(session, experiment, today):
    if experiment is None:
        return None
    behaviour = TESTABLE_BY_ID[experiment.behaviour_id]
    days = [dict(item, plan=plan_text(experiment, item["kind"])) for item in schedule(experiment)]
    today_plan = kind_on(experiment, today) if experiment.status == "active" else None
    values, adherence = collect(session, experiment, today)
    ended = experiment.status in ("completed", "stopped")
    return dict(
        id=experiment.id, behaviour_id=behaviour.id, input_id=experiment.input_id, pair_id=experiment.pair_id,
        stratum=experiment.stratum, outcome_id=experiment.outcome_id,
        outcome_label=OUTCOME_SUBJECTS[experiment.outcome_id], title=behaviour.title,
        change_text=behaviour.change_text, usual_text=USUAL_TEXT, status=experiment.status,
        start_date=experiment.start_date, end_date=experiment.end_date,
        result_date=experiment.end_date + timedelta(days=RESULT_DELAY_DAYS),
        started_at=experiment.started_at, stopped_at=experiment.stopped_at, completed_at=experiment.completed_at,
        today=dict(today_plan, plan=plan_text(experiment, today_plan["kind"])) if today_plan else None,
        days=days, adherence=adherence, off_track=off_track_for(session, experiment, today),
        result=result_for(experiment, values, adherence) if ended else None,
    )
