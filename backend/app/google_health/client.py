from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from datetime import date, timedelta
from typing import Any

import httpx

from app.core.config import Settings, get_settings
from app.google_health.data_types import (
    GOOGLE_HEALTH_API_BASE_URL,
    GOOGLE_OAUTH_REVOKE_URL,
    GOOGLE_OAUTH_USERINFO_URL,
    GOOGLE_OAUTH_TOKEN_URL,
    WEARABLES_DATA_SOURCE_FAMILY,
)


class GoogleHealthAPIError(RuntimeError):
    def __init__(self, message: str, status_code: int | None = None, payload: Any = None) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.payload = payload

# All the google health calls i need to make
class GoogleHealthClient:
    def __init__(self, settings: Settings | None = None, timeout: float | None = None) -> None:
        self.settings = settings or get_settings()
        self.timeout = timeout if timeout is not None else self.settings.google_health_api_timeout_seconds

    async def exchange_code_for_tokens(self, code: str) -> dict[str, Any]:
        data = {
            "code": code,
            "client_id": self.settings.google_health_client_id,
            "client_secret": self.settings.google_health_client_secret,
            "redirect_uri": self.settings.google_health_redirect_uri,
            "grant_type": "authorization_code",
        }
        return await self._post_form(GOOGLE_OAUTH_TOKEN_URL, data)

    async def refresh_access_token(self, refresh_token: str) -> dict[str, Any]:
        data = {
            "client_id": self.settings.google_health_client_id,
            "client_secret": self.settings.google_health_client_secret,
            "refresh_token": refresh_token,
            "grant_type": "refresh_token",
        }
        return await self._post_form(GOOGLE_OAUTH_TOKEN_URL, data)

    async def revoke_token(self, token: str) -> None:
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(GOOGLE_OAUTH_REVOKE_URL, data={"token": token})
        if response.status_code not in {200, 400}:
            raise GoogleHealthAPIError("Google token revocation failed", response.status_code, response.text)

    async def get_identity(self, access_token: str) -> dict[str, Any]:
        return await self._get_json("/users/me/identity", access_token)

    async def get_userinfo(self, access_token: str) -> dict[str, Any]:
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(self.timeout)) as client:
                response = await asyncio.wait_for(
                    client.get(
                        GOOGLE_OAUTH_USERINFO_URL,
                        headers={
                            "Authorization": f"Bearer {access_token}",
                            "Accept": "application/json",
                        },
                    ),
                    timeout=self.timeout,
                )
        except (asyncio.TimeoutError, httpx.TimeoutException) as exc:
            raise GoogleHealthAPIError(
                f"Google userinfo request timed out after {self.timeout:g}s",
                payload={"timeout_seconds": self.timeout},
            ) from exc
        except httpx.HTTPError as exc:
            raise GoogleHealthAPIError(
                "Google userinfo request failed before receiving a response",
                payload={"error": str(exc)},
            ) from exc
        return self._handle_response(response)

    async def list_data_points(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        page_token: str | None = None,
        page_size: int | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {
            "pageSize": page_size if page_size is not None else self.settings.google_health_page_size
        }
        if filter_expr:
            params["filter"] = filter_expr
        if page_token:
            params["pageToken"] = page_token
        return await self._get_json(
            f"/users/me/dataTypes/{data_type}/dataPoints",
            access_token,
            params=params,
        )

    async def reconcile_data_points(
        self,
        data_type: str,
        access_token: str,
        *,
        data_source_family: str = WEARABLES_DATA_SOURCE_FAMILY,
        filter_expr: str | None = None,
        page_token: str | None = None,
        page_size: int | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {
            "dataSourceFamily": data_source_family,
            "pageSize": page_size if page_size is not None else self.settings.google_health_page_size,
        }
        if filter_expr:
            params["filter"] = filter_expr
        if page_token:
            params["pageToken"] = page_token
        return await self._get_json(
            f"/users/me/dataTypes/{data_type}/dataPoints:reconcile",
            access_token,
            params=params,
        )

    async def daily_rollup(
        self,
        data_type: str,
        access_token: str,
        *,
        start: date,
        end: date,
        window_size_days: int = 1,
        page_size: int = 14,
    ) -> dict[str, Any]:
        exclusive_end = end + timedelta(days=1)
        body = {
            "range": {
                "start": {
                    "date": {"year": start.year, "month": start.month, "day": start.day},
                    "time": {"hours": 0, "minutes": 0, "seconds": 0, "nanos": 0},
                },
                "end": {
                    "date": {
                        "year": exclusive_end.year,
                        "month": exclusive_end.month,
                        "day": exclusive_end.day,
                    },
                    "time": {"hours": 0, "minutes": 0, "seconds": 0, "nanos": 0},
                },
            },
            "windowSizeDays": window_size_days,
            "pageSize": page_size,
        }
        return await self._post_json(
            f"/users/me/dataTypes/{data_type}/dataPoints:dailyRollUp",
            access_token,
            body,
        )

    async def iter_data_points(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
    ) -> list[dict[str, Any]]:
        data_points: list[dict[str, Any]] = []
        async for page in self.iter_data_point_pages(
            data_type,
            access_token,
            filter_expr=filter_expr,
            prefer_reconcile=prefer_reconcile,
            page_size=page_size,
        ):
            data_points.extend(page)
        return data_points

    async def iter_data_point_pages(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
        page_token: str | None = None,
    ) -> AsyncIterator[list[dict[str, Any]]]:
        async for points, _next_page_token in self.iter_data_point_pages_with_tokens(
            data_type,
            access_token,
            filter_expr=filter_expr,
            prefer_reconcile=prefer_reconcile,
            page_size=page_size,
            page_token=page_token,
        ):
            yield points

    async def iter_data_point_pages_with_tokens(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
        page_token: str | None = None,
    ) -> AsyncIterator[tuple[list[dict[str, Any]], str | None]]:
        while True:
            if prefer_reconcile:
                payload = await self.reconcile_data_points(
                    data_type,
                    access_token,
                    filter_expr=filter_expr,
                    page_token=page_token,
                    page_size=page_size,
                )
            else:
                payload = await self.list_data_points(
                    data_type,
                    access_token,
                    filter_expr=filter_expr,
                    page_token=page_token,
                    page_size=page_size,
                )
            next_page_token = payload.get("nextPageToken") or None
            yield payload.get("dataPoints", []), next_page_token
            page_token = next_page_token
            if not next_page_token:
                return
            await asyncio.sleep(0.1)

    async def _post_form(self, url: str, data: dict[str, str]) -> dict[str, Any]:
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(self.timeout)) as client:
                response = await asyncio.wait_for(
                    client.post(url, data=data, headers={"Accept": "application/json"}),
                    timeout=self.timeout,
                )
        except (asyncio.TimeoutError, httpx.TimeoutException) as exc:
            raise GoogleHealthAPIError(
                f"Google Health API request timed out after {self.timeout:g}s",
                payload={"url": url, "timeout_seconds": self.timeout},
            ) from exc
        except httpx.HTTPError as exc:
            raise GoogleHealthAPIError(
                "Google Health API request failed before receiving a response",
                payload={"url": url, "error": str(exc)},
            ) from exc
        return self._handle_response(response)

    async def _get_json(
        self,
        path: str,
        access_token: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = f"{GOOGLE_HEALTH_API_BASE_URL}{path}"
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(self.timeout)) as client:
                response = await asyncio.wait_for(
                    client.get(
                        url,
                        headers={
                            "Authorization": f"Bearer {access_token}",
                            "Accept": "application/json",
                        },
                        params=params,
                    ),
                    timeout=self.timeout,
                )
        except (asyncio.TimeoutError, httpx.TimeoutException) as exc:
            raise GoogleHealthAPIError(
                f"Google Health API request timed out after {self.timeout:g}s",
                payload={"path": path, "params": params, "timeout_seconds": self.timeout},
            ) from exc
        except httpx.HTTPError as exc:
            raise GoogleHealthAPIError(
                "Google Health API request failed before receiving a response",
                payload={"path": path, "params": params, "error": str(exc)},
            ) from exc
        return self._handle_response(response)

    async def _post_json(self, path: str, access_token: str, body: dict[str, Any]) -> dict[str, Any]:
        url = f"{GOOGLE_HEALTH_API_BASE_URL}{path}"
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(self.timeout)) as client:
                response = await asyncio.wait_for(
                    client.post(
                        url,
                        headers={
                            "Authorization": f"Bearer {access_token}",
                            "Accept": "application/json",
                            "Content-Type": "application/json",
                        },
                        json=body,
                    ),
                    timeout=self.timeout,
                )
        except (asyncio.TimeoutError, httpx.TimeoutException) as exc:
            raise GoogleHealthAPIError(
                f"Google Health API request timed out after {self.timeout:g}s",
                payload={"path": path, "timeout_seconds": self.timeout},
            ) from exc
        except httpx.HTTPError as exc:
            raise GoogleHealthAPIError(
                "Google Health API request failed before receiving a response",
                payload={"path": path, "error": str(exc)},
            ) from exc
        return self._handle_response(response)

    def _handle_response(self, response: httpx.Response) -> dict[str, Any]:
        if response.status_code < 400:
            if not response.content:
                return {}
            return response.json()
        try:
            payload: Any = response.json()
        except ValueError:
            payload = response.text
        message = "Google Health API request failed"
        if isinstance(payload, dict):
            message = payload.get("error_description") or payload.get("error") or message
        raise GoogleHealthAPIError(message, response.status_code, payload)
