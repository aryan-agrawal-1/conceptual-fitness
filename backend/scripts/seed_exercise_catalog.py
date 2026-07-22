from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
from urllib.request import urlopen

from sqlalchemy import select

from app.db.session import SessionLocal
from app.models import ExerciseCatalogItem


SOURCE_VERSION = "b0eed061e1c832b3ed815fbaa4b45b3cdc14df49"
SOURCE_URL = (
    "https://raw.githubusercontent.com/yuhonas/free-exercise-db/"
    f"{SOURCE_VERSION}/dist/exercises.json"
)
IMAGE_BASE_URL = (
    "https://raw.githubusercontent.com/yuhonas/free-exercise-db/"
    f"{SOURCE_VERSION}/exercises/"
)

POPULAR_NAMES = [
    "Barbell Bench Press - Medium Grip",
    "Barbell Squat",
    "Barbell Deadlift",
    "Dumbbell Bench Press",
    "Dumbbell Bicep Curl",
    "Dumbbell Shoulder Press",
    "Bent Over Barbell Row",
    "Chin-Up",
    "Wide-Grip Lat Pulldown",
    "Leg Press",
    "Leg Extensions",
    "Lying Leg Curls",
    "Romanian Deadlift",
    "Barbell Hip Thrust",
    "Seated Cable Rows",
    "Side Lateral Raise",
    "Cable Crossover",
    "Triceps Pushdown",
    "Standing Calf Raises",
    "Crunches",
    "Plank",
    "Dips - Chest Version",
    "Pushups",
    "Pullups",
    "Front Barbell Squat",
    "Incline Dumbbell Press",
    "Incline Dumbbell Curl",
    "Hammer Curls",
    "One-Arm Dumbbell Row",
    "Face Pull",
    "Arnold Dumbbell Press",
    "Goblet Squat",
    "Split Squat with Dumbbells",
    "Walking Lunge",
    "Sumo Deadlift",
    "Trap Bar Deadlift",
    "T-Bar Row with Handle",
    "Close-Grip Barbell Bench Press",
    "EZ-Bar Curl",
    "Skull Crusher",
    "Cable Hammer Curls - Rope Attachment",
    "Seated Leg Curl",
    "Hack Squat",
    "Calf Press On The Leg Press Machine",
    "Machine Bench Press",
    "Machine Shoulder (Military) Press",
    "Machine Bicep Curl",
    "Dip Machine",
    "Bodyweight Squat",
    "Inverted Row",
    "Bench Dips",
    "Mountain Climbers",
    "Burpees",
    "Russian Twist",
    "Hanging Leg Raise",
    "Ab Roller",
    "Kettlebell Swing",
    "Kettlebell Goblet Squat",
    "Turkish Get-Up",
    "Clean and Press",
    "Power Clean",
    "Hang Clean",
    "Barbell Incline Bench Press - Medium Grip",
    "Decline Dumbbell Bench Press",
    "Dumbbell Flyes",
    "Cable Seated Lateral Raise",
    "Rear Delt Fly",
    "Straight-Arm Pulldown",
    "Close-Grip Front Lat Pulldown",
    "Hyperextensions (Back Extensions)",
    "Good Morning",
    "Stiff-Legged Dumbbell Deadlift",
    "Step-up with Knee Raise",
    "Single-Leg Press",
    "Standing Leg Curl",
    "Glute Bridge",
    "Cable Kickback",
    "Thigh Abductor",
    "Thigh Adductor",
    "Seated Calf Raise",
    "Donkey Calf Raises",
    "Preacher Curl",
    "Concentration Curls",
    "Reverse Barbell Curl",
    "Overhead Triceps",
    "Dumbbell One-Arm Triceps Extension",
    "Cable Rope Overhead Triceps Extension",
    "Pallof Press",
    "Side Plank",
    "Bicycle Crunches",
    "Cable Crunch",
    "Farmer's Walk",
    "Prowler Sprint",
    "Battle Ropes",
    "Box Jump (Multiple Response)",
    "Jumping Rope",
    "Running, Treadmill",
    "Walking, Treadmill",
    "Bicycling, Stationary",
    "Rowing, Stationary",
    "Elliptical Trainer",
    "Stairmaster",
]

COMMON_TERMS = (
    "press",
    "squat",
    "deadlift",
    "row",
    "pulldown",
    "pull-up",
    "chin-up",
    "curl",
    "extension",
    "raise",
    "lunge",
    "fly",
    "push-up",
    "dip",
    "plank",
    "crunch",
    "calf",
    "bridge",
    "carry",
    "walk",
    "running",
    "cycling",
    "rowing",
)

VARIANT_PENALTIES = (
    "with chains",
    "with bands",
    "reverse band",
    "behind the neck",
    "guillotine",
    "one arm",
    "one-arm",
    "single-arm",
    "single-leg",
    "from deficit",
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    exercises = _load_exercises(args.source)
    curated_ids = _curated_ids(exercises, count=175)

    with SessionLocal() as session:
        existing = {
            item.external_id: item
            for item in session.scalars(
                select(ExerciseCatalogItem).where(ExerciseCatalogItem.source == "free-exercise-db")
            ).all()
        }
        for raw in exercises:
            external_id = str(raw["id"])
            item = existing.get(external_id) or ExerciseCatalogItem(
                source="free-exercise-db",
                external_id=external_id,
            )
            _apply_record(item, raw, curated=external_id in curated_ids)
            session.add(item)
        session.commit()
    print(f"Seeded {len(exercises)} exercises ({len(curated_ids)} curated).")


def _load_exercises(path: Path | None) -> list[dict[str, Any]]:
    if path is not None:
        return json.loads(path.read_text())
    with urlopen(SOURCE_URL, timeout=30) as response:
        return json.load(response)


def _curated_ids(exercises: list[dict[str, Any]], *, count: int) -> set[str]:
    popular_rank = {name.lower(): index for index, name in enumerate(POPULAR_NAMES)}

    def score(item: dict[str, Any]) -> tuple[float, str]:
        name = str(item.get("name") or "")
        value = name.lower()
        rank = popular_rank.get(value)
        points = 2000 - (rank or 0) if rank is not None else 0
        points += sum(35 for term in COMMON_TERMS if term in value)
        points -= sum(30 for term in VARIANT_PENALTIES if term in value)
        if item.get("level") == "beginner":
            points += 15
        if item.get("category") == "strength":
            points += 20
        if item.get("equipment") in {"body only", "barbell", "dumbbell", "cable", "machine"}:
            points += 10
        return points, name

    ranked = sorted(exercises, key=score, reverse=True)
    return {str(item["id"]) for item in ranked[:count]}


def _apply_record(
    item: ExerciseCatalogItem,
    raw: dict[str, Any],
    *,
    curated: bool,
) -> None:
    item.source_version = SOURCE_VERSION
    item.name = str(raw.get("name") or raw["id"])
    item.aliases = _aliases(item.name)
    item.instructions = [str(value) for value in raw.get("instructions") or []]
    item.media = [
        {
            "role": "start_pose" if index == 0 else "end_pose",
            "type": "image",
            "url": f"{IMAGE_BASE_URL}{path}",
            "source": "free-exercise-db",
        }
        for index, path in enumerate(raw.get("images") or [])
    ]
    item.force = raw.get("force")
    item.level = raw.get("level")
    item.mechanic = raw.get("mechanic")
    item.equipment = raw.get("equipment")
    item.category = raw.get("category")
    item.movement_pattern = _movement_pattern(item.name)
    item.primary_muscles = raw.get("primaryMuscles") or []
    item.secondary_muscles = raw.get("secondaryMuscles") or []
    item.measurement_schema = _measurement_schema(raw)
    item.default_rest_seconds = _default_rest_seconds(raw)
    item.is_curated = curated
    item.is_archived = False


def _measurement_schema(raw: dict[str, Any]) -> str:
    name = str(raw.get("name") or "").lower()
    if raw.get("category") == "cardio":
        return "cardio"
    if any(term in name for term in ("farmer", "carry", "walk")) and raw.get("category") != "stretching":
        return "carry"
    if any(term in name for term in ("plank", "wall sit", "isometric", "hold")):
        return "duration"
    if "assisted" in name:
        return "assisted_reps"
    if raw.get("equipment") == "body only":
        return "bodyweight_reps"
    return "reps_load"


def _default_rest_seconds(raw: dict[str, Any]) -> int | None:
    if raw.get("category") in {"cardio", "stretching"}:
        return None
    if raw.get("mechanic") == "compound":
        return 150
    return 75


def _movement_pattern(name: str) -> str | None:
    value = name.lower()
    patterns = (
        ("squat", ("squat", "leg press")),
        ("hinge", ("deadlift", "good morning", "hip thrust", "bridge")),
        ("lunge", ("lunge", "split squat", "step-up")),
        ("horizontal_push", ("bench press", "push-up", "fly")),
        ("vertical_push", ("shoulder press", "military press", "overhead press")),
        ("horizontal_pull", ("row",)),
        ("vertical_pull", ("pull-up", "chin-up", "pulldown")),
        ("carry", ("carry", "farmer", "walk")),
        ("core", ("plank", "crunch", "sit-up", "twist")),
    )
    for pattern, terms in patterns:
        if any(term in value for term in terms):
            return pattern
    return "isolation"


def _aliases(name: str) -> list[str]:
    aliases: list[str] = []
    replacements = {
        "Barbell Bench Press - Medium Grip": ["Bench Press", "Barbell Bench Press"],
        "Barbell Full Squat": ["Back Squat", "Barbell Back Squat"],
        "Barbell Squat": ["Back Squat", "Barbell Back Squat"],
        "Side Lateral Raise": ["Dumbbell Lateral Raise", "Lateral Raise"],
        "Cable Crossover": ["Cable Fly", "Standing Cable Chest Fly"],
        "Bent Over Barbell Row": ["Barbell Row"],
        "Wide-Grip Lat Pulldown": ["Lat Pulldown"],
        "Lying Leg Curls": ["Lying Leg Curl"],
        "Leg Extensions": ["Leg Extension"],
    }
    aliases.extend(replacements.get(name, []))
    return aliases


if __name__ == "__main__":
    main()
