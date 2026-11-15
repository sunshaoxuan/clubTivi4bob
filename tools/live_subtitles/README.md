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

External captions use an optional session API, configured with
`--dart-define=BOBTV_SUBTITLE_SERVICE=http://127.0.0.1:18768/` for local testing.
**The default build does not enable a production external-caption service.**
Automatic programme/subtitle discovery and live ASR acquisition have not been
ported from the research prototype into a production service by this change.
The fixture below supplies immutable decisions from a previous live capture.
It must never be presented as a fresh live synchronization test.

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
