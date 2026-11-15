# Authoritative production EPG overlay

This directory records the running Python modules reconciled against `/opt/bobtv/site` on 2026-11-15. The website tree supplies unchanged dependencies. Production's existing EPGTalk source is retained. The Taipei partial-current-conflict handling already committed on main is included to close the observed deployment drift.

The Rakuten adapter reads two local calendar days, every page, and validates market/service identities, explicit offsets and programme conflicts. It refreshes every 900 seconds. Only factual schedule metadata is cached. Source availability never grants a catalogue mapping. Every Rakuten mapping rechecks all current route market/service editions before ingestion or publication. Mixed or unresolved editions remain pending.

Global research covers every current catalogue channel. Country rotation and alternating new/due admissions prevent permanent starvation. The existing timer processes up to five tasks per bounded run. The daily 500 admission limit is removed; the rolling hourly 60 guard and upstream failure/authentication backoffs remain. The migration clears the former local budget pause once, preserving request history. Programme candidates now receive bounded GET/content inspection; previous HEAD-only success cannot suppress a real read.

Source facts, reviewed mappings, current/future rows and publicly activated coverage must be reported separately. Source enumeration is never BobTV coverage. Failed or unconfirmed sources retain their last good data and retry floors. No classification decision is inferred from a country scheduling hint.

Validation: `python tools/epg/prepare_validation.py` creates a disposable runtime overlay. Run its EPG tests with Python 3.12 and production dependencies. `clone_check.py` is an isolated database check and must use a cloned BOBTV_DATA_DIR. No official client binary release is part of this data/runtime change; verify existing client EPG hot sync against the published payload.
