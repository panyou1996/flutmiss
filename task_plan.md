# Task Plan: FluxDO Hupu Read-Only Adapter

## Goal
Implement a local FastAPI backend that adapts Hupu mobile web data into the Discourse-compatible shapes FluxDO expects, then patch FluxDO to target that backend in read-only mode.

## Current Phase
Phase 5

## Phases
### Phase 1: Discovery & Integration Points
- [x] Clone FluxDO into a local workspace
- [x] Identify the minimal frontend changes needed for a custom backend base URL
- [x] Confirm the exact Discourse-compatible routes and bootstrap HTML FluxDO requires
- **Status:** complete

### Phase 2: Backend Skeleton
- [x] Create the FastAPI project structure under the repo
- [x] Add configuration, models, routing, and app bootstrap
- [x] Add dependency and run instructions
- **Status:** complete

### Phase 3: Hupu Client & Mapping
- [x] Implement the Hupu HTTP client and parsers
- [x] Implement site/category/topic/post mapping into FluxDO-compatible JSON
- [x] Add read-only route behavior for unsupported endpoints
- **Status:** complete

### Phase 4: FluxDO Integration
- [x] Patch FluxDO to point at the local compatibility backend
- [x] Keep unsupported features clearly read-only and non-crashing
- [x] Document how to run app + backend together
- **Status:** complete

### Phase 5: Verification
- [x] Run targeted backend contract checks
- [x] Run at least one local backend start check and one app/static sanity check
- [x] Summarize gaps and residual risks
- **Status:** complete

## Key Questions
1. Which FluxDO bootstrap fields are mandatory for app startup without Linux.do?
2. Which endpoints must exist for list + detail flows to work without runtime errors?
3. How far can Hupu data map into Discourse shapes before frontend semantics break?

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| Work in `/root/fluxdo-hupu` cloned from upstream FluxDO | Keeps app and adapter in one workspace and makes the base URL patch straightforward |
| Implement only list + detail browsing flows in v1 | Matches the requested browsing-only scope and avoids fake write/login behavior |
| Add planning files in repo root | Required by `planning-with-files` and useful for a multi-stage implementation |
| Make the app base URL configurable via `--dart-define=FLUXDO_BASE_URL=...` | Keeps FluxDO changes minimal while allowing local LAN deployment |
| Keep unsupported user/profile/search/write routes stubbed or read-only | Prevents immediate frontend crashes outside the main browsing path |

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| `GET /t/{id}/posts.json` matched `/t/{id}/{post_number}.json` first and returned 422 | 1 | Reordered FastAPI route declarations so the more specific `posts.json` route is matched first |

## Notes
- Keep the backend strictly read-only.
- Prefer compatibility over perfect Discourse fidelity where FluxDO only needs a subset of fields.
- Record all Hupu field-to-Discourse mapping assumptions in `findings.md`.
- Verified locally against live Hupu responses on 2026-04-05.
