# Scores, Baselines, and Reasons

Here we explain how the app turns the given API data into our own daily Sleep, Strain, and Readiness scores. The aim is to make the scoring logic readable in plain English, while also pointing back to the functions in `backend/app/services/scores.py` and the research notes I wrote in `research/`. If you want to understand the individual scores better, please read the short papers.

## Research Basis

The three local research files map directly to the three scores:

- `research/Sleep Scores.pdf` gives duration 35%, regularity 25%, continuity 20%, timing and onset 10%, overnight physiology 5%, and stages 5%. It defines the interpolation anchors, data-validity rules, caps, and confidence requirements implemented below.
- `research/Strain Scores.pdf` defines two additive load channels: movement-gated heart-rate-reserve cardio load and exercise-specific muscular load. External work, provider zones, and RPE can fill missing coverage within a channel, while a separate weekly target provides interpretation.
- `research/Readiness Scores.pdf` defines a 35/35/30 readiness core built from sleep recovery, autonomic recovery, and recent load recovery. Illness-like signals become post-score modifiers, and confidence remains separate from the arithmetic.

Those recommendations are implemented by the score service modules through `_upsert_sleep_score`, `_upsert_strain_score`, `_upsert_readiness_score`, and the helper functions described below.

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

Sleep is scored from 0 to 100 and answers how restorative the observed sleep was. A valid main sleep and total sleep duration are mandatory. At least two of regularity, continuity, and timing/alignment must also be available; otherwise the score is withheld. This prevents a precise-looking result from being built from too little information.

The algorithm has four core components and two supporting components:

| Component | Weight | Function |
| --- | ---: | --- |
| Duration | 35% | `_duration_score` |
| Regularity | 25% | `_regularity_score` |
| Continuity | 20% | `_continuity_score` |
| Timing and onset | 10% | `_timing_score` |
| Overnight physiology | 5% | `_sleep_physiology_score` |
| Sleep stages | 5% | `_stage_score` |

The available core components are rescaled within the core's fixed 90-point share. Missing physiology or stages use a neutral value of 100: absence cannot lower the score, and their 5% shares are never transferred to another measurement. Confidence records what was missing.

### Duration

Core sleep need starts from the age midpoint: 9 hours at ages 13–17, 8 hours at ages 18–64, and 7 hours 30 minutes at age 65+. A profile target is kept within the corresponding recommended range. High recent strain can change recovery advice elsewhere, but it does not manufacture a larger core need for this score.

Sleep achieved includes the main sleep plus valid, non-overlapping sleep sessions assigned to the same 24-hour sleep day. The scored shortfall is:

`max(0, core sleep need - valid sleep achieved - 30 minutes)`

The 30-minute allowance absorbs small differences and wearable error. Straight-line interpolation is used between these anchors:

| Shortfall | Duration score |
| ---: | ---: |
| 0 min | 100 |
| 30 min | 95 |
| 60 min | 90 |
| 90 min | 80 |
| 120 min | 65 |
| 180 min | 35 |
| 240 min | 10 |
| 300+ min | 0 |

Sleep above core need is not penalised. More than two extra hours is marked as unusually long for explanation, not treated as automatically poor sleep.

### Regularity

Regularity compares bedtime and wake time with the person's circular timing reference for the matching day type (`workday` or `free_day`). Circular calculations correctly treat times around midnight as close together. The schedule drift is the mean of absolute bedtime and wake-time drift.

| Mean schedule drift | Regularity score |
| ---: | ---: |
| 0–30 min | 100 |
| 60 min | 90 |
| 90 min | 75 |
| 120 min | 55 |
| 180 min | 20 |
| 240+ min | 0 |

The reference uses up to 28 comparable prior nights. Seven nights establish the personal component; earlier results are explicitly provisional. There is no universal penalty for sleeping at a particular clock time.

### Continuity

Wake after sleep onset (WASO) drives continuity. Maintenance efficiency and awakenings lasting more than five minutes are supporting caps so the same lost sleep is not counted repeatedly.

| WASO | Continuity score |
| ---: | ---: |
| 0–20 min | 100 |
| 30 min | 90 |
| 40 min | 75 |
| 50 min | 55 |
| 60 min | 35 |
| 90+ min | 0 |

Maintenance efficiency below 85%, 75%, and 65% caps continuity at 80, 40, and 20 respectively. Two or three long awakenings cap it at 85, except two do not cap somebody aged 65+. Four or more cap it at 60.

### Timing and Sleep Onset

The timing component supports sleep latency and circadian alignment. Google Health currently supplies detected sleep start rather than a separate "trying to sleep" timestamp, so latency remains missing and alignment carries the component. Alignment compares actual midsleep with the circular midpoint of the learned sleep window for the matching day type.

| Midsleep drift | Alignment score |
| ---: | ---: |
| 0–30 min | 100 |
| 60 min | 90 |
| 90 min | 75 |
| 120 min | 50 |
| 180+ min | 0 |

If a future source supplies latency, its anchors are 100 through 30 minutes, 75 at 45, 40 at 60, and 0 at 90 minutes; latency and alignment are then averaged equally.

### Overnight Physiology

Physiology begins at 100 and can only reduce the score. Signals are grouped to avoid counting correlated measurements as independent evidence:

- Autonomic: HRV and resting heart rate.
- Respiratory: respiratory rate and oxygen saturation.
- Temperature: overnight temperature variation.

A group is abnormal when one signal crosses its personal two-spread boundary on two consecutive nights, or two related signals cross together tonight. Oxygen saturation below 90% creates an immediate respiratory flag. Zero, one, two, or three abnormal groups score 100, 80, 60, or 40. Missing physiology is neutral and only lowers confidence.

### Sleep Stages

Stages are used only when the timeline covers at least 90% of the sleep period, agrees with total sleep within 10% or 30 minutes, and contains valid, non-overlapping intervals inside the main session. REM and deep sleep must both be present. At least 14 valid prior nights are required, with the latest 28 used as the provider-specific personal reference.

- Both stages within two robust spreads score 100.
- One stage two to three spreads away scores 80.
- One beyond three spreads, or both beyond two spreads, scores 60.
- The same stage beyond two spreads for three consecutive valid nights scores 40.

Broad age plausibility rules can cap stages at 60, but do not award points for hitting a population quota. Missing or invalid stages remain neutral in the final formula.

### Combination, Caps, and Confidence

The available duration, regularity, continuity, and timing scores form the weighted core. The final calculation is:

`sleep score = 0.90 × core score + 0.05 × physiology + 0.05 × stages`

A duration shortfall of 3, 4, or 5 hours caps the final score at 60, 40, or 25. WASO of at least 90 minutes, maintenance efficiency below 65%, or at least four long awakenings caps it at 60. Supporting signals therefore cannot rescue a severely short or fragmented night.

Confidence never changes the arithmetic. It is provisional with sparse history, calibrating when all core components are present with at least seven comparable nights, and personalised only with all core components, a 28-night timing reference, valid stage coverage, and both supporting components. Data quality mirrors this evidence level.

## Strain Score

Function: `_upsert_strain_score`

Strain is an unbounded accumulation of `load_points`, not a 0–100 quality score. It answers how much cardiovascular and muscular load occurred. A value above 100 is valid, and poor sleep or readiness never reduces work that already happened.

The only additive channels are:

`daily strain = cardiovascular load + muscular load`

Heart-rate zones, session RPE, exercise type, distance, steps, and other external work are routing or validation evidence. They do not receive independent percentages and are never added on top of a better estimate of the same channel. Steps and calories cannot create load by themselves.

If there is no usable heart-rate, zone, RPE, or muscular evidence, a past day is `missing_data`, not an assumed rest day. The current day remains `in_progress`.

### Cardio Load

Function: `_cardio_load_from_hr`

Each usable minute starts with heart-rate reserve:

`HRR = clamp((HR - RHR) / (HRmax - RHR), 0, 1)`

Its full-intensity dose is:

`cardio dose = 0.64 × HRR × exp(k × HRR)`

The coefficient `k` is 1.92 for males, 1.67 for females, and 1.795 when sex is unavailable or not specified. Eligibility is continuous:

- Below 30% HRR: multiplier 0.
- From 30% to below 40% HRR: multiplier `(HRR - 0.30) / 0.10`.
- At or above 40% HRR: multiplier 1.

The final minute value is the exponential dose times this multiplier. Daily cardio load sums all eligible minutes.

RHR uses the stable personal baseline first, then the daily summary, then the observed tenth-percentile estimate when enough readings exist. HRmax uses a sustained credible workout observation when available. Otherwise it uses:

`HRmax = 208.9 - 0.74 × age`

A minute needs at least 30 seconds of valid coverage. Gaps up to 90 seconds inside a workout can be interpolated; longer gaps stay missing. A recorded workout supplies movement evidence. Outside workouts, the matching hour needs positive step or distance evidence so caffeine, illness, or stress is not scored as exercise.

Cardio confidence sits beside the result and does not change it:

- `strong`: at least 720 covered minutes, or at least 70% workout coverage.
- `moderate`: at least 240 covered minutes, or at least 30% workout coverage.
- `weak`: less than that.

### Cardio Fallback Routing

Functions: `_source_zone_load`, `_source_zone_load_from_intervals`, `_cardio_rpe_fallback`

Provider zones fill only time not already covered by direct HRR. Zone duration is passed through the same cardio equation using these HRR midpoints:

| Provider zone | HRR midpoint |
| --- | ---: |
| Light | 0.350 |
| Moderate | 0.500 |
| Vigorous | 0.725 |
| Peak | 0.925 |

Interval records are compared minute by minute with direct coverage. Summary-only zones are reduced by the uncovered share of that workout.

If neither HRR nor zones cover an endurance, team-sport, or cardio-circuit workout, session RPE can fill the uncovered duration:

`fallback cardio load = active minutes × session RPE / 10`

A generic strength workout does not use overall session RPE to invent cardio load. RPE may describe its muscular effort instead. Direct HRR, zones, and RPE are mutually exclusive for the same cardio interval.

### Detailed Muscular Load

Functions: `_detailed_muscular_load`, `_set_dose`, `_exercise_e1rm`

Completed logged sets use:

`set dose = repetitions × relative load × exercise involvement × set difficulty × set-status factor`

`relative load = effective load / current exercise-specific e1RM`

For sets of ten repetitions or fewer:

`set e1RM = load × (1 + (repetitions + RIR) / 30)`

RIR enters the e1RM estimate only when it is supplied from 0 to 3. The exercise baseline uses the strongest credible estimate from the previous 90 days. After 42 days without evidence it decays by 0.5% per week, capped at a 10% fall. A first session can use its strongest qualifying set as a provisional within-session baseline.

Exercise involvement is:

- 0.6 for a small isolation exercise.
- 0.8 for a larger single-joint exercise.
- 1.0 for a multi-joint upper-body exercise.
- 1.2 for a lower-body or full-body compound exercise.

Set difficulty is 1.00 at 0–3 RIR or when RIR is missing, 0.85 at 4–5, 0.70 at 6–7, and 0.55 at 8 or more. A warm-up receives a 0.25 set-status factor; working and drop sets receive 1.0. Assisted work subtracts assistance, added load is added, pounds are converted to kilograms, and per-implement loads are multiplied by implement count.

Isometrics replace repetitions with `seconds / 30` and relative intensity. Loaded carries use carried load and distance. Bodyweight and assisted exercise routes use effective body mass when external load is absent.

### Muscle Allocation and Diminishing Returns

Function: `_local_muscular_points`

Each set assigns 70% of its dose equally across primary muscles and 30% equally across secondary muscles. An exercise without secondary muscles assigns 100% to its primary group.

For each muscle:

- If raw local dose is at most 5, local points equal raw dose.
- Above 5:

`local points = 5 + 10 × ln(1 + (raw local dose - 5) / 10)`

Muscular load is the sum of local points. This makes repeated work on one tissue grow more slowly than balanced work across several tissues.

Session RPE modifies the completed muscular result only when fewer than 70% of working sets have RIR:

`session effort modifier = clamp(0.80, 1.20, 0.80 + 0.04 × session RPE)`

This maps RPE 5 to no change and limits the adjustment to ±20%.

### Generic Strength Fallback

Function: `_generic_muscular_load`

A duration-only strength workout uses:

`generic muscular load = category points per active minute × estimated active minutes × session effort modifier`

Active-time fractions are 35% for upper-, lower-, and full-body lifting, 60% for calisthenics, and 70% for circuits. Starting priors are 0.8 points per active minute for upper body, 1.0 for lower body, 1.1 for full body, 0.8 for calisthenics, and 0.9 for circuits.

After at least three detailed sessions in the category, the prior is replaced by the median points per active minute from up to the eight most recent qualifying sessions in the prior 90 days. The generic route and detailed set route are never both applied to one workout.

### Total Strain

Function: `_upsert_strain_score`

The stored total is `cardio load + muscular load`. Both channels and their routing evidence remain in `components`, including workout contributions, local muscle points, coverage, fallback use, and confidence. The displayed one-decimal score is derived from the unrounded channel estimates.

Reasons are created with `_strain_reasons`, and confidence comes from `_strain_confidence_phase`, which is based on how many prior Strain days exist.

## Weekly Strain Target

Function: `_upsert_strain_target`

The weekly target is the interpretation layer for Strain. Daily Strain says "how much load happened today." The weekly target says "how does this week's load compare to what this person is used to?"

The target uses up to the previous 60 valid Strain days. `_chronic_load` calculates both the mean of the latest 28 valid days and an exponentially weighted history with `alpha = 2 / 29`, then retains the higher reference so a short break does not collapse the target. The weekly target is:

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

Readiness is a whole-number score from 0 to 100 estimating preparedness for physical strain during the coming day. It requires the main sleep ending on that day, at least one valid autonomic input, reliable activity coverage for each of the previous three days, and at least seven comparable reference days for the autonomic and residual-load inputs.

The core calculation is:

`core readiness = 0.35 × sleep recovery + 0.35 × autonomic recovery + 0.30 × recent load recovery`

All three blocks are required and each runs from 0 to 100. A missing block is not redistributed across the others. The record instead remains `missing_data` with a calibration reason and the available components.

Respiratory, oxygen, temperature, and explicit illness signals do not receive positive weights. They can apply a post-score penalty or cap. Confidence is also excluded from the arithmetic.

### Sleep Recovery

Function: `_readiness_sleep_component`

Readiness consumes the duration and continuity calculations defined by the Sleep score, but does not consume the full Sleep score. This avoids counting sleep timing, stages, and overnight physiology again.

Recent sleep burden follows:

`burden_today = max(0, 0.90 × burden_yesterday + shortfall - 0.50 × extra sleep)`

Shortfall uses total valid sleep across the sleep day, including valid naps:

`shortfall = max(0, core sleep need - valid sleep achieved - 30 minutes)`

Extra sleep is the valid amount above core need, capped at 120 minutes for one day. A missing night carries the prior burden without decay. Two or more missing nights in the latest seven prevent a precise burden and therefore withhold the complete Readiness score.

The latest shortfall is already represented by duration. It is removed from the burden input before scoring:

`pre-existing burden = max(0, current burden - latest shortfall)`

`burden nights = pre-existing burden / core sleep need`

Burden is interpolated between:

| Burden nights | Burden score |
| ---: | ---: |
| 0 | 100 |
| 0.5 | 90 |
| 1 | 75 |
| 2 | 50 |
| 3 | 25 |
| 4+ | 0 |

Sleep recovery is:

`sleep recovery = 0.55 × duration + 0.25 × continuity + 0.20 × burden score`

Duration and burden are required. If continuity is unavailable, the duration and burden weights are rescaled within this block and confidence falls.

Readiness is capped at 70 after a three-hour duration shortfall, 50 after four hours, and 30 after five hours or more. Severe fragmentation caps it at 70.

### Autonomic Recovery

Function: `_autonomic_component`

Autonomic recovery uses overnight or controlled resting measurements from a consistent source. RMSSD is preferred. SDNN can be used as a separate source-specific fallback when it is the only valid HRV measure; it is never converted into estimated RMSSD or mixed into the same reference. The current Google Health integration supplies Fitbit RMSSD.

HRV is transformed with the natural logarithm before comparison. Resting heart rate remains on its native scale:

`zHRV = (ln(HRV) - log-scale HRV centre) / log-scale HRV spread`

`zRHR = (RHR - RHR centre) / RHR spread`

For each metric, recent `z` is the median of the latest three valid comparable nights, normally inside the latest four calendar nights. The current night remains visible:

`HRV adverse deviation = max(0, -(0.40 × current zHRV + 0.60 × recent zHRV))`

`RHR adverse deviation = max(0, 0.40 × current zRHR + 0.60 × recent zRHR)`

Favourable deviations stop at zero adverse deviation and do not award more than 100. Adverse deviation is interpolated between:

| Adverse spreads | Metric score |
| ---: | ---: |
| 0–0.5 | 100 |
| 1 | 85 |
| 1.5 | 65 |
| 2 | 40 |
| 3 | 10 |
| 4+ | 0 |

With both metrics:

`autonomic recovery = 0.60 × HRV score + 0.40 × RHR score`

If only one is valid, that metric supplies the block and confidence falls. HRV and RHR are not charged again by the anomaly modifier.

### Recent Load Recovery

Function: `_load_recovery_component`

Readiness consumes the separate cardiovascular and muscular channels stored by Strain. The previous three days decay into today's residual exposure:

`cardio residual exposure = 0.60 × C1 + 0.30 × C2 + 0.10 × C3`

`muscular residual exposure = 0.50 × M1 + 0.30 × M2 + 0.20 × M3`

Every prior day must have reliable coverage. Missing activity remains unknown rather than becoming a zero-load rest day. A reliably observed rest day remains zero.

Each channel has its own median and robust-spread reference. The normal reference window is 28 days and extends to 60 calendar days when fewer than 28 valid observations are available:

`adverse exposure = max(0, (residual exposure - centre) / spread)`

The channel score is interpolated between:

| Adverse spreads | Channel score |
| ---: | ---: |
| 0–0.5 | 100 |
| 1 | 90 |
| 2 | 65 |
| 3 | 35 |
| 4+ | 10 |

If both channels are valid:

`recent load recovery = 0.70 × lower channel score + 0.30 × higher channel score`

If only one channel is reliable, it supplies the block and confidence falls.

Detailed resistance-training load is also decayed per muscle group. A local residual above two personal spreads creates a `reduced` local-readiness warning; above three creates `very_reduced`. These warnings explain the muscular result and do not subtract from the global score again.

### Illness-Like Signals and Concordance

Function: `_anomaly_component`

Signals are grouped so correlated measurements do not each collect a full penalty:

- Autonomic group: autonomic recovery below 70.
- Respiratory group: respiratory rate above its personal alert boundary, oxygen saturation below its personal lower boundary, or both adverse together.
- Temperature group: overnight skin-temperature variation above its personal alert boundary.

A non-autonomic group is active when one of its metrics crosses on two consecutive valid nights. The respiratory group can also activate when respiratory rate and oxygen saturation cross together tonight. A single mild crossing remains an explanation and does not change the score.

The modifier is:

| Active condition | Penalty | Cap |
| --- | ---: | ---: |
| No non-autonomic group | 0 | none |
| One respiratory or temperature group | 5 | none |
| One non-autonomic group plus impaired autonomic recovery | 10 | 75 |
| Respiratory and temperature groups | 12 | none |
| Both groups plus impaired autonomic recovery | 18 | 60 |

An explicit illness tag or oxygen saturation below 90% caps Readiness at 40 and produces cautious health language rather than a diagnosis.

After the penalty, the lowest sleep or anomaly cap is applied:

`final readiness = round(clamp(core readiness - anomaly penalty, 0, 100))`

### Confidence

Function: `_readiness_confidence`

Confidence is metadata beside the score and never changes the number.

- High confidence requires duration and continuity, both HRV and RHR, both load channels, complete optional anomaly groups, stable sources, no recent missing sleep, and at least 28 comparable reference days.
- Moderate confidence has the required inputs with 14–27 comparable days or one supporting input missing.
- Low confidence has 7–13 comparable days, only one autonomic input, one reliable load channel, or more limited optional coverage.

These levels map to `personalized`, `calibrating`, and `provisional` phases and to `strong`, `moderate`, and `weak` data quality. When a required block is absent, the score stays in calibration rather than silently moving that block's weight elsewhere.

## Baselines

Functions: `rebuild_daily_baselines`, `_calculate_personal_baseline`, `_metric_value_for_baseline`

Baselines are how the app learns what is normal for the user. They are rebuilt daily for these metrics:

- `sleep_minutes`
- `sleep_start_minute`
- `sleep_end_minute`
- `sleep_efficiency`
- `heart_rate_variability`
- `resting_heart_rate`
- `skin_temperature_variation`
- `respiratory_rate`
- `oxygen_saturation`
- `strain_load`
- `cardio_residual_exposure`
- `muscular_residual_exposure`

The baseline for a date only uses earlier days. It never uses the current day, so a bad night or a hard workout can affect today's score without immediately redefining what "normal" means.

### Reference and Recent Windows

Sleep duration and timing use the prior 28 calendar days. The physiological, efficiency, and strain references can use up to 60 days because they are either sparser or intended to move slowly. Every baseline also stores a recent trend from its latest seven valid comparable readings. The stable reference and recent trend have separate jobs: the reference describes normal, while the recent trend helps identify a short sustained change without immediately redefining normal.

Only prior dates are included. The current measurement can therefore be compared with the reference without leaking into it.

### Baseline Exclusions

Functions: `_baseline_context_exclusion`, `_detect_timezone_shift_context`

Certain days are excluded from baseline learning because they are not good examples of normal:

- illness
- travel
- automatic timezone shift
- sensor anomaly
- device change
- non-wear
- overload or overreaching

Altitude is also excluded for oxygen saturation, respiratory rate, and resting heart rate. Menstrual-cycle context is not discarded from temperature blindly; the baseline records that cycle-aware modelling is unavailable so it does not pretend an unexplained temperature shift is cycle-adjusted.

`_detect_timezone_shift_context` automatically creates a `travel_timezone_shift` context when consecutive sleep sessions show a timezone offset change of at least two hours.

Why: the research files repeatedly emphasise personal baselines, but a personal baseline should represent normal life. Illness, travel, and sensor anomalies should affect the daily interpretation without becoming the new normal.

### Source Consistency

The source account, platform, and device are part of comparability. A baseline uses the latest continuous source run; observations before a detected source change are not mixed into the new reference. Unknown source identity prevents the confidence phase from becoming fully personalised.

This matters especially for HRV, sleep efficiency, respiratory rate, oxygen saturation, and temperature because a device or method change can shift the measurement even when the person has not changed.

### Metric-Specific Calculations

Function: `_metric_value_for_baseline`

Each metric gets its value from the most appropriate source:

- Sleep duration uses only the main sleep session; naps remain separate. Workdays and free days have separate references, and the personal value is stored beside the independent adequacy target so chronically short sleep cannot redefine sufficient sleep.
- Sleep start and end use circular medians and circular robust spread for the matching workday/free-day pattern. Times around midnight therefore stay close together.
- Sleep efficiency uses a provider-specific rolling median and robust spread.
- HRV uses like-for-like rMSSD measurements on the natural-log scale. The stored centre and bounds are converted back to milliseconds for consumers, while scoring uses the log-scale spread.
- Resting heart rate uses a provider-specific median and robust spread over the consistent resting/overnight series.
- Skin temperature variation is treated as a provider-relative measurement. The app does not mistake a provider's deviation-from-baseline metric for absolute body temperature.
- Respiratory rate uses a provider-specific sleep-window reference.
- Oxygen saturation uses the personal median and tenth percentile as a one-sided lower boundary, with 100% as the upper ceiling. It is not treated as a symmetric bell-shaped metric.
- Strain uses a 28-day-half-life exponentially weighted reference across up to 60 days. Recorded zero-load rest days remain zero, while missing days remain absent. The baseline metadata also retains the matching weekday mean rather than presenting an acute:chronic ratio as an injury threshold.
- Cardio and muscular residual exposure use separate median and robust-spread references. They start with the latest 28 calendar days and extend to 60 when fewer than 28 valid residual observations are available.

If a daily summary is marked as missing, the app excludes most summary-based metrics. Sleep timing, sleep efficiency, and strain load are exceptions because they come from their own sleep or score records.

### Stored Baseline Evidence

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
- Calculation method.
- Recent trend and valid-reading count.
- Latest-observation recency.
- Source identity, consistency, and source-run start.
- Metric-specific context such as day type, HRV transform, oxygen lower tail, or strain weekday reference.

The robust spread is median absolute deviation scaled by 1.4826. In plain English: it measures typical variation around the median in a way that is less sensitive to weird outlier days than standard deviation.

Symmetric metrics generally use the centre plus or minus two robust spreads. Circular sleep timing, log HRV, bounded oxygen saturation, efficiency, and strain each use the metric-specific treatment described above. Extreme filtering occurs on the appropriate scale and is deliberately not applied to strain, where a real high-load day is part of the training history.

### Baseline Confidence Phases

Function: `_phase_for_count`

The phase is based on how many valid days went into the baseline:

- `missing`: 0 valid days.
- `provisional`: 1 to 6 valid readings.
- `calibrating`: 7 to 27 valid readings.
- `personalized`: 28 or more valid days.

When a score depends on multiple baselines, `_combined_phase` takes the weakest one. This is intentionally conservative. If HRV is personalised but Strain history is still provisional, Readiness should still admit that part of the picture is young.

### How Baselines Update Over Time

Baselines are rebuilt from the rolling historical window each time scores are rebuilt. That means:

- Today's score uses yesterday and earlier to define normal.
- Tomorrow's baseline may include today unless context, missingness, source comparability, or metric-specific quality rules exclude it.
- One abnormal day can influence the future only if it is not excluded and not an extreme outlier, and even then it is diluted by the rest of the rolling window.

Rolling robust references adapt slowly after a persistent structural change. Short anomalies remain in the recent trend or are excluded, while a genuinely stable new level eventually becomes part of the reference.

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
- A persistent or concordant anomaly modifier adds a high-severity reason.
- An active sleep, illness-like, or safety cap adds the highest-priority reason.
- Elevated local muscular residuals add a muscle-group recovery reason without another deduction.

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
