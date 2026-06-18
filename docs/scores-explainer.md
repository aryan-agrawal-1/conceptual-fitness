# Scores, Baselines, and Reasons

Here we explain how the app turns the given API data into our own daily Sleep, Strain, and Readiness scores. The aim is to make the scoring logic readable in plain English, while also pointing back to the functions in `backend/app/services/scores.py` and the research notes I wrote in `research/`. If you want to understand the individual scores better, please read the short papers.

## Research Basis

The three local research files map directly to the three scores: In

- In`research/Sleep Scores.pdf` I argue that sleep scoring should rely most heavily on duration, regularity, and continuity, since wearables are stronger at broad sleep-wake patterns than determining the exact stages. I recommended weighting sleep roughly as duration 35%, regularity 25%, continuity 20%, timing 10%, overnight physiology 5%, and stages 5%.
- In`research/Strain Scores.pdf` I show why strain should be accumulated load points, rather than a bounded 0-100 quality score. It points toward heart-rate-reserve based cardio load, duration, daily activity, muscular load, and eventually subjective effort. I also recommend separating raw daily strain from weekly target interpretation.
- In`research/Readiness Scores.pdf` I argue that readiness should be personalised, baseline-driven, and based on the combination of sleep, autonomic recovery, recent load, and illness-like anomaly signals. I recommend weights around sleep adequacy/debt 30%, autonomic recovery 30%, recent load fit 25%, illness/anomaly/context 10%, and confidence 5%.

Those recommendations are implemented in `scores.py` through `_upsert_sleep_score`, `_upsert_strain_score`, `_upsert_readiness_score`, and the helper functions described below.

## How Scores Are Rebuilt

The rebuild entry point is `rebuild_derived_scores`.

For each day in the requested range, it will:

1. Detect automatic timezone-shift context using `_detect_timezone_shift_context`.
2. Rebuilds daily baselines using `rebuild_daily_baselines`.
3. Writes the Sleep score with `_upsert_sleep_score`.
4. Writes the Strain score with `_upsert_strain_score`.
5. Writes the Readiness score with `_upsert_readiness_score`.
6. Rebuilds weekly strain targets with `_upsert_strain_target`.

This order matters. Baselines are available before the scores are calculated, and Readiness can use prior Strain scores when it decides whether recent load was normal for the person.

## Sleep Score

Function: `_upsert_sleep_score`

The Sleep score is a 0-100 score. It only calculates when the app can find a main sleep session ending on that date. If there is no usable main sleep session, the score is marked as waiting with reason `waiting_for_main_sleep`.

The score follows the structure recommended in `research/Sleep Scores.pdf`: duration and regularity carry most of the score, continuity is also important, and physiology plus stages are treated as smaller supporting signals because wearable physiology and stage detection are noisier than timing and duration.

The current weights are:


| Component  | Weight | Function                  |
| ---------- | ------ | ------------------------- |
| Duration   | 35%    | `_duration_score`         |
| Regularity | 25%    | `_regularity_score`       |
| Continuity | 20%    | `_continuity_score`       |
| Timing     | 10%    | `_timing_score`           |
| Physiology | 5%     | `_sleep_physiology_score` |
| Stages     | 5%     | `_stage_score`            |


The final number is produced by `_weighted_score`. Missing optional components do not zero the score. Instead, `_weighted_score` averages over the components that are actually present. This is important for sleep because stage data or physiology may be missing, but duration and timing can still produce a meaningful score.

### Sleep Duration

Function: `_duration_score`

Duration compares minutes asleep against the user's adjusted sleep need. The target is clamped between 7 and 9 hours, because the research uses that range as the practical adult target range. The adjusted target comes from `_adjusted_sleep_need_minutes`.

`_adjusted_sleep_need_minutes` starts with the user's profile sleep target, or 480 minutes if no profile target exists. It clamps that base target between 420 and 540 minutes. If yesterday's Strain was more than 1.5 times the user's Strain baseline, the app adds 30 minutes of sleep need, capped at 570 minutes.

Why: `research/Sleep Scores.pdf` and `research/Readiness Scores.pdf` both argue that sleep need should respond to recent load. A harder-than-normal day should make the app expect a little more sleep before calling the night fully adequate.

The duration score works like this:

- If the user sleeps between 94% and 112% of target, duration gets 100.
- If sleep is short, the score falls steeply. This reflects the research point that short sleep should not be rescued by nice-looking stage data.
- If sleep is longer than target, the score falls gently but bottoms at 70. Oversleeping can be a signal, but it is not treated as harshly as undersleeping.

Why: `research/Sleep Scores.pdf` puts duration first because wearables are relatively reliable for total sleep time and because a short night remains a short night even if other metrics look okay.

### Sleep Regularity

Function: `_regularity_score`

Regularity compares the sleep start and end time against the person's own sleep timing baseline. It uses:

- `sleep_start_minute` baseline
- `sleep_end_minute` baseline
- circular minute difference, so times around midnight compare correctly

If there is not enough baseline data yet, the component returns a neutral-ish 75 rather than pretending to know the user's pattern. Once there is enough data, the score stays high for small drift and starts penalising drift beyond about 30 minutes. A very late start between 2:00am and 5:00am receives an additional penalty.

Why: `research/Sleep Scores.pdf` explicitly says sleep regularity should be a major component, not a tiny bonus, because irregular schedules are linked with worse long-term outcomes and because timing consistency is actionable.

### Sleep Continuity

Function: `_continuity_score`

Continuity measures whether sleep was a continuous block or a broken night. It combines:

- Sleep efficiency: minutes asleep divided by the time spent in the sleep period.
- Awake minutes: a penalty if awake time rises above 20 minutes.

The component is 72% efficiency score and 28% awake-minutes score.

Why: `research/Sleep Scores.pdf` treats awakenings, restlessness, and sleep efficiency as meaningful but slightly less important than duration and regularity. The implementation follows that hierarchy.

### Sleep Timing

Function: `_timing_score`

Timing looks only at sleep start drift versus the user's usual sleep start baseline. It is related to regularity, but narrower. If baseline data is not ready, it returns 82. Once baseline data exists, it penalises drift after about 45 minutes and also penalises very late sleep starts between 2:00am and 5:00am.

Why: the sleep research separates "when did the user sleep?" from "how much did they sleep?" because timing reflects circadian stability.

### Sleep Physiology

Function: `_sleep_physiology_score`

Physiology is a small supporting component. It averages whichever of these are available:

- HRV against baseline, where higher is better.
- Resting heart rate against baseline, where lower is better.
- Respiratory rate against baseline, where lower is better.
- Oxygen saturation using `_spo2_score`.

The baseline-based metrics use `_metric_baseline_score`. If no personal baseline exists yet, the metric returns 75 rather than being treated as good or bad.

When a baseline exists, `_metric_baseline_score` compares the value against the user's median and robust spread. It starts from 80, then moves up or down by 12 points for each spread-unit of change. For HRV, being above baseline helps. For resting heart rate and respiratory rate, being below baseline helps. This makes the metric personal without making every tiny difference feel dramatic.

Why: `research/Sleep Scores.pdf` says overnight physiology can explain why sleep may have been poor, but it should not define sleep quality. Those signals are more central to Readiness than Sleep.

### Sleep Stages

Function: `_stage_score`

Stages are optional and lightly weighted. The function reads REM and deep sleep from the stage summary, then scores:

- REM percent as best between 15% and 30%.
- Deep percent as best between 10% and 25%.

Both are scored with `_range_score`, then averaged.

Why: the sleep research is cautious about consumer sleep stages. Stages can be useful supporting evidence, but wearable stage detection is less secure than duration, timing, and continuity.

### Sleep Confidence and Quality

Sleep's `confidence_phase` is the weakest phase among the relevant sleep baselines:

- `sleep_minutes`
- `sleep_start_minute`
- `sleep_efficiency`

That is handled through `_baseline_phase` and `_combined_phase`.

The `data_quality` field comes from `_quality_for_components`, which counts how many components had usable scores. More usable components means stronger quality.

## Strain Score

Function: `_upsert_strain_score`

Strain is not a 0-100 score. It is accumulated `load_points`. This follows `research/Strain Scores.pdf`, which argues that strain is a dose of work, not a quality rating. There is no natural maximum where 100 means "complete"; going above a target can be meaningful and should remain visible.

The Strain score is built from:

- Cardio load from heart-rate reserve.
- Provider zone load as a fallback when raw heart-rate coverage is weak.
- Daily activity load from steps or active calories.
- Muscular load for strength-like workouts.
- RPE load, currently present as a placeholder but not implemented.

If there is no heart-rate, workout, or activity data, Strain is marked as waiting or missing. For today it is `in_progress`; for past days it is `missing_data`.

### Cardio Load

Function: `_cardio_load_from_hr`

Cardio load is the backbone of Strain. It uses heart-rate reserve:

`intensity = (heart_rate - resting_heart_rate) / (max_heart_rate - resting_heart_rate)`

The resting heart rate comes from `_resting_hr_for_strain`, which tries:

1. The user's resting-heart-rate baseline.
2. The daily summary's resting heart rate.
3. A low-percentile estimate from raw heart-rate samples.

The max heart rate starts with `estimated_max_heart_rate`, then `_credible_observed_max_hr` can replace it if workout samples show a sustained observed max above the formula estimate.

Only intensities above 30% of heart-rate reserve create cardio load. Above that, points rise nonlinearly:

`points_per_minute = 2.5 * ((intensity - 0.30) / 0.70) ** 1.7`

Each heart-rate sample contributes up to the next 120 seconds. Longer gaps are counted, but not allowed to create unlimited load from stale data.

Why: `research/Strain Scores.pdf` points to Google Cardio Load and older TRIMP-style ideas: load should increase with both duration and intensity, and heart-rate reserve is more personalised than raw heart rate.

### Cardio Confidence

Function: `_cardio_load_from_hr`

The same function also classifies raw heart-rate coverage:

- `strong`: at least 720 covered minutes, or at least 70% workout coverage.
- `moderate`: at least 240 covered minutes, or at least 30% workout coverage.
- `weak`: less than that.

This confidence matters because the app only adds provider zone load when raw heart-rate coverage is weak. It also controls how much gap-fill daily activity load is allowed to contribute.

### Provider Zone Load

Functions: `_source_zone_load`, `_source_zone_load_from_intervals`

When raw heart-rate coverage is weak, the app tries to use provider-supplied heart-rate zones instead. There are two sources:

- Workout summaries through `_source_zone_load`.
- Interval records through `_source_zone_load_from_intervals`.

The logic is simple: minutes in higher zones are worth more points. For workout summaries, the weights are:

- Zone 1: 0.1 per minute
- Zone 2: 0.35 per minute
- Zone 3: 0.8 per minute
- Zone 4: 1.4 per minute
- Zone 5: 2.0 per minute

Why: this preserves the same research principle as cardio load: time at higher intensity should count more than time at low intensity.

### Daily Activity Load

Function: `_daily_activity_load`

Daily activity load catches ordinary activity that may not appear as a workout. It uses the larger of:

- Step load: up to 8 points at 10,000 steps.
- Active-calorie load: up to 12 points at 600 active calories.

Then it adjusts based on cardio confidence:

- If cardio confidence is strong, most movement was probably already captured, so only a tiny gap-fill amount remains.
- If cardio confidence is moderate, activity load is capped at 6.
- If cardio confidence is weak, activity load can contribute more.

Why: `research/Strain Scores.pdf` says low-intensity activity should not be ignored, but it should not double-count what heart rate already captured.

### Muscular Load

Function: `_muscular_load`

Muscular load looks for strength-like workout types, including terms such as strength, weight, resistance, crossfit, hiit, and circuit. Each matching workout contributes:

`min(20, workout_minutes * 0.18)`

Why: the strain research is explicit that heart rate undercounts strength training and other non-steady-state work. This is a first-pass estimate until the app has richer exercise, set, rep, weight, or RPE data.

### Total Strain

Function: `_upsert_strain_score`

Total Strain is:

`cardio_load + optional_source_zone_load + daily_activity_load + muscular_load`

The result is rounded and stored as `load_points`.

Reasons are created with `_strain_reasons`, and confidence comes from `_strain_confidence_phase`, which is based on how many prior Strain days exist.

## Weekly Strain Target

Function: `_upsert_strain_target`

The weekly target is the interpretation layer for Strain. Daily Strain says "how much load happened today." The weekly target says "how does this week's load compare to what this person is used to?"

The target uses the previous 60 days of Strain scores, then `_chronic_load` takes the mean of the most recent 28 valid days. The weekly target is:

`chronic_daily_load * 7`

The target record also stores:

- Current week progress.
- Acute load from the current week.
- Chronic load.
- Progress ratio.
- Load band from `_load_band_for_ratio`.

The bands are:

- `below`: less than 70% of target.
- `steady`: 70% to 115% of target.
- `above`: 115% to 140% of target.
- `well_above`: above 140% of target.

Why: `research/Strain Scores.pdf` points to Apple-style 7-day versus 28-day interpretation and Google-style weekly targets. A weekly target is more useful than forcing daily strain into a fake 0-100 maximum.

## Readiness Score

Function: `_upsert_readiness_score`

Readiness is a 0-100 score. It only calculates when there is a main sleep session for the day. If sleep is missing, Readiness waits with reason `waiting_for_main_sleep`, because the score is meant to describe the body after overnight recovery.

The current weights are:


| Component               | Weight | Function                     |
| ----------------------- | ------ | ---------------------------- |
| Sleep adequacy and debt | 30%    | `_readiness_sleep_component` |
| Autonomic recovery      | 30%    | `_autonomic_component`       |
| Recent load fit         | 25%    | `_load_fit_component`        |
| Illness/anomaly context | 10%    | `_anomaly_component`         |
| Confidence              | 5%     | `_confidence_component`      |


The final number is produced by `_weighted_score`, then possibly capped by anomaly context. This follows `research/Readiness Scores.pdf`: readiness should be a personalised estimate of whether the body looks recovered enough for strain today, not just a sleep score and not just an HRV score.

### Sleep Adequacy and Debt

Function: `_readiness_sleep_component`

This component combines:

- Sleep duration score from `_duration_score`.
- Sleep continuity score from `_continuity_score`.
- Seven-day sleep debt from `_sleep_debt_minutes`.

Duration contributes 65%, continuity contributes 35%, and sleep debt subtracts up to 28 points. Sleep debt is the sum, across the last seven days including the current day, of how many minutes the user slept below target.

Why: the readiness research says sleep adequacy and accumulated sleep debt should be a major part of readiness because poor sleep affects performance, mood, recovery, and autonomic state.

### Autonomic Recovery

Function: `_autonomic_component`

Autonomic recovery compares the day's overnight physiology against the user's own baselines:

- HRV, where higher than baseline is better.
- Resting heart rate, where lower than baseline is better.

Each metric is scored by `_metric_baseline_score`, then the available scores are averaged. `_autonomic_trend_penalty` can subtract up to 16 points if the recent multi-day trend is bad:

- 8 points if recent HRV is below the baseline lower bound.
- 8 points if recent resting heart rate is above the baseline upper bound.

Why: `research/Readiness Scores.pdf` stresses that HRV is useful only against a personal baseline and preferably over multiple days. The trend penalty is the code's way of making persistent deviations matter more than a single noisy reading.

### Recent Load Fit

Function: `_load_fit_component`

Recent load fit asks whether recent Strain is normal for the user. It looks back up to 60 days and adapts based on how much history exists:

- 4 to 6 valid days: compare yesterday to the average.
- 7 to 13 valid days: use a 3-day acute window against the remaining history.
- 14 to 27 valid days: use a 7-day acute window against the remaining history.
- 28 or more valid days: use 7-day acute load against 28-day chronic load.

The ratio is then scored:

- Up to 1.20: 100.
- 1.20 to 1.50: falls from 100 to 75.
- 1.50 to 2.00: falls from 75 to 40.
- Above 2.00: 35.

If yesterday's load is more than twice chronic load, the score loses another 12 points.

Why: the readiness research says recent load should stop Readiness from becoming only a sleep or HRV number. The strain research also cautions that acute-versus-chronic load should be used as an interpretation tool, not a magic injury prediction number. This component follows that: it penalises unusual spikes without claiming to diagnose risk.

### Illness and Anomaly Context

Function: `_anomaly_component`

This component starts at 100 and looks for recovery signals that are outside the normal range:

- Respiratory rate scoring poorly against baseline.
- Oxygen saturation below 94.
- HRV scoring poorly.
- Resting heart rate scoring poorly.
- A user or system context tag for illness.

Each anomaly subtracts 18 points, up to 70 points. It can also cap the whole Readiness score:

- Two anomalies cap Readiness at 70.
- Three or more anomalies cap Readiness at 55.

Why: this follows the Apple Vitals-style idea discussed in `research/Readiness Scores.pdf`: one odd metric can be noise, but several overnight signals moving in the wrong direction together should matter a lot.

### Confidence

Function: `_confidence_component`

Confidence turns baseline maturity into a small score contribution:

- `missing`: 30
- `provisional`: 55
- `calibrating`: 78
- `personalized`: 100

It checks the phases for HRV, resting heart rate, strain load, and sleep minutes, then uses `_combined_phase` to take the weakest phase.

Why: the readiness score is supposed to be personalised. If the app does not yet know the user's normal ranges, the score can still be useful, but it should be less confident.

### Readiness Confidence and Quality

Readiness's `confidence_phase` is the weakest phase among:

- HRV baseline.
- Resting-heart-rate baseline.
- Strain confidence phase.

The `data_quality` field again comes from `_quality_for_components`.

## Baselines

Functions: `rebuild_daily_baselines`, `_baseline_values`, `_metric_value_for_baseline`

Baselines are how the app learns what is normal for the user. They are rebuilt daily for these metrics:

- `sleep_minutes`
- `sleep_start_minute`
- `sleep_end_minute`
- `sleep_efficiency`
- `heart_rate_variability`
- `resting_heart_rate`
- `respiratory_rate`
- `oxygen_saturation`
- `strain_load`

The baseline for a date only uses earlier days. It never uses the current day, so a bad night or a hard workout can affect today's score without immediately redefining what "normal" means.

### Baseline Window

Function: `_baseline_values`

The baseline first tries the previous 28 days. If it can find at least 14 valid days, it uses that 28-day window. If not, it expands to 60 days. This gives the app enough data when history is sparse while still preferring a recent baseline when possible.

Why: the readiness research recommends rolling personal baselines around 21-30 days for signals like HRV and RHR. The code uses 28 days as the preferred window and 60 days as a fallback when data is sparse.

### Baseline Exclusions

Functions: `_baseline_context_exclusion`, `_detect_timezone_shift_context`

Certain days are excluded from baseline learning because they are not good examples of normal:

- illness
- travel
- automatic timezone shift
- sensor anomaly

`_detect_timezone_shift_context` automatically creates a `travel_timezone_shift` context when consecutive sleep sessions show a timezone offset change of at least two hours.

Why: the research files repeatedly emphasise personal baselines, but a personal baseline should represent normal life. Illness, travel, and sensor anomalies should affect the daily interpretation without becoming the new normal.

### Baseline Values

Function: `_metric_value_for_baseline`

Each metric gets its value from the most appropriate source:

- `strain_load` comes from the day's Strain score.
- Sleep timing and efficiency come from the main sleep session.
- HRV, resting heart rate, respiratory rate, oxygen saturation, and sleep minutes come from the daily summary.

If a daily summary is marked as missing, the app excludes most summary-based metrics. Sleep timing, sleep efficiency, and strain load are exceptions because they come from their own sleep or score records.

### Baseline Statistics

Functions: `rebuild_daily_baselines`, `_robust_spread`, `_drop_extreme_outliers`

For each baseline, the app stores:

- Mean value.
- Median value.
- Robust spread.
- Lower bound.
- Upper bound.
- Valid day count.
- Included dates.
- Exclusions.
- Confidence phase.

The robust spread is median absolute deviation scaled by 1.4826. In plain English: it measures typical variation around the median in a way that is less sensitive to weird outlier days than standard deviation.

The lower and upper bounds are:

- `median - 2 * robust_spread`
- `median + 2 * robust_spread`

Before storing the baseline, `_drop_extreme_outliers` removes values more than 4 robust-spread units from the median, as long as there are at least 8 values. That keeps one strange day from dragging the baseline.

### Baseline Confidence Phases

Function: `_phase_for_count`

The phase is based on how many valid days went into the baseline:

- `missing`: 0 valid days.
- `provisional`: 1 to 13 valid days.
- `calibrating`: 14 to 27 valid days.
- `personalized`: 28 or more valid days.

When a score depends on multiple baselines, `_combined_phase` takes the weakest one. This is intentionally conservative. If HRV is personalised but Strain history is still provisional, Readiness should still admit that part of the picture is young.

### How Baselines Update Over Time

Baselines are not incrementally nudged by today's value. They are rebuilt from the rolling historical window each time scores are rebuilt. That means:

- Today's score uses yesterday and earlier to define normal.
- Tomorrow's baseline may include today, unless today is excluded because of illness, travel, timezone shift, sensor anomaly, missing data, or extreme outlier filtering.
- One abnormal day can influence the future only if it is not excluded and not an extreme outlier, and even then it is diluted by the rest of the rolling window.

This is exactly the behaviour the research points toward: react to today's signal, but do not let one unusual day rewrite the user's baseline.

## Reasons

Functions: `_sleep_reasons`, `_strain_reasons`, `_readiness_reasons`, `_reason`

Reasons are short explanations stored with each score. They are designed to answer "why did this score move?" without exposing every calculation.

Every reason has:

- `code`: a stable identifier the app can use.
- `severity`: `info`, `low`, `medium`, or `high`.
- `message`: the user-facing explanation.
- `direction`: usually `negative`, but can be `positive` or `neutral`.

### Sleep Reasons

Function: `_sleep_reasons`

Sleep reasons scan the component scores:

- If a component is below 70, it adds a medium-severity negative reason like `sleep_duration_low`.
- If a component is 90 or higher, it adds a low-severity positive reason like `sleep_duration_strong`.

Only the first three reasons are kept.

### Strain Reasons

Function: `_strain_reasons`

Strain reasons explain the main source of load:

- If total strain is 0, it adds `no_strain_detected`.
- If cardio load is the main contributor, it adds `cardio_load_primary`.
- If muscular load contributed, it adds `muscular_load_estimated`.

Only the first three reasons are kept.

### Readiness Reasons

Function: `_readiness_reasons`

Readiness reasons scan the component scores:

- If a component is below 70, it adds a medium-severity negative reason.
- If a component is 90 or higher, it adds a low-severity positive reason.
- If anomaly context capped the score, it inserts `readiness_anomaly_cap` first with high severity.

Only the first four reasons are kept.

### Waiting Reasons

Function: `_mark_score_waiting`

When a score cannot be calculated yet, it still stores a reason. For example:

- Sleep waits for `waiting_for_main_sleep`.
- Readiness waits for `waiting_for_main_sleep`.
- Strain waits for `waiting_for_activity_data`.

This keeps the UI explainable even when the score is absent.

## Why This Design Holds Together

The scoring system follows three principles from the research:

1. Use the most reliable wearable signals most heavily. Sleep duration, timing, continuity, and HR-derived load are weighted more than fragile sleep-stage details.
2. Compare the user to themselves. HRV, resting heart rate, respiratory rate, sleep timing, and strain are all interpreted through rolling personal baselines wherever possible.
3. Keep the scores conceptually separate. Sleep measures the night. Strain measures load. Readiness measures recovery state. The reasons and future insight layer can explain how they interact without making any one score do too many jobs.

