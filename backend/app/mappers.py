from __future__ import annotations

import hashlib
import html
import math
import re
from collections import OrderedDict
from datetime import UTC, datetime, timedelta
from typing import Any

from .config import settings

IMG_FIX_RE = re.compile(r"/\s+data-imgid=")
HIDDEN_TIME_RE = re.compile(r'data-time="(\d{10})"')


def stable_user_id(username: str) -> int:
    digest = hashlib.sha1(username.encode("utf-8")).hexdigest()[:8]
    return int(digest, 16)


def compose_post_id(topic_id: int, post_number: int) -> int:
    return topic_id * settings.post_id_factor + post_number


def split_post_id(post_id: int) -> tuple[int, int]:
    return divmod(post_id, settings.post_id_factor)


def parent_category_id(cate_id: int) -> int:
    return 10000 + cate_id


def parent_slug(cate_id: int) -> str:
    return f"cate-{cate_id}"


def child_slug(topic_id: int) -> str:
    return f"zone-{topic_id}"


def topic_slug(topic_id: int) -> str:
    return f"hupu-{topic_id}"


def normalize_html_content(content: str | None) -> str:
    if not content:
        return "<p></p>"
    fixed = IMG_FIX_RE.sub(' data-imgid=', content)
    return fixed


def parse_relative_time(text: str | None) -> datetime | None:
    if not text:
        return None

    text = text.strip()
    now = datetime.now(UTC)
    if text == "刚刚":
        return now

    units = {
        "秒前": "seconds",
        "分钟前": "minutes",
        "小时前": "hours",
        "天前": "days",
    }
    for suffix, unit in units.items():
        if text.endswith(suffix):
            try:
                count = int(text[: -len(suffix)].strip())
            except ValueError:
                return now
            return now - timedelta(**{unit: count})

    if text.endswith("月前"):
        try:
            count = int(text[:-2].strip())
        except ValueError:
            return now
        return now - timedelta(days=count * 30)

    if re.fullmatch(r"\d{2}-\d{2}", text):
        month, day = map(int, text.split("-"))
        year = now.year
        dt = datetime(year, month, day, tzinfo=UTC)
        if dt > now + timedelta(days=1):
            dt = datetime(year - 1, month, day, tzinfo=UTC)
        return dt

    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(UTC)
    except ValueError:
        return None


def extract_hidden_epoch(content: str | None) -> datetime | None:
    if not content:
        return None
    match = HIDDEN_TIME_RE.search(content)
    if match is None:
        return None
    return datetime.fromtimestamp(int(match.group(1)), tz=UTC)


def isoformat_or_none(value: datetime | None) -> str | None:
    return value.isoformat().replace("+00:00", "Z") if value else None


def build_category_state(catalog_groups: list[dict[str, Any]]) -> dict[str, Any]:
    parent_names: dict[int, str] = {}
    children: list[dict[str, Any]] = []
    by_topic_id: dict[int, dict[str, Any]] = {}
    by_slug: dict[str, dict[str, Any]] = {}
    by_forum_name: dict[str, dict[str, Any]] = {}
    hot_topic_ids: list[int] = []

    for group in catalog_groups:
        topic_list = group.get("topicList") or []
        group_category_id = int(group.get("categoryId") or 0)
        group_name = str(group.get("name") or "")
        if group_category_id > 0 and group_name:
            parent_names[group_category_id] = group_name
        if group_category_id == 0:
            hot_topic_ids = [int(item["topicId"]) for item in topic_list if item.get("topicId")]
        for item in topic_list:
            topic_id = int(item["topicId"])
            cate_id = int(item.get("cateId") or group_category_id or 0)
            if cate_id > 0 and group_category_id > 0 and group_name:
                parent_names.setdefault(cate_id, group_name)
            child = {
                "id": topic_id,
                "slug": child_slug(topic_id),
                "name": str(item.get("topicName") or topic_id),
                "description": str(item.get("count") or ""),
                "parent_category_id": parent_category_id(cate_id) if cate_id > 0 else None,
                "cate_id": cate_id,
                "logo": item.get("topicLogo"),
                "permission": 3,
            }
            if topic_id not in by_topic_id:
                children.append(child)
            by_topic_id[topic_id] = child
            by_slug[child["slug"]] = child
            by_forum_name[child["name"]] = child

    parents = [
        {
            "id": parent_category_id(cate_id),
            "slug": parent_slug(cate_id),
            "name": name,
            "description": None,
            "parent_category_id": None,
            "permission": 3,
        }
        for cate_id, name in sorted(parent_names.items(), key=lambda item: item[0])
    ]
    categories = parents + sorted(children, key=lambda item: item["id"])
    return {
        "categories": categories,
        "children_by_topic_id": by_topic_id,
        "children_by_slug": by_slug,
        "children_by_forum_name": by_forum_name,
        "hot_topic_ids": hot_topic_ids,
    }


def discourse_category_payload(category: dict[str, Any]) -> dict[str, Any]:
    payload = {
        "id": category["id"],
        "name": category["name"],
        "slug": category["slug"],
        "description": category.get("description"),
        "parent_category_id": category.get("parent_category_id"),
        "color": "EA0E20" if category.get("parent_category_id") else "1F2937",
        "text_color": "FFFFFF",
        "read_restricted": False,
        "permission": category.get("permission", 3),
        "allow_global_tags": False,
        "allowed_tags": [],
        "allowed_tag_groups": [],
        "required_tag_groups": [],
        "minimum_required_tags": 0,
    }
    if category.get("logo"):
        payload["uploaded_logo"] = {"url": category["logo"]}
    return payload


def discourse_user_payload(username: str, avatar_url: str | None = None) -> dict[str, Any]:
    return {
        "id": stable_user_id(username),
        "username": username,
        "name": username,
        "avatar_template": avatar_url or settings.default_avatar_url,
        "trust_level": 0,
    }


def build_topic_list_response(
    topic_rows: list[dict[str, Any]],
    next_url: str | None,
) -> dict[str, Any]:
    users: "OrderedDict[int, dict[str, Any]]" = OrderedDict()
    topics: list[dict[str, Any]] = []
    for row in topic_rows:
        username = row.get("last_poster_username") or row.get("username") or "hupu_user"
        avatar = row.pop("_avatar_template", None)
        user = discourse_user_payload(username, avatar)
        users[user["id"]] = user
        row["posters"] = [{"user_id": user["id"], "description": "Original Poster", "extras": ""}]
        topics.append(row)
    return {
        "users": list(users.values()),
        "topic_list": {
            "topics": topics,
            "more_topics_url": next_url,
        },
    }


def map_topic_thread(thread: dict[str, Any], category: dict[str, Any] | None) -> dict[str, Any]:
    created_at = parse_relative_time(thread.get("time"))
    topic_id = int(thread["tid"])
    reply_count = int(thread.get("replies") or 0)
    username = str(thread.get("username") or "hupu_user")
    return {
        "id": topic_id,
        "title": str(thread.get("title") or ""),
        "slug": topic_slug(topic_id),
        "posts_count": reply_count + 1,
        "reply_count": reply_count,
        "views": int(thread.get("views") or 0),
        "like_count": int(thread.get("recommendNum") or 0),
        "excerpt": None,
        "created_at": isoformat_or_none(created_at),
        "last_posted_at": isoformat_or_none(created_at),
        "last_poster_username": username,
        "category_id": category["id"] if category else 0,
        "pinned": False,
        "visible": True,
        "closed": False,
        "archived": False,
        "tags": [],
        "unseen": False,
        "unread_posts": 0,
        "new_posts": 0,
        "last_read_post_number": None,
        "highest_post_number": reply_count + 1,
        "username": username,
    }


def map_topic_from_detail(topic_id: int, detail: dict[str, Any], category: dict[str, Any] | None) -> dict[str, Any]:
    thread = detail.get("t_detail") or {}
    created_at = extract_hidden_epoch(thread.get("content")) or parse_relative_time(thread.get("update"))
    username = str((thread.get("user") or {}).get("username") or "hupu_user")
    avatar = (thread.get("user") or {}).get("header")
    topic = {
        "id": topic_id,
        "title": str(thread.get("title") or detail.get("t_desc", {}).get("title") or ""),
        "slug": topic_slug(topic_id),
        "posts_count": int(thread.get("replies") or 0) + 1,
        "reply_count": int(thread.get("replies") or 0),
        "views": int(thread.get("hits") or 0),
        "like_count": int(thread.get("rcmd") or 0),
        "excerpt": None,
        "created_at": isoformat_or_none(created_at),
        "last_posted_at": isoformat_or_none(created_at),
        "last_poster_username": username,
        "category_id": category["id"] if category else 0,
        "pinned": False,
        "visible": True,
        "closed": str(thread.get("is_lock") or "0") == "1",
        "archived": False,
        "tags": [],
        "unseen": False,
        "unread_posts": 0,
        "new_posts": 0,
        "last_read_post_number": None,
        "highest_post_number": int(thread.get("replies") or 0) + 1,
        "username": username,
        "_avatar_template": avatar,
    }
    return topic


def map_main_post(topic_id: int, detail: dict[str, Any]) -> dict[str, Any]:
    thread = detail.get("t_detail") or {}
    user = thread.get("user") or {}
    created_at = extract_hidden_epoch(thread.get("content")) or parse_relative_time(thread.get("update")) or datetime.now(UTC)
    username = str(user.get("username") or "hupu_user")
    avatar = user.get("header") or settings.default_avatar_url
    return {
        "id": compose_post_id(topic_id, 1),
        "name": username,
        "username": username,
        "avatar_template": avatar,
        "cooked": normalize_html_content(thread.get("content")),
        "post_number": 1,
        "post_type": 1,
        "updated_at": isoformat_or_none(created_at),
        "created_at": isoformat_or_none(created_at),
        "like_count": int(thread.get("lights") or 0),
        "reply_count": 0,
        "reply_to_post_number": 0,
        "score_hidden": False,
        "can_edit": False,
        "can_delete": False,
        "can_recover": False,
        "can_wiki": False,
        "bookmarked": False,
        "read": True,
        "actions_summary": [],
        "reactions": [],
        "user_id": stable_user_id(username),
        "moderator": False,
        "admin": False,
        "group_moderator": False,
        "hidden": False,
        "cooked_hidden": False,
        "can_see_hidden_post": False,
    }


def build_quote_block(quote_info: dict[str, Any] | None) -> str:
    if not quote_info:
        return ""
    username = html.escape(str(quote_info.get("username") or ""))
    content = normalize_html_content(quote_info.get("content"))
    return f'<aside class="quote"><div class="title">{username}</div>{content}</aside>'


def map_reply_post(
    topic_id: int,
    post_number: int,
    reply: dict[str, Any],
    quoted_post_number: int = 0,
) -> dict[str, Any]:
    user = reply.get("user") or {}
    username = str(user.get("username") or "hupu_user")
    avatar = user.get("header") or settings.default_avatar_url
    created_at = parse_relative_time(reply.get("createDt")) or datetime.now(UTC)
    cooked = build_quote_block(reply.get("quote_info")) + normalize_html_content(reply.get("content"))
    return {
        "id": compose_post_id(topic_id, post_number),
        "name": username,
        "username": username,
        "avatar_template": avatar,
        "cooked": cooked,
        "post_number": post_number,
        "post_type": 1,
        "updated_at": isoformat_or_none(created_at),
        "created_at": isoformat_or_none(created_at),
        "like_count": int(reply.get("allLightCount") or reply.get("light") or 0),
        "reply_count": int(reply.get("replies") or 0),
        "reply_to_post_number": quoted_post_number,
        "score_hidden": False,
        "can_edit": False,
        "can_delete": False,
        "can_recover": False,
        "can_wiki": False,
        "bookmarked": False,
        "read": True,
        "actions_summary": [],
        "reactions": [],
        "user_id": stable_user_id(username),
        "moderator": False,
        "admin": False,
        "group_moderator": False,
        "hidden": bool(reply.get("isHidden")),
        "cooked_hidden": bool(reply.get("isHidden")),
        "can_see_hidden_post": False,
    }


def map_nested_reply_post(topic_id: int, raw_parent_post_id: int, index: int, reply: dict[str, Any]) -> dict[str, Any]:
    user = reply.get("user") or {}
    username = str(user.get("username") or "hupu_user")
    avatar = user.get("header") or settings.default_avatar_url
    created_at = parse_relative_time(user.get("createDt")) or datetime.now(UTC)
    post_number = 100000 + index
    return {
        "id": raw_parent_post_id * 1000 + index,
        "name": username,
        "username": username,
        "avatar_template": avatar,
        "cooked": normalize_html_content(reply.get("content")),
        "post_number": post_number,
        "post_type": 1,
        "updated_at": isoformat_or_none(created_at),
        "created_at": isoformat_or_none(created_at),
        "like_count": int(reply.get("allLightCount") or reply.get("lights") or 0),
        "reply_count": 0,
        "reply_to_post_number": 0,
        "score_hidden": False,
        "can_edit": False,
        "can_delete": False,
        "can_recover": False,
        "can_wiki": False,
        "bookmarked": False,
        "read": True,
        "actions_summary": [],
        "reactions": [],
        "user_id": stable_user_id(username),
        "moderator": False,
        "admin": False,
        "group_moderator": False,
        "hidden": False,
        "cooked_hidden": False,
        "can_see_hidden_post": False,
    }


def build_topic_detail_response(
    topic_id: int,
    detail: dict[str, Any],
    category: dict[str, Any] | None,
    posts: list[dict[str, Any]],
    stream_numbers: list[int],
) -> dict[str, Any]:
    thread = detail.get("t_detail") or {}
    created_user = thread.get("user") or {}
    post_stream = {
        "posts": posts,
        "stream": [compose_post_id(topic_id, number) for number in stream_numbers],
    }
    created_at = extract_hidden_epoch(thread.get("content"))
    return {
        "id": topic_id,
        "title": str(thread.get("title") or ""),
        "slug": topic_slug(topic_id),
        "posts_count": int(thread.get("replies") or 0) + 1,
        "post_stream": post_stream,
        "category_id": category["id"] if category else 0,
        "closed": str(thread.get("is_lock") or "0") == "1",
        "archived": False,
        "tags": [],
        "views": int(thread.get("hits") or 0),
        "like_count": int(thread.get("rcmd") or 0),
        "created_at": isoformat_or_none(created_at),
        "visible": True,
        "can_vote": False,
        "vote_count": 0,
        "user_voted": False,
        "summarizable": False,
        "has_cached_summary": False,
        "has_summary": False,
        "archetype": "regular",
        "details": {
            "can_edit": False,
            "notification_level": 1,
            "created_by": discourse_user_payload(
                str(created_user.get("username") or settings.read_only_username),
                created_user.get("header"),
            ),
        },
    }


def build_preloaded_payload(site_payload: dict[str, Any], topic_list_payload: dict[str, Any]) -> dict[str, Any]:
    site_settings = {
        "min_topic_title_length": 1,
        "min_personal_message_title_length": 1,
        "min_post_length": 1,
        "min_first_post_length": 1,
        "min_private_message_post_length": 1,
        "long_polling_base_url": "/",
        "presence_enabled": False,
        "secure_uploads": False,
        "discourse_reactions_enabled_reactions": "",
    }
    return {
        "siteSettings": site_settings,
        "site": site_payload,
        "topicList": topic_list_payload,
    }


def build_site_payload(category_payloads: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "categories": category_payloads,
        "top_tags": [],
        "can_tag_topics": False,
    }


def discourse_page_for_post_number(post_number: int) -> int:
    if post_number <= 1:
        return 0
    return max(0, math.ceil((post_number - 1) / settings.topic_page_size) - 1)

