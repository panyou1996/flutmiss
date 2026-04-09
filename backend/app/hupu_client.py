from __future__ import annotations

import json
import time
from typing import Any

import httpx
from selectolax.parser import HTMLParser
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from .config import settings


class HupuClientError(RuntimeError):
    pass


class HupuClient:
    def __init__(self) -> None:
        self._client = httpx.AsyncClient(
            base_url=settings.hupu_base_url,
            timeout=settings.request_timeout_seconds,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
                ),
                "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            },
            follow_redirects=True,
        )
        self._cache: dict[str, tuple[float, Any]] = {}

    async def close(self) -> None:
        await self._client.aclose()

    def _cache_get(self, key: str) -> Any | None:
        entry = self._cache.get(key)
        if entry is None:
            return None
        expires_at, value = entry
        if expires_at < time.time():
            self._cache.pop(key, None)
            return None
        return value

    def _cache_set(self, key: str, value: Any) -> Any:
        self._cache[key] = (time.time() + settings.cache_ttl_seconds, value)
        return value

    @retry(
        retry=retry_if_exception_type((httpx.HTTPError, HupuClientError)),
        wait=wait_exponential(multiplier=0.3, min=0.3, max=2),
        stop=stop_after_attempt(3),
        reraise=True,
    )
    async def _request_json(self, url: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        response = await self._client.get(url, params=params)
        response.raise_for_status()
        data = response.json()
        if not isinstance(data, dict):
            raise HupuClientError(f"Unexpected JSON payload for {url}")
        return data

    @retry(
        retry=retry_if_exception_type((httpx.HTTPError, HupuClientError)),
        wait=wait_exponential(multiplier=0.3, min=0.3, max=2),
        stop=stop_after_attempt(3),
        reraise=True,
    )
    async def _request_text(self, url: str) -> str:
        response = await self._client.get(url)
        response.raise_for_status()
        return response.text

    def _extract_next_data(self, html: str) -> dict[str, Any]:
        parser = HTMLParser(html)
        node = parser.css_first("script#__NEXT_DATA__")
        if node is None or not node.text():
            raise HupuClientError("Missing __NEXT_DATA__")
        try:
            data = json.loads(node.text())
        except json.JSONDecodeError as exc:
            raise HupuClientError("Invalid __NEXT_DATA__ JSON") from exc
        if not isinstance(data, dict):
            raise HupuClientError("Unexpected __NEXT_DATA__ shape")
        return data

    async def fetch_zone_catalog(self) -> list[dict[str, Any]]:
        cache_key = "zone_catalog"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached

        html = await self._request_text("/zone")
        next_data = self._extract_next_data(html)
        groups = next_data["props"]["pageProps"]["data"]
        if not isinstance(groups, list):
            raise HupuClientError("Invalid zone catalog payload")
        return self._cache_set(cache_key, groups)

    async def fetch_zone_threads(self, topic_id: int, page: int = 1, cursor: str | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {"topicId": topic_id, "page": page}
        if cursor:
            params["cursor"] = cursor
        cache_key = f"topic_threads:{topic_id}:{page}:{cursor or ''}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached
        payload = await self._request_json("/api/v2/bbs/topicThreads", params=params)
        data = payload.get("data")
        if not isinstance(data, dict):
            raise HupuClientError("Invalid topic thread payload")
        return self._cache_set(cache_key, data)

    async def fetch_zone_threads_by_offset_page(self, topic_id: int, discourse_page: int) -> dict[str, Any]:
        target_page = discourse_page + 1
        cursor: str | None = None
        current: dict[str, Any] | None = None
        for page in range(1, target_page + 1):
            current = await self.fetch_zone_threads(topic_id, page=page, cursor=cursor)
            cursor = current.get("nextCursor")
        if current is None:
            raise HupuClientError("Failed to resolve topic page")
        return current

    async def fetch_thread_detail(self, topic_id: int) -> dict[str, Any]:
        cache_key = f"thread_detail:{topic_id}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached
        payload = await self._request_json(f"/api/v2/bbs-thread/{topic_id}")
        data = payload.get("data")
        if not isinstance(data, dict):
            raise HupuClientError("Invalid thread detail payload")
        return self._cache_set(cache_key, data)

    async def fetch_thread_replies(self, topic_id: int, page: int = 1) -> dict[str, Any]:
        cache_key = f"thread_replies:{topic_id}:{page}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached
        payload = await self._request_json(f"/api/v2/reply/list/{topic_id}", params={"page": page})
        data = payload.get("data")
        if not isinstance(data, dict):
            raise HupuClientError("Invalid thread replies payload")
        return self._cache_set(cache_key, data)

    async def fetch_reply_detail(self, topic_id: int, raw_pid: str) -> dict[str, Any]:
        cache_key = f"reply_detail:{topic_id}:{raw_pid}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached
        payload = await self._request_json(f"/api/v2/bbs-reply-detail/{topic_id}-{raw_pid}")
        data = payload.get("data")
        if not isinstance(data, dict):
            raise HupuClientError("Invalid reply detail payload")
        return self._cache_set(cache_key, data)

