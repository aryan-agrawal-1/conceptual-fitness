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
