# Client subtitle integration, 2026-11-15

Status: development branch, production acceptance incomplete.

The client has a persistent seven-language subtitle menu with requested-language,
English, then no-subtitle selection. Native subtitle selection belongs to each
ManagedPlayer, including preview and multi-view decoders. The shared video widget
and vendored subtitle viewport use decoded picture bounds, local surface geometry,
fit and alignment. No subtitle translation or generation was added.

An optional external caption session adapter consumes verified programme/asset
windows on the actual decoded playback clock. It clears movie captions for
advert/acquisition/unknown intervals, expired sessions and channel changes. It
does not reopen video to update captions. Default builds leave this service
unconfigured. The included service is a replay fixture, not production discovery
or live ASR acquisition. See ../../tools/live_subtitles/README.md for the contract.

Action Movies UK service 6065 uses a duration-based 24-second live start hint,
bounded by the available manifest. CDN media/keys, HLS identities, cue markers
and discontinuities are preserved. mpv's single-key list operation retains SDK
protocol/retry settings. Main playback configures its buffer before opening media,
then starts monitoring. The pilot primes its cache and retains at least normal
buffer settings. Other streams retain their existing tier choices.

Validation:

* 32 relevant unit/widget tests passed, including all seven language fallbacks,
  Chinese script identity, 150-second ad gating, stale session response, service
  lease expiry, moved/letterboxed/pillarboxed picture bounds, existing window
  playback lifecycle and stall detection.
* A native PlayerService replay ran the complete previously captured 270-second
  movie/promo/movie sequence. No film caption in 2,999 advert samples over 150
  seconds. First post-return caption state was sampled at movie return +0.0213 s,
  with a 50 ms sampling interval. This is sampled state, not screen OCR timing.
  Six comparable caption onsets had median absolute deviation 0.364 s, maximum
  0.599 s from the previous local ASR onset estimates, including remux shifts.
  The ASR reference is not human-annotated ground truth. Three layouts were used;
  separate native screenshots confirmed picture-relative captions and an empty
  film-caption layer during the promo.
* The final frozen five-minute native PlayerService/AdaptiveBufferManager test
  played the current 1920x1080 UK live route. Initial buffering: 4.398 s at position
  zero, plus 0.442 s at position 0.0803 s. After the first ten seconds: zero
  buffering samples and zero playback errors. The final demuxer options retained
  the complete SDK protocol whitelist and seg_max_retry=5. Cache at finish:
  12.16 seconds. Frozen tested source hashes remained unchanged during this run.
* Earlier tests failed: direct player had a 1.8-second later stall; the first
  PlayerService run had 5.3-second early and 9.35-second later stalls; one build
  failed to start because option string serialization corrupted a protocol
  whitelist. These failures remain in the evidence directory and are excluded
  from final passing results.
* Mac Intel development builds succeeded. The installed app was not replaced;
  no official release, remote main merge, or other-platform physical acceptance.

Evidence directory:
/Users/shou/Documents/Codex/2026-07-18/git/outputs/BobTV-subtitle-client-20261115

Outstanding: production subtitle source/discovery and synchronization service,
new live movie/ad/movie reacquisition in the client, and cross-platform physical
acceptance. The replay verifies consumption of a previously calibrated timeline;
it does not prove new live ASR reacquisition or production subtitle availability.
