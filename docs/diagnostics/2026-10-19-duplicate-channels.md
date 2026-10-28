# Channel duplication regression, unpublished repair

Checked on 2026-10-19, approximately 03:02 JST. Repair code and generated catalog
are local test candidates. No release, website/mirror deployment, installed-app
replacement, app close or app restart was performed by this investigation.

## Verified causes

The screenshot came from macOS 1.1.7+100. Read-only SQLite inspection found one
favorite list and 61 unique membership rows, with no duplicate membership primary
keys. The card duplicates have two distinct causes:

1. `ChannelsScreen._automaticChannelKey` and favorite expansion gave public
   catalog rows a server-ID key and old provider rows a separate name key, even
   when the canonical stream URL was identical. Wind Theater and CCTV-6 each
   therefore appeared as a public card plus a legacy-provider card.
2. `process_channel_inventory.py` derived channel IDs from the complete category
   path and channel name. Astro AOD had two public IDs because its routes were
   classified as drama and movies. Both route categories were marked manual;
   neither route had an explicit manual channel merge or manual channel name.
   Retention of earlier public IDs could also leave more than one identity in
   an otherwise identical country/category path.

The Mac held 21,971 route rows. Its 9,680 public routes represented 8,808 public
IDs; 1,714 distinct URLs were also present in old providers. There were 123 exact
same-name groups involving 258 public IDs. Same names alone are not sufficient
evidence of a duplicate: country, local region, delay, quality and media kind can
identify distinct services.

Windows was checked independently over the existing authorized connection. Its
running 1.1.7+100 process was PID 10604; its database held only the 9,680 public
routes, no favorites, and the same 123 same-name groups. This establishes that
the directory problem is shared across installations, independently of private
favorites or Mac-only storage.

## Implemented locally

`ChannelPresentationIdentity` is now used by card grouping, route counts and
favorite membership. It bridges a legacy group only through a matching canonical
public route, compatible full normalized name, quality/media and country.
Multiple possible public identities fail closed. Public IDs are not joined by
name alone. Explicit manual merges have precedence. Source rows, private URLs
and manual EPG mappings are not rewritten. The playing row remains the visible
representative during a list refresh.

The publisher now conservatively coalesces compatible classification-only
variants and retained duplicate IDs in the same explicit country/category
boundary. Unknown geography, additional regional hierarchy, different country,
region or EPG values (including missing versus present values), full-name delay
or quality distinctions, and explicit manual identity decisions are excluded.
Genre memberships are retained in validated optional `categoryIds` metadata.
The client stores and displays these memberships without creating another card.
An explicit pending local category edit overrides cached memberships.

This presentation change does not authorize a new EPG mapping. EPG bindings
continue to use their exact identity fingerprint and existing lock protections.

## Actual-data replay

Input public snapshot version: `2026-10-18T17:48:18.249000Z`.

Compressed input SHA-256:
`96b3873f8c9e29dc754002424abd3b41061fcff4f5b7d8dfdf81ab38e0008d05`.

Final conservative candidate: 8,804 public IDs and all 9,680 original route
objects, including provenance/access metadata. Four redundant IDs are removed;
122 same-name groups remain separate. They must not be bulk-merged based on
names. Earlier broader shadow candidates were superseded after missing identity
metadata was made a blocking difference.

Read-only replay of the actual Mac favorite selection:

| Case | Visible cards | Favorite membership rows |
| --- | ---: | ---: |
| Released grouping | 12 | 61 |
| Client repair | 10 | 61 |
| Client and conservative catalog repair | 9 | 61 |

The two Astro AOD genre memberships remain available under one identity. No
channel or favorite membership was removed from the installed database.

## Validation and limits

- macOS-hosted client regression selection: 86 passed. The initially skipped
  environment-gated private HTTP API fixture was then run with the bundled
  Python runtime and passed separately, giving 87 passed client cases. Includes
  favorites backup/restore, other-device denial, merges, transfers, server EPG
  lock/fingerprint protection, list identity and alternative routes.
- Windows-native isolated source fixture: 46 passed. Installed PID 10604 was
  unchanged after the tests. The initial offline dependency attempt failed
  because the fixture omitted its vendored media packages; copying the existing
  source baseline's vendored dependencies resolved that fixture-only failure.
- Server classification/inventory/publication regression selection: 86 passed.
- Actual Mac read-only presentation audit: passed, 12 to 9 cards, 61 memberships.
- Actual conservative catalog privacy validation and client import: two passed.
- Android ARM64 debug Dart bundle: compiled successfully, no APK installation.
- New helper and audit test analysis: no issues. Existing large screen/database
  analysis has existing warnings/style notices and no compiler errors.
- No connected Android device was available. Installed-app visual interaction,
  native platform package builds, and on-device acceptance of this repair remain
  unperformed. Unit tests do not substitute for these checks.

The deployed publisher has an `origins` schema/access validation extension newer
than this workspace's publisher. The replay proves every route object including
that metadata remains unchanged, while validating channel changes through the
local schema. Before any future deployment, reconcile that deployed extension
and its tests; do not overwrite it with the workspace copy. No server deployment
was attempted.

Evidence and the explicitly unpublished candidate are under
`outputs/BobTV-duplicates-20261019/` outside the repository. Release publication
remains paused. Current installed clients have not received this repair.
