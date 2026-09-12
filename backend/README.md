# Conceptual Fitness Backend

FastAPI backend for Conceptual Fitness. It handles Google Health API OAuth, encrypted token storage, data sync, and app-facing health summaries.

## Local setup

1. Put local secrets in `backend/.env`.
2. Install dependencies:

   ```bash
   cd backend
   python3 -m venv .venv
   . .venv/bin/activate
   pip install -e ".[dev]"
   ```

3. Start local infrastructure:

   ```bash
   cd ..
   docker compose --env-file backend/.env up -d postgres redis
   cd backend
   ```

4. Run migrations:

   ```bash
   alembic upgrade head
   ```

5. Start the API:

   ```bash
   uvicorn app.main:app --reload
   ```

6. Open the OAuth flow:

   ```text
   http://localhost:8000/auth/google-health/start
   ```

## Useful endpoints

- `GET /healthz`
- `GET /auth/google-health/diagnostics`
- `GET /auth/google-health/start`
- `GET /connections/google-health`
- `POST /sync/manual`
- `GET /sync/status`
- `GET /dashboard/today`
- `GET /summaries/daily?start=YYYY-MM-DD&end=YYYY-MM-DD`

## Sync and calibration

Run `celery -A app.tasks.celery_app worker --loglevel=info` alongside the API for
background imports. The initial import covers 14 calendar days; the historical
job then covers a fixed 90-day range with separate cursors for each source.
Completed sources are preserved when a failed or interrupted job is retried.
The hourly task also queues unfinished calibration work. Interrupted work becomes
retryable after its one-hour lease expires.

`GET /sync/current/status` reports today's refresh with `is_running`, `is_fresh`,
and `has_failure`. Historical progress is separate in `historical_backfill`
(range, overall status, completed/total sources, and source statuses).
`POST /sync/current/historical-backfill/retry` retries unfinished history.
Apply migrations before running the updated API and worker.

### Historical score checkpoints (batch 2)

The 14-day current import publishes scores first. History has one deterministic
checkpoint per completed source: all of that source's pages are coalesced into
one summary/score rebuild, and `succeeded` plus `completed_at` are committed with
the rebuilt scores. No timer fires a rebuild for each page. A failed checkpoint
rolls back derived writes and remains retryable using the saved import cursor;
already successful sources are skipped. Score publication is serialized per user.

Historical edits rebuild summaries for the edited dates and existing dependent
score windows, starting at the earliest edited day. Raw references extend up to
90 days; changes in derived strain inputs propagate into their later consumers
until inputs stop changing or the last existing score date is reached. Dates
before the edit are preserved. This includes workout edits/deletion/merges,
manual body measurements and tags. Current body measurements are never replaced
by an older historical summary's measurements.

The status contract also exposes `current_scores_available`, independent of
`historical_backfill.calibration_state`. History includes `checkpoint_at` and
per-source `coverage_start`, `coverage_end`, `page_in_progress`, and `completed_at`.
Coverage describes checked/processing dates, not a promise that the provider had
records on every date. Empty imports can succeed while scores remain unavailable.

Pass `?data_type=sleep` (or another supported source key) to the historical retry
endpoint to retry only that source, including when a sibling is still running.
A successfully queued retry becomes pending immediately. The Dashboard’s Profile destination shows live progress; each new checkpoint
refreshes Dashboard scores without blocking useful current data. Import details
are kept off the Home screen.

Profile offers an opt-in local completion notification. iOS background refresh
checks for completion; delivery can be delayed until the next allowed background
check or app opening. Permission and completion deduplication are stored per
account on the device. Notifications contain no health measurements. This uses
native BackgroundTasks/UserNotifications and requires no additional service.

Existing accounts may have saved history from before historical progress tracking
was introduced. A successful current-sync cursor covering the entire target range
can seed a completed historical receipt. Untouched job rows plus older saved
records instead expose `coverage_state: untracked`, `stored_from`, and
`stored_through`; Profile shows that saved history is available without claiming
it is missing or that all provider pages were verified. Worker availability does
not determine whether recorded coverage is complete.
