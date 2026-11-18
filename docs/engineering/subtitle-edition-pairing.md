# Subtitle discovery and film-edition timing

Each connected provider inspects every identity-matching release returned by its catalogue. Downloads use at most four workers per provider, checksum-verified movie/language caches, and bounded file/archive sizes. The providers currently integrated automatically are OpenSubtitles via its public Stremio addon, Subtitle Cat, and SubDL. Other sites in third-party directories are not implicitly integrated.

An existing English file must not stop searches for the requested language. Original title, year and a verified IMDb lookup constrain results. When a provider supplies a generic Chinese tag, distinct simplified and traditional characters are inspected after the real file is read; ambiguous generic tags stay unclassified.

Languages retain their original cue boundaries. Identical timestamp grids remain directly compatible. Independently segmented tracks require the same IMDb identifier, provider and full release label, plus at least 40 distinct cue intervals whose starts agree within 0.2 seconds and ends within 0.3 seconds. These anchors must cover at least 80% of the track span and eight of ten timeline bins, and constitute at least 7% of its cues. At least 90% of translated cue midpoints must fall inside English speech intervals expanded by 0.3 seconds. Short tracks, shifted edits and insufficient evidence remain unpaired. These checks establish timing correspondence; they do not grade translation quality.

The cache recomputes this evidence when reading and writing a paired edition, verifies subtitle bytes and hashes, and never reuses a viewer's live offset as a film cache entry. Resource schema 3 refreshes previous negative searches made under the identical-grid-only policy. Failed providers remain temporarily unavailable; downloaded files without timing evidence remain pending rather than being reported as absent.

Live display still requires fresh acoustic alignment, and ad intervals suspend captions. A different edition cannot replace a previously verified fallback until fresh speech confirms it.
