# Findings & Decisions

## Requirements
- Reuse FluxDO as the app shell.
- Replace Linux.do data with Hupu mobile web data.
- Use local FastAPI as the backend.
- Keep the product read-only: browsing only, no login, posting, replying, or other interactions.
- Keep the FastAPI response shape compatible enough with FluxDO's Linux.do/Discourse expectations to avoid frontend rewrites beyond backend targeting.
- Current implementation scope is limited to list + detail flows.

## Research Findings
- FluxDO is a Flutter client centered on Discourse models and routes, not a thin Linux.do-specific shell.
- FluxDO startup depends on a bootstrap HTML response parsed by `PreloadedDataService`, including `data-preloaded`, `csrf-token`, `shared_session_key`, `discourse-base-uri`, and `data-discourse-setup`.
- FluxDO topic list and topic detail flows rely on Discourse-style routes such as `/latest.json`, `/c/...`, `/t/{id}.json`, and `/t/{id}/posts.json`.
- Hupu mobile web exposes anonymous JSON endpoints that are sufficient for read-only browsing:
  - `/api/v2/bbs/topicThreads`
  - `/api/v2/bbs-thread/{tid}`
  - `/api/v2/reply/list/{tid}`
  - `/api/v2/bbs-reply-detail/{tid}-{pid}`
  - `/api/v2/search2`
- Hupu channel metadata is available from `https://m.hupu.com/zone` and channel pages like `https://m.hupu.com/zone/{id}`.
- FluxDO's detail loading logic uses `post_number` and `stream` semantics, so the adapter will likely need synthetic sequential post numbers rather than raw Hupu reply ids.

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| Build a Discourse facade instead of patching FluxDO models deeply | Lowest-risk way to preserve existing UI flows |
| Use synthetic post ids/post numbers for reply loading | FluxDO expects stable sequential stream semantics that Hupu raw reply ids do not provide directly |
| Degrade unsupported read/list variants like `/new`, `/unread`, `/hot`, `/top` to latest-like behavior | Prevents crashes while staying within the requested scope |
| Expose nested reply reading through `/posts/{post_id}/replies` and keep `/posts/{post_id}/reply-ids.json` empty | FluxDO can still open the reply sheet without needing nested Hupu replies to masquerade as topic stream posts |
| Leave `currentUser` absent from bootstrap payload | Keeps the app in anonymous read-only mode and avoids fake user/session semantics |
| Make backend URL a compile-time define in Flutter | Minimal app-side change with no model or navigation fork required |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| Hupu `/zone/index` is not the real channel route | Use `/zone` and `/zone/{id}` instead |
| `/t/{id}/posts.json` conflicted with `/t/{id}/{post_number}.json` in FastAPI | Declare the more specific `posts.json` route first |

## Resources
- FluxDO repo: https://github.com/Lingyan000/fluxdo
- Hupu zone index: https://m.hupu.com/zone
- Hupu zone example: https://m.hupu.com/zone/1
- Hupu topicThreads: https://m.hupu.com/api/v2/bbs/topicThreads?topicId=1&page=1
- Hupu thread detail: https://m.hupu.com/api/v2/bbs-thread/638232100
- Hupu reply list: https://m.hupu.com/api/v2/reply/list/638232100?page=1
- FastAPI: https://github.com/fastapi/fastapi
- HTTPX: https://github.com/encode/httpx
- selectolax: https://github.com/rushter/selectolax
- tenacity: https://github.com/jd/tenacity

## Visual/Browser Findings
- `https://m.hupu.com/zone/{id}` embeds usable first-page data in `__NEXT_DATA__`, including `zoneData`, `postList.topicThreads`, and `nextCursor`.
- The Hupu zone frontend bundle references `/api/v2/bbs/topicThreads`, confirming that subsequent pagination is via public JSON rather than private app-only APIs.
- `https://m.hupu.com/bbs/{tid}.html` embeds enough content to confirm topic page structure, while `/api/v2/bbs-thread/{tid}` and `/api/v2/reply/list/{tid}` provide cleaner machine-readable detail and reply payloads.

## Implementation Notes
- Backend implementation lives under `backend/`.
- Key files:
  - `backend/app/hupu_client.py`: upstream fetch + retry + TTL cache
  - `backend/app/mappers.py`: Hupu-to-Discourse field mapping
  - `backend/app/main.py`: FastAPI compatibility routes
- FluxDO app integration is currently one code change:
  - `lib/constants.dart` now reads `FLUXDO_BASE_URL` with local backend default `http://127.0.0.1:8000`
- Locally verified live routes on 2026-04-05:
  - `/`
  - `/site.json`
  - `/latest.json`
  - `/c/zone-1/1/l/latest.json`
  - `/t/638232100.json`
  - `/t/638232100/posts.json?post_number=21&asc=true`
  - `/posts/by_number/638232100/2`
  - `/posts/638232100000002/replies`

## Residual Risks
- FluxDO still contains many Linux.do-specific feature surfaces outside the browsing core. They are not rewritten here.
- Search, notifications, bookmarks, login, posting, reactions, and profile-rich flows remain out of scope or stubbed.
- Hupu list payloads do not expose enough user metadata to fully reproduce Discourse topic poster stacks.
- Relative time strings from Hupu are converted heuristically; display ordering is good enough for browsing but not exact canonical timestamps.
