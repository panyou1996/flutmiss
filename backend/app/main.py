from __future__ import annotations

import json
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse

from .config import settings
from .hupu_client import HupuClient, HupuClientError
from .mappers import (
    build_category_state,
    build_preloaded_payload,
    build_site_payload,
    build_topic_detail_response,
    build_topic_list_response,
    discourse_category_payload,
    discourse_page_for_post_number,
    map_main_post,
    map_nested_reply_post,
    map_reply_post,
    map_topic_from_detail,
    map_topic_thread,
    normalize_html_content,
    split_post_id,
    stable_user_id,
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    client = HupuClient()
    try:
        app.state.hupu = client
        yield
    finally:
        await client.close()


app = FastAPI(title=settings.app_name, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_client() -> HupuClient:
    return app.state.hupu


async def get_category_state() -> dict[str, Any]:
    groups = await get_client().fetch_zone_catalog()
    return build_category_state(groups)


def _encode_preloaded_attribute(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return (
        raw.replace("&", "&amp;")
        .replace('"', "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("'", "&#39;")
    )


def _read_only_error() -> JSONResponse:
    return JSONResponse(
        status_code=501,
        content={"errors": ["read-only backend"], "error_type": "read_only_backend"},
    )


async def _topic_list_for_zone(topic_id: int, discourse_page: int, route_path: str) -> dict[str, Any]:
    state = await get_category_state()
    category = state["children_by_topic_id"].get(topic_id)
    if category is None:
        raise HTTPException(status_code=404, detail="Unknown category")
    data = await get_client().fetch_zone_threads_by_offset_page(topic_id, discourse_page)
    topics = [map_topic_thread(item, category) for item in data.get("topicThreads", [])]
    has_more = bool(data.get("nextCursor"))
    next_url = f"{route_path}?page={discourse_page + 1}" if has_more else None
    return build_topic_list_response(topics, next_url)


async def _topic_list_for_latest(discourse_page: int, topic_ids: list[int] | None = None) -> dict[str, Any]:
    state = await get_category_state()
    selected_topic_ids = topic_ids or list(state["hot_topic_ids"] or settings.aggregate_topic_ids)
    rows: list[dict[str, Any]] = []

    if topic_ids:
        for tid in topic_ids:
            detail = await get_client().fetch_thread_detail(tid)
            forum_name = ((detail.get("t_detail") or {}).get("f_info") or {}).get("f_name")
            category = state["children_by_forum_name"].get(forum_name)
            rows.append(map_topic_from_detail(tid, detail, category))
        return build_topic_list_response(rows, None)

    for topic_id in selected_topic_ids:
        category = state["children_by_topic_id"].get(topic_id)
        if category is None:
            continue
        data = await get_client().fetch_zone_threads_by_offset_page(topic_id, discourse_page)
        rows.extend(map_topic_thread(item, category) for item in data.get("topicThreads", []))

    deduped: dict[int, dict[str, Any]] = {}
    for row in rows:
        deduped[row["id"]] = row
    sorted_rows = sorted(
        deduped.values(),
        key=lambda item: item.get("last_posted_at") or "",
        reverse=True,
    )
    next_url = f"/latest.json?page={discourse_page + 1}" if sorted_rows else None
    return build_topic_list_response(sorted_rows, next_url)


async def _build_topic_detail(topic_id: int, post_number: int | None = None) -> dict[str, Any]:
    client = get_client()
    state = await get_category_state()
    detail = await client.fetch_thread_detail(topic_id)
    forum_name = ((detail.get("t_detail") or {}).get("f_info") or {}).get("f_name")
    category = state["children_by_forum_name"].get(forum_name)
    total_replies = int((detail.get("t_detail") or {}).get("replies") or 0)
    total_posts = total_replies + 1
    stream_numbers = list(range(1, total_posts + 1))

    if post_number is None or post_number <= 1:
        page = 1
    else:
        page = discourse_page_for_post_number(post_number) + 1

    reply_page = await client.fetch_thread_replies(topic_id, page=page)
    reply_rows = reply_page.get("list") or []
    pid_to_post_number = {
        str(item.get("pid")): ((page - 1) * settings.topic_page_size + index + 2)
        for index, item in enumerate(reply_rows)
        if item.get("pid") is not None
    }

    posts: list[dict[str, Any]] = []
    if post_number is None or post_number <= settings.topic_page_size + 1:
        posts.append(map_main_post(topic_id, detail))

    for index, reply in enumerate(reply_rows):
        number = (page - 1) * settings.topic_page_size + index + 2
        quote_info = reply.get("quote_info") or {}
        quoted_number = pid_to_post_number.get(str(quote_info.get("pid")), 0)
        posts.append(map_reply_post(topic_id, number, reply, quoted_post_number=quoted_number))

    posts.sort(key=lambda item: item["post_number"])
    return build_topic_detail_response(topic_id, detail, category, posts, stream_numbers)


async def _resolve_posts_by_numbers(topic_id: int, post_numbers: list[int]) -> list[dict[str, Any]]:
    if not post_numbers:
        return []

    client = get_client()
    detail = await client.fetch_thread_detail(topic_id)
    page_to_numbers: dict[int, list[int]] = {}
    for post_number in sorted(set(post_numbers)):
        if post_number <= 1:
            continue
        page = discourse_page_for_post_number(post_number) + 1
        page_to_numbers.setdefault(page, []).append(post_number)

    reply_pages = {
        page: await client.fetch_thread_replies(topic_id, page=page)
        for page in sorted(page_to_numbers)
    }

    result: list[dict[str, Any]] = []
    if 1 in post_numbers:
        result.append(map_main_post(topic_id, detail))

    for page, numbers in page_to_numbers.items():
        reply_rows = reply_pages[page].get("list") or []
        pid_to_post_number = {
            str(item.get("pid")): ((page - 1) * settings.topic_page_size + index + 2)
            for index, item in enumerate(reply_rows)
            if item.get("pid") is not None
        }
        index_by_number = {
            ((page - 1) * settings.topic_page_size + index + 2): item
            for index, item in enumerate(reply_rows)
        }
        for number in numbers:
            reply = index_by_number.get(number)
            if reply is None:
                continue
            quote_info = reply.get("quote_info") or {}
            quoted_number = pid_to_post_number.get(str(quote_info.get("pid")), 0)
            result.append(map_reply_post(topic_id, number, reply, quoted_post_number=quoted_number))

    result.sort(key=lambda item: item["post_number"])
    return result


@app.exception_handler(HupuClientError)
async def hupu_error_handler(_: Any, exc: HupuClientError) -> JSONResponse:
    return JSONResponse(status_code=502, content={"errors": [str(exc)], "error_type": "upstream_hupu_error"})


@app.get("/", response_class=HTMLResponse)
async def index() -> HTMLResponse:
    state = await get_category_state()
    latest = await _topic_list_for_latest(discourse_page=0)
    site_payload = build_site_payload([discourse_category_payload(item) for item in state["categories"]])
    preloaded = build_preloaded_payload(site_payload, latest)
    preloaded_attr = _encode_preloaded_attribute(preloaded)
    html_body = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="csrf-token" content="readonly-hupu-csrf">
  <meta name="shared_session_key" content="readonly-hupu-session">
  <meta name="discourse-base-uri" content="/">
  <meta id="data-discourse-setup" data-cdn="https://m.hupu.com">
  <title>{settings.app_name}</title>
</head>
<body>
  <div id="data-preloaded" data-preloaded="{preloaded_attr}"></div>
</body>
</html>"""
    return HTMLResponse(content=html_body)


@app.get("/site.json")
async def site_json() -> dict[str, Any]:
    state = await get_category_state()
    return build_site_payload([discourse_category_payload(item) for item in state["categories"]])


@app.get("/session/csrf")
async def session_csrf() -> dict[str, Any]:
    return {"csrf": "readonly-hupu-csrf"}


@app.get("/latest.json")
async def latest_json(page: int = 0, topic_ids: str | None = None) -> dict[str, Any]:
    ids = [int(item) for item in topic_ids.split(",")] if topic_ids else None
    return await _topic_list_for_latest(page, ids)


@app.get("/new.json")
@app.get("/unread.json")
@app.get("/unseen.json")
@app.get("/hot.json")
@app.get("/top.json")
async def aliased_topic_lists(page: int = 0) -> dict[str, Any]:
    return await _topic_list_for_latest(page)


@app.get("/c/{slug}.json")
async def category_by_slug(slug: str, page: int = 0) -> dict[str, Any]:
    state = await get_category_state()
    category = state["children_by_slug"].get(slug)
    if category is None:
        raise HTTPException(status_code=404, detail="Unknown category slug")
    return await _topic_list_for_zone(category["id"], page, f"/c/{slug}.json")


@app.get("/c/{slug}/{category_id}.json")
async def category_by_id(slug: str, category_id: int, page: int = 0) -> dict[str, Any]:
    return await _topic_list_for_zone(category_id, page, f"/c/{slug}/{category_id}.json")


@app.get("/c/{slug}/{category_id}/l/{filter_name}.json")
async def category_filter(slug: str, category_id: int, filter_name: str, page: int = 0) -> dict[str, Any]:
    return await _topic_list_for_zone(category_id, page, f"/c/{slug}/{category_id}/l/{filter_name}.json")


@app.get("/c/{parent_slug_value}/{slug}/{category_id}/l/{filter_name}.json")
async def category_filter_with_parent(
    parent_slug_value: str,
    slug: str,
    category_id: int,
    filter_name: str,
    page: int = 0,
) -> dict[str, Any]:
    return await _topic_list_for_zone(
        category_id,
        page,
        f"/c/{parent_slug_value}/{slug}/{category_id}/l/{filter_name}.json",
    )


@app.get("/t/{topic_id}.json")
async def topic_detail(topic_id: int) -> dict[str, Any]:
    return await _build_topic_detail(topic_id)


@app.get("/t/{topic_id}/posts.json")
async def topic_posts(
    topic_id: int,
    post_number: int | None = None,
    asc: bool = True,
    post_ids: list[int] = Query(default=[], alias="post_ids[]"),
) -> dict[str, Any]:
    detail = await get_client().fetch_thread_detail(topic_id)
    total_replies = int((detail.get("t_detail") or {}).get("replies") or 0)
    total_posts = total_replies + 1

    if post_ids:
        numbers = [split_post_id(post_id)[1] if post_id > settings.post_id_factor else post_id for post_id in post_ids]
    elif post_number is not None:
        if asc:
            numbers = list(range(post_number + 1, min(total_posts, post_number + settings.topic_page_size) + 1))
        else:
            start = max(1, post_number - settings.topic_page_size)
            numbers = list(range(start, post_number))
    else:
        numbers = []

    posts = await _resolve_posts_by_numbers(topic_id, numbers)
    return {
        "post_stream": {
            "posts": posts,
            "stream": [item["id"] for item in posts],
        }
    }


@app.get("/t/{topic_id}/{post_number}.json")
async def topic_detail_by_post_number(
    topic_id: int,
    post_number: int,
    filter: str | None = None,
    username_filters: str | None = None,
    filter_top_level_replies: bool | None = None,
) -> dict[str, Any]:
    _ = (filter, username_filters, filter_top_level_replies)
    return await _build_topic_detail(topic_id, post_number=post_number)


@app.get("/posts/by_number/{topic_id}/{post_number}")
async def post_by_number(topic_id: int, post_number: int) -> dict[str, Any]:
    posts = await _resolve_posts_by_numbers(topic_id, [post_number])
    if not posts:
        raise HTTPException(status_code=404, detail="Post not found")
    return posts[0]


@app.get("/posts/{post_id}.json")
async def post_json(post_id: int) -> dict[str, Any]:
    topic_id, post_number = split_post_id(post_id)
    posts = await _resolve_posts_by_numbers(topic_id, [post_number])
    if not posts:
        raise HTTPException(status_code=404, detail="Post not found")
    post = posts[0]
    post["raw"] = normalize_html_content(post["cooked"])
    return post


@app.get("/posts/{post_id}/reply-ids.json")
async def post_reply_ids(post_id: int) -> list[dict[str, int]]:
    _ = post_id
    return []


@app.get("/posts/{post_id}/replies")
async def post_replies(post_id: int, after: int = 1) -> list[dict[str, Any]]:
    topic_id, post_number = split_post_id(post_id)
    if post_number <= 1:
        return []
    posts = await _resolve_posts_by_numbers(topic_id, [post_number])
    if not posts:
        return []
    parent_post = posts[0]

    page = discourse_page_for_post_number(post_number) + 1
    page_data = await get_client().fetch_thread_replies(topic_id, page=page)
    reply_rows = page_data.get("list") or []
    page_index = (page - 1) * settings.topic_page_size
    raw_pid = None
    for index, item in enumerate(reply_rows):
        if page_index + index + 2 == post_number:
            raw_pid = str(item.get("pid")) if item.get("pid") is not None else None
            break
    if raw_pid is None:
        return []

    detail = await get_client().fetch_reply_detail(topic_id, raw_pid)
    replies = detail.get("replies") or []
    nested = [
        map_nested_reply_post(topic_id, parent_post["id"], index + 1, item)
        for index, item in enumerate(replies)
        if index + 1 >= after
    ]
    return nested


@app.get("/u/{username}.json")
async def user_json(username: str) -> dict[str, Any]:
    return {
        "user": {
            "id": stable_user_id(username),
            "username": username,
            "name": username,
            "avatar_template": settings.default_avatar_url,
            "trust_level": 0,
            "bio_excerpt": "Read-only Hupu user stub",
            "can_send_private_messages": False,
            "can_send_private_message_to_user": False,
        }
    }


@app.get("/u/{username}/summary.json")
async def user_summary(username: str) -> dict[str, Any]:
    _ = username
    return {
        "user_summary": {
            "days_visited": 0,
            "posts_read_count": 0,
            "likes_received": 0,
            "likes_given": 0,
            "topic_count": 0,
            "post_count": 0,
            "time_read": 0,
            "bookmark_count": 0,
            "topics_entered": 0,
            "recent_time_read": 0,
            "replies": [],
            "links": [],
            "most_replied_to_users": [],
            "most_liked_by_users": [],
            "most_liked_users": [],
            "top_categories": [],
        },
        "topics": [],
        "badges": [],
    }


@app.api_route("/{path:path}", methods=["POST", "PUT", "PATCH", "DELETE"])
async def read_only_write_routes(path: str) -> JSONResponse:
    _ = path
    return _read_only_error()


@app.get("/{path:path}")
async def unsupported_get(path: str) -> JSONResponse:
    _ = path
    return JSONResponse(
        status_code=404,
        content={"errors": ["unsupported route"], "error_type": "unsupported_route"},
    )
