# Initial sync and historical backfill — batch 2

Implemented issues #6 and #7 from tracker #43, within milestone 1 of #51.
Checked on 12 September 2026. Batch 1's existing staged-backfill contract remains
the prerequisite; no dependency or delivery-order changes were necessary.
Implementation is submitted for review; linked issues remain open until merge.

Subsequent user direction overrides #7’s original Home-screen placement: detailed
import progress lives only in Profile. Home still refreshes scores at checkpoints.
The displayed count refers to Google Health data types, not devices.

## Issue #6 — definition of done

- [x] Success/loading/empty/error/retry acceptance: a source stays running until
  its derived scores commit; empty pages still complete; checkpoint failure rolls
  back derived writes; retry resumes saved pages; completed sources are skipped.
  Current-score availability is independent of historical calibration.
- [x] Durable regression coverage: multi-page checkpoint coalescing, rollback,
  retry without reimport, duplicate completed-job suppression, targeted worker
  isolation, downstream baseline invalidation, preservation of earlier scores,
  and removal of deleted workouts from later strength references.
- [x] Accessibility: the shared progress UI exposes textual status and named
  progress/retry controls, without relying on color. Largest Dynamic Type checked.
- [x] Observability: source checkpoint success and exception classes are logged;
  new historical failure logs exclude provider payloads and measurements.
- [x] Visual verification: current scores remain visible during calibration;
  completion, failure, and date coverage verified in the simulator.

## Issue #7 — definition of done

- [x] Success/loading/empty/error/retry acceptance: Profile shows
  source status, requested dates, checked/processing coverage, and completion.
  Offline errors retain the last known progress and offer another check.
  Pending/running sources remain distinct from interrupted sources.
- [x] Durable backend regression coverage: progress contract, source validation,
  stale job retry, queue failure/deduplication, targeted retry while a sibling runs,
  and isolation from current sync cursors/freshness.
- [x] Accessibility: native labeled switches, source-specific retry labels/hints,
  readable status text, a labeled progress value, and wrapping/scrolling at the
  largest accessibility text size. Verified via runtime accessibility inspection.
- [x] Observability: progress, retry, scheduling and notification failures log
  generic diagnostics; notifications contain no measurements.
- [x] Visual verification: loading, not-started, running, interrupted, complete,
  empty and offline fixtures checked on iPhone 17 Pro (iOS 26.5). Profile completion
  and Dashboard failure also checked on the smaller iPhone 17e (iOS 26.5).
- [x] Live-account check: retrying one interrupted source returned that source to
  pending while leaving failed siblings unchanged and existing scores visible.
  Follow-up investigation found no active Celery worker: this verified queueing,
  not real-provider job execution. All 24 historical types remained pending.
- [x] Optional notification: native permission prompt/opt-in checked. A temporary
  on-device assertion check verified background delivery and no repeat delivery
  for the same completion. The temporary test hook was removed after passing.

## Checks and limitations

- Full backend suite: **141 passed**. Follow-up checks passed after strengthening
  the rollback and deleted-workout regression assertions.
- Changed-file Ruff checks, Python compilation and `git diff --check`: passed.
- iOS Debug simulator build and launch: passed on both tested devices.
- Full-repository Ruff reports one pre-existing unused variable in
  `backend/app/api/routes/auth.py:181`; it was not changed in this batch.
- No physical-device or real-time background-scheduling guarantee was tested.
  iOS controls background refresh timing; the UI explicitly explains that a local
  completion notification may wait until a later check or app opening.
- The complete 90-day provider import was not repeated for the real account.
  Full import, resume and failure paths are exercised with provider test doubles;
  the live check uses the existing account and a single targeted retry.

UI fixtures can be opened with `-HistoryPreviewState` followed by `loading`,
`waiting`, `running`, `failed`, `complete`, `empty`, or `offline`. Add
`-HistoryProfile` to show Profile; otherwise Dashboard is shown without import details.
These fixtures are Debug-only. No frontend test target was added.

## Correction: existing history versus job tracking

The absence of a worker does not establish that historical data is missing.
Follow-up inspection found retained history predating the new progress rows.
Those untouched pending rows counted jobs, not existing history, so the original
`0/24` presentation and explanation were misleading.

A recorded successful full-range sync now seeds a completed historical receipt,
independent of worker activity. Existing older records without such a receipt are
shown as **Saved history available**, with the retained record date range; the UI
does not label them incomplete or show a zero-completion counter. Actual running
jobs, provider errors, partial progress and known completions keep their explicit
states. Record endpoints alone are not treated as proof of complete pagination.

Validation: 44 sync tests passed, including full-range receipt recovery without a
worker, preservation of completion, recent-only sync exclusion and older stored
history without a receipt. iOS build and real-account Profile inspection passed.
