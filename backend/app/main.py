from __future__ import annotations

from fastapi import FastAPI

from app.api.routes import auth, body, dashboard, health, metrics, profile, scores, sync, tags


app = FastAPI(
    title="Conceptual Fitness Backend",
    version="0.1.0",
    description="Backend for Conceptual Fitness Google Health API OAuth, sync, and health summaries.",
)

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(auth.connections_router)
app.include_router(sync.router)
app.include_router(dashboard.router)
app.include_router(metrics.router)
app.include_router(scores.router)
app.include_router(profile.router)
app.include_router(tags.router)
app.include_router(body.router)
