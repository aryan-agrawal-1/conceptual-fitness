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
