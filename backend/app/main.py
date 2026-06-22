from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.routes import auth, body, dashboard, health, metrics, profile, scores, sync, tags
from app.core.config import get_settings, validate_production_settings


settings = get_settings()
validate_production_settings(settings)


app = FastAPI(
    title="Conceptual Fitness Backend",
    version="0.1.0",
    description="Backend for Conceptual Fitness Google Health API OAuth, sync, and health summaries.",
)

if settings.allowed_cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.allowed_cors_origins),
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["Authorization", "Content-Type"],
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
