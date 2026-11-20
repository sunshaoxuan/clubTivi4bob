# Client audio subtitle pilot, 2026-11-17

Status: Mac Intel development pilot. No official release and no Windows/Android rollout. Real Action Movies advert acceptance is blocked by the reviewed stream returning HTTP 404. The official UK channel page on this Mac also displays `Rakuten TV is not available in your country.` The offline fixture is explicitly synthetic and cannot establish live advert recovery or a live bandwidth reduction.

## Data flow

The active libmpv decoder has an optional `bobtv_pcm` filter. It forwards the original audio AVFrame unchanged and exports a bounded two-second mono 16 kHz PCM window and decoder timestamps via filter metadata. The Mac worker runs whisper.cpp v1.8.2 offline, with a checksum-verified base.en q5_1 model. There is no microphone recording, API key or remote AI request.

`HlsBufferProxy` indexes the exact playlist used by the viewer. In client-clock mode, media goes from the provider through a streaming loopback endpoint to the same decoder, once. It marks programme and ad assets and keeps the subtitle display gated by the viewer's current playback position. This segment interception is disabled for existing clients without the Mac pilot resources.

Client-clock sessions POST only words, confidence, timestamps, programme identity, asset and monotonic clock epoch/serial to `/api/v1/subtitles/client/`. `TextHub` uses the existing persistent movie/IMDb, edition and language cache and does not instantiate a media collector or server ASR model. Timing evidence belongs to one viewer; an offset is never shared between viewers. Requested subtitle language falls back to English, then none, across the existing seven display languages.

An advert suspends local rendering immediately and invalidates the old mapping. A returning previously matched edition can resume only after fresh consistent dialogue from at least two distinct cues spanning two seconds. Initial acquisition retains the three-cue requirement. A source/asset/clock/programme change invalidates calibration. Standard FPS ratios require additional multi-window evidence.

## Reproducible Mac pilot

Build the diagnostic or normal Mac app from this branch, then run `tools/macos/prepare_client_asr.py APP --cmake CMAKE`. The worker and model live inside that isolated bundle. The installed user app is not overwritten. `prepare_audio_spectrum.py` includes the PCM filter and source in the existing pinned FFmpeg 6.0 build.

`tools/diagnostics/client_audio_local_probe.dart` and `tools/live_subtitles/run_local_audio_fixture.py` exercise real native PCM capture, actual offline ASR, HTTP dialogue upload, server matching, ad suspension and fresh matching after return. Their source consists of generated spoken sentences and a known silent advert interval. They must always be labeled offline fixtures.

`tools/live_subtitles/deploy_client_clock.py` deploys a separate systemd service on loopback 8923 and the narrower `/api/v1/subtitles/client/` Nginx location. It retains rollback copies and runs all subtitle backend tests before activation. Existing legacy sessions and installed clients remain isolated.

## Acceptance boundaries

- Native output PCM must be byte-identical with and without the tap, including opposite stereo phase.
- Observe actual caption text after return, not only a matched/ready status.
- Count caption leakage over the entire advert interval.
- Compare synchronization to distinct held-out cue anchors; label synthetic known-clock error separately from ASR residuals.
- Record app JSON bytes, service outbound media requests and systemd IP accounting. A new-path media count of zero is not an actual before/after live-bandwidth comparison when the original stream cannot play.
- Keep real live advert recovery, real HLS clock continuity and platform-specific native performance pending until measured. Windows/Android capability in upstream whisper.cpp does not establish BobTV support there.

## Recorded offline result

The final automatic native fixture lasted 66.605 seconds, with native mute `yes`, volume zero, no player errors and zero buffering samples after startup. The ten-second advert contained 100 display samples and zero movie-caption leaks. The first actual caption after return appeared after 13.739 seconds. Five distinct anchors excluded from initial recovery calibration had median absolute ASR residual 0.090 seconds and maximum 0.247 seconds. These are synthetic/offline measurements. See `outputs/BobTV-client-asr-20261117/offline-acceptance.json` outside the checkout for the original observations and exact limits.

The fixture uploaded 20,239 JSON bytes and received 28,234 subtitle/control JSON bytes. It made zero outbound video requests on the subtitle server. Neither a real live advert measurement nor an actual live bandwidth before/after comparison is available. The original reviewed master remained HTTP 404. The remote test API is separate from the legacy endpoint; server stream prewarming is disabled for the legacy unit, while existing on-demand clients retain their original protocol.
