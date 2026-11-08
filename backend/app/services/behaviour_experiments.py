from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, time, timedelta
from statistics import mean

from sqlalchemy import select

from app.core.security import utcnow
from app.models import BehaviourExperiment
from app.services.behaviour_map import BEHAVIOUR_MAP_V1
from app.services.behaviour_presentation import (
    BETTER_DIRECTION, FINDING_STATES, NEUTRAL_BANDS, OUTCOME_NOUNS, OUTCOME_SUBJECTS, UNIT_TEXT, direction_word,
    number,
)
from app.services.behaviour_safety import note_for
from app.services.behaviour_series import detail_value, load_user_data, outcome_for, sick_days


logger = logging.getLogger(__name__)

EXPERIMENT_DAYS = 28
BLOCK_DAYS = 7
WASHOUT_DAYS = 2
MIN_VALID_DAYS = 6
RESULT_DELAY_DAYS = 2
USUAL_TEXT = "Usual day: do what you normally do"
ONE_PERSON_TEXT = "This is one person's result over a short period. It is not proof that the change caused " \
                  "the difference, and other things in your life may have changed too."


@dataclass(frozen=True)
class ExperimentBehaviour:
    id: str
    input_id: str
    title: str
    change_text: str
    latest_use: time | None = None


TESTABLE_BEHAVIOURS = (
    ExperimentBehaviour("caffeine_before_2pm", "caffeine", "No caffeine after 2pm",
                      "Experiment day: no caffeine after 2pm", latest_use=time(14)),
    ExperimentBehaviour("alcohol_free", "alcohol", "Alcohol-free days", "Experiment day: no alcohol"),
    ExperimentBehaviour("no_screens_in_bed", "screen_in_bed", "No screens in bed",
                      "Experiment day: no screens in bed"),
)
TESTABLE_BY_INPUT = {item.input_id: item for item in TESTABLE_BEHAVIOURS}
TESTABLE_BY_ID = {item.id: item for item in TESTABLE_BEHAVIOURS}


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
    return last_use is not None and last_use < behaviour.latest_use


def latest_experiment(session, user_id):
    return session.scalar(select(BehaviourExperiment).where(
        BehaviourExperiment.user_id == user_id,
    ).order_by(BehaviourExperiment.started_at.desc()).limit(1))


def active_experiment(session, user_id, today):
    experiment = latest_experiment(session, user_id)
    if experiment is None or experiment.status != "active":
        return experiment
    if today >= experiment.end_date + timedelta(days=RESULT_DELAY_DAYS):
        experiment.status = "completed"
        experiment.completed_at = utcnow()
        session.commit()
        logger.info("Behaviour experiment completed experiment=%s", experiment.id)
    return experiment


def start_experiment(session, user_id, finding, today):
    if not finding_testable(finding):
        raise ExperimentError("not_testable")
    current = active_experiment(session, user_id, today)
    if current is not None and current.status == "active":
        raise ExperimentError("experiment_active")
    behaviour = TESTABLE_BY_INPUT[input_of(finding["pair_id"])]
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
    if experiment.status == "stopped" and experiment.stopped_at is not None:
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
    for item in schedule(experiment):
        day = item["date"]
        if day > last:
            break
        answer = data.answers.get((day, behaviour.input_id))
        if item["kind"] == "change":
            adherence["change_days"] += 1
            followed = followed_change(behaviour, answer)
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
    return f"You logged doing the change on {adherence['followed_days']} of {adherence['change_days']} " \
           f"change days."


def result_for(experiment, values, adherence):
    outcome_id = experiment.outcome_id
    noun = OUTCOME_NOUNS[outcome_id]
    unit = UNIT_TEXT.get(BEHAVIOUR_MAP_V1.outcome(outcome_id).unit, "")
    notes = [*filter(None, [note_for(experiment.input_id)]), ONE_PERSON_TEXT,
             f"The first {WASHOUT_DAYS} days of each week, sick days and days without {noun} data were left out."]
    if adherence["followed_days"] < adherence["change_days"]:
        notes.append("Change days where the change was not logged were still counted as change days, "
                     "which can make any difference look smaller.")
    counts = dict(change_days=len(values["change"]), usual_days=len(values["usual"]))
    if min(counts.values()) < MIN_VALID_DAYS:
        return dict(
            status="too_few_days", **counts, minimum_days=MIN_VALID_DAYS, difference=None, unit=unit,
            benefit=None,
            summary=f"Not enough days to compare: {counts['change_days']} change days and "
                    f"{counts['usual_days']} usual days had {noun} data, and at least {MIN_VALID_DAYS} of each "
                    f"are needed.",
            adherence_text=adherence_text(adherence), notes=notes,
        )
    difference = mean(values["change"]) - mean(values["usual"])
    band = NEUTRAL_BANDS[outcome_id]
    subject = OUTCOME_SUBJECTS[outcome_id]
    if abs(difference) <= band:
        benefit = "none"
        summary = f"{subject} differed by less than {number(band)} {unit} between change days and usual days, " \
                  f"so no clear difference was seen."
    else:
        benefit = "helps" if difference * BETTER_DIRECTION.get(outcome_id, 0) > 0 else "hurts"
        summary = f"{subject} was about {number(difference)} {unit} " \
                  f"{direction_word(outcome_id, difference)} on change days than on usual days."
    return dict(
        status="ready", **counts, minimum_days=MIN_VALID_DAYS, difference=difference, unit=unit,
        benefit=benefit, summary=summary, adherence_text=adherence_text(adherence), notes=notes,
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
        days=days, adherence=adherence,
        result=result_for(experiment, values, adherence) if ended else None,
    )
