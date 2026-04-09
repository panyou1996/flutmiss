from __future__ import annotations

import os
from dataclasses import dataclass


def _parse_int_list(value: str | None, default: list[int]) -> list[int]:
    if not value:
        return default
    result: list[int] = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            result.append(int(part))
        except ValueError:
            continue
    return result or default


@dataclass(frozen=True)
class Settings:
    app_name: str = os.getenv("APP_NAME", "FluxDO Hupu Compat")
    public_base_url: str = os.getenv("PUBLIC_BASE_URL", "http://127.0.0.1:8000")
    hupu_base_url: str = os.getenv("HUPU_BASE_URL", "https://m.hupu.com")
    request_timeout_seconds: float = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "15"))
    cache_ttl_seconds: int = int(os.getenv("CACHE_TTL_SECONDS", "90"))
    topic_page_size: int = int(os.getenv("TOPIC_PAGE_SIZE", "20"))
    post_id_factor: int = int(os.getenv("POST_ID_FACTOR", "1000000"))
    aggregate_topic_ids: tuple[int, ...] = tuple(
        _parse_int_list(os.getenv("AGGREGATE_TOPIC_IDS"), [1, 60, 294, 88, 93, 177, 184])
    )
    default_avatar_url: str = os.getenv(
        "DEFAULT_AVATAR_URL",
        "https://i3.hoopchina.com.cn/user/default/tiger3.png",
    )
    read_only_username: str = os.getenv("READ_ONLY_USERNAME", "hupu_readonly")


settings = Settings()

