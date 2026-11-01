# animeOTTv3 upgrade – final notes (phases 1-6)

## Features
Controls page (admin: users list, Maximum Concurrent Users, Allow User Video Downloads) · session limit (backend, transactional) ·
download engine (background_downloader, Range resume) · Download button under the player · Downloads tab (Saved | Downloads | Profile) ·
offline player · Gallery save · smart pull-to-refresh · streaming start-up optimizations.

## Backend (FastAPI) – all verify the Firebase ID token; admin routes also check users/{uid}.role == 'admin'
| Endpoint | Who | Purpose |
|---|---|---|
| POST /session/start, /session/heartbeat, /session/end | signed-in user | concurrent-session limit (429 = limit reached) |
| GET /settings | signed-in user | allowDownloads only |
| GET/PUT /admin/settings | admin | maxConcurrentUsers (1..MAX), allowDownloads |
| GET /admin/users | admin | paged user list + active count |
| POST /downloads/authorize | signed-in user | 403 when downloads are off; checks video exists + active session |

## Data
Firestore: `settings/app` {maxConcurrentUsers, allowDownloads} (read: signed-in, write: backend only) · `sessions/{uid}_{deviceId}` (backend only) · rules in firestore.rules.
Device: SharedPreferences keys `dl_records_v1`, `stream_url_cache_v1`; files in `<appSupport>/anime_downloads/`. No migration of existing data.

## Platform config
Android: INTERNET, POST_NOTIFICATIONS, FOREGROUND_SERVICE(+_DATA_SYNC), WRITE_EXTERNAL_STORAGE (maxSdk 28). iOS: NSPhotoLibraryAddUsageDescription / NSPhotoLibraryUsageDescription.
Packages added: background_downloader, gal, cached_network_image. Deploy firestore.rules and the backend (API_BASE_URL must point to it).

## Streaming optimizations (phase 6) – what changed and why
1. Candidate URLs are probed in PARALLEL (Range 0-0) and the first that really serves video is tried first (was: sequential full player inits, each failure can take many seconds).
2. The URL that worked is cached per video (next start: no probing at all).
3. More Videos loads all documents in parallel (was one Firestore round-trip per video).
4. Language lookup uses a narrowed query (langGroup/groupId, else category+season) instead of reading the WHOLE `videos` collection on every page open; falls back to the old read if the query fails.
5. Thumbnails: disk + memory cache, decoded at 640px (smoother scrolling, thumbnails visible offline once seen).
Not possible here: adaptive bitrate (Drive serves one file – needs HLS/DASH transcoding infra), tuning ExoPlayer buffer sizes (not exposed by video_player).

## How to measure before/after (no numbers are claimed – none were measured)
`lib/services/stream_perf.dart`: set `kStreamOptimizations = false` for the original behaviour, `true` for the new one. Open the same video 5x on the same network (force-close the app between runs; first run with true is the "cold" run, later runs use the URL cache). Long-press the video title: the sheet lists `probe` and `player-ready` times in ms. Compare medians. For More Videos / language lookup use Firebase console usage (document reads per open).

## Regression checklist (run on a device)
1 Admin sees Controls in Profile; ordinary user does not and gets 403 from /admin/* · 2 users list loads/empty/error · 3 Downloads tab between Saved and Profile; Profile still opens ·
4 Download starts, % moves, Pause/Resume/Cancel, kill app mid-download and reopen · 5 airplane mode: downloaded video plays · 6 file appears in Gallery album "Anime Portal" ·
7 admin turns downloads off: button disabled, running downloads pause, offline videos still play · 8 limit=1: second device gets the limit message; admin exempt ·
9 pull inside More Videos -> only that section; pull at top -> full refresh, video keeps playing · 10 login/logout/Saved/Search/Series/Movies/Upload unchanged · 11 `flutter analyze`, `flutter build apk`.

## Test status
Backend: `python selftest_controls.py` -> all checks passed; `selftest_drive.py` runs clean (existing). Flutter: NOT compiled/analyzed in the authoring environment (no SDK) – run `flutter pub get && flutter analyze` first.
