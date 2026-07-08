# Native Health Design Direction

## Goal

The app should feel like a personal health cockpit: native, calm, useful, and data-rich without becoming a generic analytics dashboard. The current weather-led dashboard is the strongest part of the experience because it makes the app feel personal and alive. The next design pass should keep that emotional quality while making the rest of the dashboard and detail pages more distinctive, more consistent, and more actionable.

The main shift is away from repeated report cards and toward a clearer hierarchy:

- What is my state today?
- What changed?
- What should I do next?
- Which details explain that recommendation?

## Decisions From Review

Keep the weather preview as the dashboard atmosphere, but do not add weather details such as temperature, condition icons, or forecast text to the header. The weather should remain environmental and personal, not become another data widget.

Keep the existing sync and last-synced treatment. It is useful, lightweight, and already part of the app's trust model.

Do not include HRV in Daily Status. HRV is an important recovery metric, but it is not a derived score and should not be forced into a progress ring. A progress ring implies a target or completion percentage, which is not meaningful for HRV. HRV should remain in the health metric grid and become more expressive through baseline context and mini-chart treatment.

Keep health metric cards large and grid-based, but make them more useful by adding compact versions of the primary chart. The card should still be scannable at a glance, but it should stop relying only on icon, value, and status text.

Improve metric detail pages with stronger color and chart identity. The HRV concept direction works because color and baseline context make the page feel like a recovery lens rather than a generic report.

Rework workout card identity. The current cards use SF Symbols selected from workout type and colors selected from intensity. That is functional but can feel arbitrary because the icon block dominates the row visually.

## Current Structure

The relevant app surface is concentrated in:

- `ios/ConceptualFitness/Dashboard/DashboardView.swift`
- `ios/ConceptualFitness/Dashboard/DashboardComponents.swift`
- `ios/ConceptualFitness/Shared/GlassPanel.swift`
- `ios/ConceptualFitness/Shared/MetricDetailScreen.swift`
- `ios/ConceptualFitness/Shared/MetricDetailComponents.swift`
- `ios/ConceptualFitness/Shared/ScoreRangeSelector.swift`
- `ios/ConceptualFitness/Shared/HeartRateZones.swift`
- metric detail files under `ios/ConceptualFitness/Dashboard/*DetailView.swift`
- `ios/ConceptualFitness/Dashboard/DailyInsightProvider.swift`
- `ios/ConceptualFitness/Dashboard/DashboardModels.swift`
- dashboard and metric payloads in `backend/app/api/routes/dashboard.py` and `backend/app/api/routes/metrics.py`

The app already has useful shared primitives: `AppBackground`, `glassSurface`, `MetricDetailScreen`, `StatusPill`, `HeroMetricValue`, `MetricSummaryRow`, `MetricTrendRow`, `SelectedChartReadout`, `CircularProgressMetric`, `ScoreRangeNavigator`, and shared chart geometry helpers. The issue is not lack of components; it is that the visual language is not centralized enough and most screens still compose the same glass panel pattern repeatedly.

## Dashboard Direction

### Header And Weather

The dashboard should continue to open with a weather-aware, full-width atmospheric header. It should contain:

- greeting
- shortened daily brief
- existing sync / last-synced navigation bar treatment
- location control if needed, but visually quiet

It should not contain:

- temperature
- weather condition icon as dashboard content
- forecast details
- extra weather labels competing with health state

The weather should act as a living background and mood layer. It should not become the primary data object.

### Daily Status

Daily Status should focus on the derived score system:

- Readiness
- Sleep
- Strain

HRV should not be included here.

The current three-ring approach is understandable, but the next version should feel like one cohesive daily status module instead of three equal circular widgets. The module should make it clear that these three scores interact:

- readiness tells training ambition
- sleep explains recovery foundation
- strain shows load against plan

The design can still use compact rings or radial treatments, but they should sit inside a single status surface with one clear interpretation line. Strain can remain a progress-style visual because it has a weekly target and progress ratio. Readiness and Sleep can use score visuals because they are 0-100 derived scores.

### Daily Brief

The daily brief should become shorter. The current prompt asks for 55 to 65 words, and the dashboard hero currently allocates enough space for an eight-line slot. That makes the header feel considered, but it also pushes the dashboard toward a text-heavy coaching note.

The new daily brief should be closer to a concise daily guidance line or two. It should explain the dominant state and the immediate recommendation without repeating all score details.

Recommended target:

- daytime: what to aim for today and why
- evening: how to wind down tonight and why
- 25 to 35 words
- no bullet points
- no numeric values
- direct “you / your” language
- one dominant limiter or opportunity

### Remove Short Insight

The separate short insight should be removed as a product concept. It currently creates a second generated message in `DailyInsightProvider` and is displayed inside `DailyBriefCard`. With the new dashboard structure, this becomes redundant.

Consequences:

- remove the `shortInsight` generation path from `DailyInsightProvider`
- remove short insight cache kind and preview text
- remove `insight` from `DashboardData`
- remove `data.insight` rendering from `DailyBriefCard`
- update `DashboardView.reload()` so it only requests one generated brief
- update preview states that currently model both daily brief and short insight
- simplify debug behavior so AI availability tracks the single daily brief

This reduces generation work, cache complexity, and duplicate dashboard copy.

## Workout Cards

### Current Behavior

Workout card icon and color are currently derived in the iOS layer:

- `WorkoutSummary.summaryIconName` in `DashboardComponents.swift`
- `WorkoutSummary.summaryTint` in `DashboardComponents.swift`
- `WorkoutDetail.summaryIconName` and `WorkoutDetail.summaryTint` in `WorkoutDetailView.swift`

The icon is selected by string matching the workout type, such as run, cycle, walk, swim, strength, or fallback mixed cardio. The dashboard color is selected from intensity: peak red, vigorous/high orange, moderate blue, light/low green, fallback indigo. Workout detail uses a similar but not identical intensity mapping.

This means the current visual identity is:

- activity type controls glyph
- intensity controls color
- the color is presented as a saturated gradient icon tile

The weakness is that the large colorful icon tile can dominate the row while not adding much insight. A blue walking card and green walking card are both plausible, but the meaning is not obvious unless the user reads the intensity.

### Better Options

Option A: Neutral Activity Glyph, Data-Led Accent

Use a quieter monochrome or low-tint activity glyph, then use a thin accent bar, small status pill, or trailing metric color to express intensity/strain. This keeps the row cleaner and makes the numeric workout result the focus.

Option B: Activity Category Palette

Use stable colors by activity family instead of intensity:

- walking / daily movement: blue or mint
- running / cardio: red or coral
- cycling: cyan or blue
- strength: graphite or purple-neutral
- swimming: cyan
- mobility / yoga: teal

Intensity can then be shown separately through a pill or strain value. This makes repeated workout types feel consistent over time.

Option C: Strain-Band Accent

Use workout type for icon only, and use strain/intensity band for a small secondary accent. This is probably the most semantically honest choice because workout cards are mostly about what happened and how much load it created.

Recommended approach: combine A and C. Keep the activity glyph, remove the heavy saturated icon block, and use a compact strain/intensity accent. On detail pages, the activity header can be more expressive, but the dashboard list should be quiet and scan-first.

### DRY Implementation Direction

The workout mapping should be centralized. Right now the dashboard and workout detail each define their own summary icon/tint logic. Create one shared workout presentation helper or model extension used by both dashboard rows and workout detail. It should own:

- display name normalization
- SF Symbol selection
- activity family
- activity accent
- intensity / strain accent
- fallback behavior

The UI components should consume this presentation object rather than reimplementing mapping locally.

## Health Metric Cards

### Current Behavior

`MetricCardItem` is built in `DashboardComponents.swift` from `DashboardData`. Cards are large square grid items with:

- SF Symbol
- value
- title
- status
- chevron
- tint

This is clear, but it makes every metric feel equally generic. HRV, resting heart rate, skin temperature, SpO2, steps, distance, sleep, calories, and VO2 Max all have different interpretation models, but the cards mostly differ by icon and color.

### New Direction

Keep the larger grid, but add a compact primary-chart preview to each metric card. Each card should show:

- title
- current value
- status or baseline relation
- small trend/baseline/chart preview
- subtle domain color

The mini chart should mirror the detail page's primary chart grammar:

- HRV: mini line with baseline band
- Resting HR: mini line with baseline band
- Respiratory rate: mini line with baseline band
- Skin temperature variation: mini line around baseline / zero band
- SpO2: mini line with low-threshold cue
- Heart rate: compact range or intraday line depending on available data
- VO2 Max: mini trend line
- Sleep: compact bar or timeline summary
- Steps / calories / distance: compact bars with goal or average cue

The card should not become a full chart. It should be a sparkline-sized evidence cue that makes the grid feel alive and helps the user choose what to open.

### Data Consequence

The backend dashboard metric payload is already richer than the current iOS model decodes for many metrics. `dashboard_metric_summaries` returns current, previous, trend, baseline, quality, unit, and direction metadata for most metrics. The iOS `MetricDashboardSummary` currently only decodes current and data quality.

For mini charts, there are two choices:

1. Decode and use more of the existing summary payload for status and trend, then add a small `sparkline` or `preview_points` array to dashboard metric summaries.
2. Avoid changing the dashboard payload and lazily fetch detail data for visible cards.

Recommended approach: extend the dashboard payload with compact preview points. The dashboard should not issue many detail requests just to render the first screen. A compact 7 to 14 point preview per metric is enough, and it keeps the dashboard fast and deterministic.

The backend should shape this payload consistently across metric families, even if individual detail pages have richer chart structures. The iOS dashboard can then render a small set of reusable mini-chart variants.

### DRY Implementation Direction

Create shared dashboard metric presentation types rather than growing `MetricCardItem` into a large per-metric switch. The presentation layer should know:

- metric key
- display title
- unit
- icon
- domain color
- interpretation type
- mini-chart type
- whether higher is better
- status text rules

Create reusable mini-chart views in `Shared`, not inside each metric detail file. The card chart previews should use the same color tokens and geometry helpers as the full charts.

Likely shared mini-chart variants:

- mini baseline line
- mini threshold line
- mini bar set
- mini range line
- mini sleep stage strip
- mini empty state

These should be small, non-interactive, and visually stable inside square metric cards.

## Metric Detail Pages

### Current Behavior

Most detail pages use `MetricDetailScreen`, then stack:

- summary panel
- explanation panel
- chart panel
- pattern/context/reasons panels

This is consistent and understandable. It also causes the screens to feel like similar reports even when the metric meaning is different.

### New Direction

Keep `MetricDetailScreen` for navigation, loading, timeframe, and date selection. Improve the loaded content structure per domain:

1. Hero summary with domain color and status.
2. Primary chart as the visual anchor.
3. Compact explanation or interpretation.
4. Context / drivers / actions below.

Explanation text should not always be a large standalone panel directly after the summary. On some pages it should be a compact contextual line beneath the chart or within the hero area. Users opening HRV, RHR, sleep, or strain are usually trying to understand their own result, not read a static definition first.

### HRV Detail

HRV should keep the baseline concept as the core visual. The stronger concept uses:

- recovery teal / baseline blue
- soft baseline band
- clear relation label
- large current or average value
- short interpretation
- no progress ring

HRV should never imply 100% completion. It is a baseline-relative recovery signal.

### Chart Consistency

The app needs shared chart semantics:

- baseline band
- normal range
- threshold line
- goal line
- selected point
- missing value
- positive / stable / caution / risk state
- domain accent

Currently, color choices are scattered across detail files. The next pass should introduce a shared health theme and shared chart style definitions so full charts and mini charts agree.

Likely shared location:

- `ios/ConceptualFitness/Shared/HealthTheme.swift`
- `ios/ConceptualFitness/Shared/HealthChartStyle.swift`
- `ios/ConceptualFitness/Shared/MiniMetricCharts.swift`

The exact file split can change, but the important part is that semantic colors and chart styling live outside individual detail pages.

## Color Direction

The palette should be native, soft, and semantic.

Recommended semantic families:

- Readiness: green, but not neon
- Sleep: indigo / blue-violet, restrained
- Strain: orange / amber
- Recovery physiology: teal / blue
- Heart rate: red / pink
- Activity: blue / mint
- Respiratory / SpO2: cyan
- Body temperature: amber / warm orange

Recommended status families:

- positive: green
- stable / normal: blue or teal
- caution: amber
- risk / high strain / low oxygen: red or orange
- missing: secondary gray

Avoid allowing each screen to decide independently that “up” is green or orange. For some metrics, up is good; for others, up is caution. Status color should come from metric semantics, not generic trend direction.

## Typography Direction

Use SF Pro defaults where possible and reserve rounded display numerals for health values. The app already does this in several places with rounded bold numeric text and monospaced digits.

Recommended hierarchy:

- dashboard greeting: large rounded title
- daily brief: compact subheadline, medium weight
- primary values: rounded, bold, monospaced where numeric comparison matters
- card labels: compact, semibold
- chart labels: small, restrained, not competing with data

Avoid oversized headings inside cards. The app should feel dense enough for repeated daily use.

## Component Architecture

### Add Shared Theme Layer

Create a shared theme layer that owns domain colors, status colors, chart colors, material constants, and possibly standard spacing/radius values. `GlassPanel.swift` is the current home of app background and glass surface styling, but the theme should not become a single massive file. Keep the glass modifier separate and add focused theme/chart files.

This avoids repeated `.blue`, `.green`, `.orange`, `.indigo`, and `.purple` decisions across detail files.

### Add Presentation Models

Move display mapping out of views where possible.

Useful shared presentation concepts:

- metric presentation by metric key
- workout presentation by workout type, intensity, and strain
- score presentation for readiness, sleep, and strain
- status presentation for normal / elevated / below / above / missing

This keeps dashboard cards, detail heroes, charts, and legends aligned.

### Keep Views Small

The detail files are already large. New shared chart/card primitives should avoid making them larger. Detail files should mostly compose:

- screen shell
- summary content
- chart content
- metric-specific interpretation

Reusable rendering should live in `Shared`.

## Backend And Data Contract

### Dashboard Metric Summaries

The dashboard should receive enough data to render mini charts without fetching each detail endpoint.

Recommended additions to dashboard metric summaries:

- compact preview points
- baseline or threshold summary where relevant
- unit
- trend
- higher-is-better
- relation/status

Some of this already exists in the backend response but is not decoded by iOS. The iOS model should be updated to reflect the actual dashboard contract before adding new preview points.

### Score Data

Daily Status can continue using `DashboardSnapshot.scores` and `strainTarget`. No HRV score should be created for the Daily Status module.

### Prompt Data

The daily brief prompt should still receive HRV and other metric context because HRV may explain the recommendation. The change is only that HRV should not be rendered as a score ring or daily status item.

## Specific Areas To Change

### DashboardView

Use it to keep the weather hero, sync behavior, refresh behavior, and data loading. Simplify AI text loading to one daily brief.

The `heroHeight` logic should be revisited after the daily brief is shortened and the short insight is removed. The page should show the daily status module and first workout/metric content sooner.

### DashboardComponents

This file currently owns too much display mapping and too many dashboard UI concepts. It should be split or reorganized around:

- Daily Status module
- workout card/list components
- health metric grid/cards
- dashboard presentation helpers

Do not let the mini-chart work turn `MetricCard` into a large switch statement. Use shared presentation and mini-chart primitives.

### DailyInsightProvider

Change from two generated outputs to one. The new brief should be shorter and more focused.

Remove:

- `shortInsight`
- short insight prompt mode
- short insight cache kind
- preview short insight

Retain:

- daily/evening slot behavior
- domain contract
- cautious health language
- cache behavior for the single brief

### DashboardModels

Remove the dashboard `insight` field when short insight is removed.

Extend `MetricDashboardSummary` so iOS decodes the richer dashboard summary payload and the new mini-chart preview points.

### WorkoutDetailView And DashboardComponents Workout Extensions

Centralize workout icon/color/presentation logic. Dashboard and detail should not carry separate versions of summary icon and tint mapping.

### Metric Detail Files

Keep existing detail behavior, but migrate shared colors and chart primitives gradually. HRV is the best first target because it most clearly benefits from baseline color treatment and because it should avoid progress-ring metaphors.

After HRV, apply the same architecture to:

- Resting Heart Rate
- Respiratory Rate
- Oxygen Saturation
- Skin Temperature Variation
- Sleep
- Strain
- Readiness

### AppShellView

Keep existing tab structure and sync coordinator. Consider replacing `.tint(.blue)` with a theme-level app tint so tabs and controls align with the new palette.

## Rollout Plan

1. Add shared health theme and chart style primitives.
2. Collapse daily brief generation to one shorter message and remove short insight.
3. Centralize score, metric, and workout presentation mapping.
4. Redesign the dashboard daily status module with Readiness, Sleep, and Strain only.
5. Rework workout cards with quieter glyphs and data-led accents.
6. Extend dashboard metric summary decoding and backend preview data for mini charts.
7. Add mini-chart metric cards while keeping the large grid.
8. Refresh HRV detail as the reference metric detail direction.
9. Apply the same detail-page structure and color semantics across the remaining metric screens.

## Non-Goals

Do not add weather data widgets to the dashboard header.

Do not make HRV look like a score or completion percentage.

Do not replace native controls with custom web-style controls.

Do not make the dashboard dark, neon, or visually dominated by one color family.

Do not add decorative cards inside cards. The app should feel more distinctive through hierarchy, chart language, and semantic color, not through more containers.

