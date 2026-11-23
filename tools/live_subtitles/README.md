# Live subtitles client integration

The client supports the seven existing application languages: en, zh-CN,
zh-TW, ja, fr, es and ko. The preference follows the application language until
explicitly changed in the subtitle menu. Selection is requested language,
English while a missing selected non-English language is translated in the background,
then no subtitles if there is no usable English reference. Chinese scripts remain distinct.
AI-generated captions are explicitly labelled and share the verified English cue grid.

Native tracks are selected per ManagedPlayer. The shared video widget covers
channel previews, main/window/fullscreen playback, alternative previews and
multi-view. Both native tracks and synchronized external captions use the
actual decoded video rectangle and the surface's own fit/alignment.

External captions use the BobTV session API at
`https://bobtv.briconbric.com/api/v1/subtitles/`. A compile-time override or an
empty `BOBTV_SUBTITLE_SERVICE` may select a development service or disable it.
The enabled production pilot accepts only the exact reviewed Action Movies UK
service 6065 route with a current public EPG identity. Other channels retain
native track selection. Seven-language fallback applies to acquired and
acoustically verified existing files; missing files remain unavailable.

The service verifies public catalogue/EPG snapshots and the official movie
identity before acquiring subtitle files. Device-side speech recognition aligns
the English reference; generated translations retain that exact cue grid. The
legacy media-collector pilot remains separate from the client-only translation
workflow described below. No provider website Translate action is invoked.

## Resource discovery and subtitle variants

Each search checks all three configured providers that can verify the film.
OpenSubtitles via Stremio and SubDL require a verified IMDb ID. Subtitle Cat
uses title and year and leaves the final edition check to acoustic alignment.
An English hit or full language coverage does not skip another provider.
Only existing downloads are read. Each provider records its result, attempted
and parsed counts, cache reuse, and any lookup or file failures in
`provider-search-audit.json` and the resource cache index.

A track must pass timing checks against its English reference before becoming
eligible for playback. Distinct translations can share one English reference.
Each alternative retains its own cue times and source attribution. Acoustic
matching can inspect every eligible reference. A transcript fingerprint ignores
formatting and cue timing so duplicate copies do not inflate the display limit
of three options per language. The separate track fingerprint retains cue times
for verifying clock compatibility.

Cache schema 4 repeats earlier incomplete searches while retaining verified
editions and reusable downloads. A provider failure keeps usable results
available and permits a retry after backoff. Failed lookups, unverified film
identity, missing files, and unpaired timings have separate audit outcomes.

Additional providers require a supported retrieval route and permission for
the intended cache and playback use. The direct OpenSubtitles API uses an
application API key. ASSRT requires a token, and SubHD file access was blocked
in the Bee Season test. YIFY limits contributions to personal use and requires
written permission for indexing. These stay outside the automatic provider set.
[OpenSubtitles API documentation](https://opensubtitles.stoplight.io/docs/opensubtitles-api/)
[ASSRT API documentation](https://assrt.net/api/doc)
[YIFY terms](https://yts-subs.com/legal-information)

## Session API

POST `sessions`: `{source, language}`. Unsupported sources return 404, and the
client keeps its original stream. A successful response contains:

```json
{
  "session": "unique-playback-session",
  "source": "exact-requested-route",
  "playbackUrl": "http://127.0.0.1:18768/continuous-media",
  "windows": [{
    "start": 0, "end": 6, "state": "LOCKED",
    "program": "confirmed-programme", "asset": "verified-source-asset",
    "tracks": [{"language": "zh-CN", "verified": true, "cues": [
      {"start": 0, "end": 2, "text": "Existing subtitle text"}
    ]}]
  }]
}
```

GET `sessions/{session}` refreshes the same identity and supplies all available
language tracks, so language switches do not reopen video. Times are seconds on
the returned media's decoded player timeline, including interruptions. The
service must normalize clocks and invalidate acoustic calibration on source or
movie changes. LOCKED is an evidence-backed server assertion, not a client
inference from a programme title. Advert/unknown/acquiring intervals contain no
external film captions. The client clears on missing windows, invalid identity,
stop, channel change, disabled subtitles, or a three-second refresh lease expiry.
The API must never return unverified matching subtitles.

The service base and returned media URL must belong to existing BobTV nodes or
explicitly configured local development hosts. The client uses a single native
video decoder and its actual position. Polling captions never reloads video.

## Action Movies buffer pilot

For the verified UK host and service 6065, a loopback manifest adapter inserts
a 24-second EXT-X-START holdback, bounded by the available playlist duration.
This prevents one-second advert fragments from reducing startup headroom to
three seconds merely because a player counts fragments. Segment/key URIs and
advert/discontinuity metadata are preserved. The media still comes directly
from the original CDN; the adapter does not transcode or cache video. FFmpeg's
prefer_x_start option enables the hint; the existing SDK demuxer options and retry policy are preserved.
The main playback path applies its buffer tier before opening media and starts
health monitoring after open. The pilot primes its initial cache before showing
playback and uses at least the normal tier.
This is a pilot profile, not a verified solution for every provider.

## Native replay fixture

`replay_service.py --capture CAPTURE --output OUTPUT --ffmpeg FFMPEG` reads an
existing `segments.jsonl`, `caption-decisions.jsonl` and `cycle-result.json`.
It remuxes the captured movie/promo/movie cycle without burned subtitles and
exposes the session API. The media and acquired subtitle content remain outside
the repository. `tools/diagnostics/live_subtitle_probe.dart` runs the same
ManagedPlayer and BobtvVideo as the client, logs playback/captions every 50 ms,
and automatically moves the video among three layouts every 30 seconds.

This development fixture does not load the user's catalogue/preferences, run
the updater, replace the installed application, or publish a release.

## EPG programme context and handover

The normal client now keeps factual programme identities in a separate local
side table, installed atomically with each validated server EPG snapshot. Old
installations backfill this table once even when the immutable EPG version has
not changed. An exact current public catalogue route, enabled managed guide,
current identity hash and current airing are required for production discovery.
Private/custom sources are never uploaded by a fuzzy name match.

POST `sessions` additionally carries `programme` with `key`, `catalogChannelId`,
`programmeSourceId`, `originalChannelId`, `sourceEventId`, optional `movieId`,
`episodeId`, `seasonId` and factual `episodeLabel`,
`marketCode`, `serviceId`, `title`, `startUtc`, `stopUtc`, and
`clockIsSubtitleOffset:false`. These are discovery hints, never an acoustic
anchor. A service that accepts the context must echo the exact `programmeKey`
in each response. Old programme replies are rejected. A changed/gapped airing
clears old captions before POST `sessions/{id}/programme` updates that context.
The decoder is neither reopened nor sought. This service acknowledgement does
not replace the producer's obligation to verify movie/asset and alignment.

External text is hidden while playback is paused or buffering. Unknown/ad/promo
windows remain empty until a new LOCKED interval supplies confirmed programme,
asset and usable tracks. Cues are evaluated on decoded playback position. A
failed three-second lease clears external captions and restores native track
selection. Malformed tracks/cues are rejected before rendering.

The client now targets the pilot producer by default. The prior replay fixture
and unit/widget checks remain separate from real live-ad acceptance. Production
EPG expansion and seven-platform physical acceptance require their own evidence.

Episode programmes retain their official episode identity without inventing a movie ID. The context key includes the movie or episode ID, so newly enriched programme facts invalidate an older acquisition session. EPG clock values identify a programme slot; they never establish a subtitle offset across inserted advertising.

## Isolated live service deployment

`deploy.py` installs committed, hash-verified code as a separate systemd service
on loopback 8921, with an explicit Nginx route and retained rollback copies.
The main application and EPG workers are not restarted. The service permits at
most four clients sharing one live collector, retains a two-hour live-media window,
and expires idle sessions. Runtime media, keys, transcripts and subtitle files
are private cache material outside the repository. CPU is limited to one
core and memory to 768 MiB. Dependencies and the existing tiny.en model are
provisioned separately from requirements.txt; no paid ASR API or API credential is needed.
PyAV is pinned to the tested 15.1.0 interface. System FFmpeg is preferred over
the bundled static Linux build after an observed encrypted-HLS decoder crash.
Deployment checks WAV decoding compatibility before switching the service.

A movie CAID on an inserted asset is insufficient for caption release. The
current movie `epid` and an acoustic lock establish the initial media mapping.
Interrupted captions are empty. The same verified asset can resume only when
its original PTS agrees within 160 ms with the expected continuation. Clock or
asset changes force fresh acoustic alignment. Subsequent independent cues are
recorded as holdout error observations and never silently used to refit the
post-insertion clock. Gapped or stale EPG clears captions while media continues.

The pilot media playlist pins each session's origin and declares EXT-X-START.
The client preserves that hint when a subtitle service replaces an Action
Movies source. Its native decoder position, not wall time or the network edge,
is used to display cues. Fresh live test reports must distinguish server
relock time, first rendered caption time, holdout synchronization error,
startup holdback and any interruption in video playback.

The producer remuxes each served segment onto the continuous collector timeline
without re-encoding audio or video. Raw source PTS and encryption metadata remain
in the private acoustic-analysis cache. Ads can retain the movie CAID and jump
their raw PTS without declaring an HLS discontinuity; passing those raw clocks
to the decoder caused an observed minute-scale playhead jump. Normalized output
uses a pinned session origin; real ad/film segment smoke checks measured first
video PTS within 70 ms of the declared timeline start. Fresh native live tests
must still validate decoder clock continuity across the insertion.

Acoustic analysis runs in one background worker with a generation/asset guard.
Slow or stale ASR results cannot block advert suspension or reactivate captions
after a content boundary. The online gate reads packet PTS with ffprobe, and
only one acoustic analysis is outstanding per engine. Beam size 1 bounds pilot
CPU cost; calibrated source PTS carries the continuous subtitle clock.

The media publisher remuxes and caches segments in source order before HTTP
serves them. A PID-specific MPEG-TS continuity counter is carried across all
segments and content boundaries. Per-segment mux counter resets caused observed
`Packet corrupt` warnings, including during a real insertion. Only TS header
counter bits are rewritten; elementary payloads, normalized PTS/DTS and PCR
remain unchanged. Initial playlists wait for 24 seconds of ready media, and
HTTP readers never launch a remux subprocess. An unusable source segment is
logged and skipped with a discontinuity rather than blocking the producer.
Private media and caption decision memory retain at most two hours.

Short source fragments are grouped into approximately six-second transport
chunks after normalization, without changing their timestamped elementary
payloads. Groups stop at content, advert, source-gap and discontinuity boundaries.
The output playlist has its own consecutive media sequence; source sequence IDs
remain diagnostic facts. New session origins use an existing output boundary.
This bounds per-fragment HTTPS overhead on distant clients while retaining the
same source clock used by subtitle suspension and acoustic checks.

The live probe waits until three independent post-return acoustic holdouts
have actually passed through the native player. It records displayed cue onset
errors separately from the service's scheduled onset errors. Playback acceptance
requires no buffering after the verified baseline; initial acquisition and
buffering before that baseline are reported separately. Native sampling is
50 ms, with the backend's own decoded-position notification granularity.
### AI subtitle translation fallback

The client-only service reads its existing protected `/etc/bobtv/subtitle-ai.env`.
`BOBTV_SUBTITLE_AI_BASE_URL`, `BOBTV_SUBTITLE_AI_TOKEN` and
`BOBTV_SUBTITLE_AI_MODEL` remain server-only. Missing configuration leaves
existing subtitles and playback working without making AI requests.

After the current film and English reference have been verified, a missing exact
selected language triggers background translation to zh-CN, zh-TW, ja, ko, fr or
es. Existing usable subtitles for that exact language take precedence. English
continues playing while the translation is prepared. Provider failures and a
subtitle in the other Chinese script do not suppress translation of the requested
language. A later native exact-language track replaces its generated equivalent.

Each bounded batch has a translation pass and a separate proofreading pass against
the English original. Cue IDs and timing are retained exactly. Validated draft and
reviewed batches are saved independently, so retries and restarts resume unfinished
work. Only complete, reviewed tracks enter the playback catalog, marked `[AI]`.
Cache keys include the language, original cue grid and pipeline version. Background
completion does not change the selected language, pinned variant, player or clock.
A programme change cancels further work for the old film, retaining reusable batches.

The built-in source scope is the three configured providers: Subtitle Cat, SubDL,
and OpenSubtitles via Stremio. `BOBTV_SUBTITLE_AI_TRANSLATION_ALLOWED_PROVIDERS`,
when explicitly set, restricts that scope; an explicit empty value disables it.
The rolling 24-hour attempt budget defaults to 1024 and is adjustable using
`BOBTV_SUBTITLE_AI_DAILY_ATTEMPTS` (64–10000). At most two translation jobs run
across all channels. Translation calls are serialized separately from existing
alignment/metadata AI work, so a long translation cannot occupy its request slot.
No video or raw audio is sent by this translation pipeline.
