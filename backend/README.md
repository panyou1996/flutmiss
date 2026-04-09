# FluxDO Hupu Compat Backend

## Run

```bash
cd /root/fluxdo-hupu/backend
python3 -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

## FluxDO App

The Flutter app now reads its backend base URL from the compile-time define `FLUXDO_BASE_URL`.

Default:

```text
http://127.0.0.1:8000
```

Override example:

```bash
flutter run --dart-define=FLUXDO_BASE_URL=http://192.168.1.10:8000
```

## Scope

- Read-only browsing only
- Bootstrap HTML compatible with `PreloadedDataService`
- Discourse-style list/detail routes for FluxDO
- Hupu source endpoints:
  - `/zone`
  - `/api/v2/bbs/topicThreads`
  - `/api/v2/bbs-thread/{tid}`
  - `/api/v2/reply/list/{tid}`
  - `/api/v2/bbs-reply-detail/{tid}-{pid}`

## Implemented Compatibility Routes

- `GET /`
- `GET /site.json`
- `GET /session/csrf`
- `GET /latest.json`
- `GET /new.json`
- `GET /unread.json`
- `GET /unseen.json`
- `GET /hot.json`
- `GET /top.json`
- `GET /c/{slug}.json`
- `GET /c/{slug}/{id}.json`
- `GET /c/{slug}/{id}/l/{filter}.json`
- `GET /c/{parent_slug}/{slug}/{id}/l/{filter}.json`
- `GET /t/{id}.json`
- `GET /t/{id}/{post_number}.json`
- `GET /t/{id}/posts.json`
- `GET /posts/by_number/{topic_id}/{post_number}`
- `GET /posts/{post_id}.json`
- `GET /posts/{post_id}/reply-ids.json`
- `GET /posts/{post_id}/replies`
- `GET /u/{username}.json`
- `GET /u/{username}/summary.json`

Unsupported write routes return `501 read-only backend`.

