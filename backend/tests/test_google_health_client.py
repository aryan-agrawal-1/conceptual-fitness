from __future__ import annotations

from datetime import date
from typing import Any

import pytest

from app.google_health.client import GoogleHealthClient


@pytest.mark.asyncio
async def test_daily_rollup_uses_closed_open_civil_range(monkeypatch) -> None:
    client = GoogleHealthClient()
    captured: dict[str, Any] = {}

    async def fake_post_json(path: str, access_token: str, body: dict[str, Any]) -> dict[str, Any]:
        captured["path"] = path
        captured["access_token"] = access_token
        captured["body"] = body
        return {"rollupDataPoints": []}

    monkeypatch.setattr(client, "_post_json", fake_post_json)

    await client.daily_rollup(
        "total-calories",
        "access-token",
        start=date(2026, 6, 5),
        end=date(2026, 6, 18),
    )

    assert captured["path"] == "/users/me/dataTypes/total-calories/dataPoints:dailyRollUp"
    assert captured["access_token"] == "access-token"
    assert captured["body"]["range"]["start"] == {
        "date": {"year": 2026, "month": 6, "day": 5},
        "time": {"hours": 0, "minutes": 0, "seconds": 0, "nanos": 0},
    }
    assert captured["body"]["range"]["end"] == {
        "date": {"year": 2026, "month": 6, "day": 19},
        "time": {"hours": 0, "minutes": 0, "seconds": 0, "nanos": 0},
    }
    assert captured["body"]["windowSizeDays"] == 1
    assert captured["body"]["pageSize"] == 14
