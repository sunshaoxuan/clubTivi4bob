# Live subtitles client integration

The client supports the seven existing application languages: en, zh-CN,
zh-TW, ja, fr, es and ko. The preference follows the application language until
explicitly changed in the subtitle menu. Selection is requested language,
English, then no subtitles. Chinese scripts remain distinct. There is no
subtitle generation or translation fallback.

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

`service.py` verifies current immutable public catalogue/EPG snapshots and the
official movie identity, retrieves existing Subtitle Cat download links, and
runs local tiny.en speech recognition for synchronization. It never invokes a
Translate action or generates subtitle text. Provider translation quality is
unreviewed. English audio is the currently supported acoustic pilot.

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
