# Production visual acceptance, 2026-10-06 JST

## Authorization and production version

User authorized direct publication to the formal website directory and visual
acceptance. The localization version was already deployed. A fresh read-only
SHA-256 check confirmed all 14 affected runtime files in /opt/bobtv/site match
the committed source (3655aa6). bobtv.service is active. No runtime edits or
repeated deployment were needed. Client, databases and server configuration were
left unchanged. This follow-up adds only this acceptance record and screenshots.

## Fresh browser checks

Public target: https://bobtv.briconbric.com/.
Chrome headless, real production responses, four languages (zh-CN, en, ja,
zh-TW), three pages (product, downloads, diagnostics), widths 1440/390/320 at
900px height: 36 combinations returned 200 and the requested language.
No horizontal overflow, missing product image, JavaScript errors, console errors
or failed page/asset requests were observed.

The agent inspected complete desktop pages and mobile screenshots, including
lower sections, release history, installation instructions, diagnostic privacy
content and footers. Headings wrap within their containers, image framing is
intact, language controls fit, and copy does not overlap adjacent content.
No blocking visual defect was identified. This is engineering visual acceptance;
user preference approval remains with the user. Existing styling was retained.

Live interaction checks: selecting Traditional Chinese persisted when navigating
to diagnostics without a lang query; keyboard selection switched to English;
checksum disclosure opened. All three real installer links returned HTTP 206,
four bytes for bytes=0-3, with no redirects. No diagnostic logs were uploaded.
A fresh connection selected Japanese and returned CF-cache-status DYNAMIC.
Only this Japanese geographic connection was observed live; other geography
rules remain covered by the previously executed tests.

## Visual-review service limitation

Queried the live model directory. Gemini 3.1 Pro High and Gemini 3.8 Flash
image requests each failed twice with no available accounts. No provider,
credentials, routing or global settings were changed. No external visual
approval is claimed. The primary agent completed screenshot inspection and
browser verification; this limitation does not alter the recorded observations.

## Evidence and verification scope

- home-en-desktop.png: actual public English homepage, 1440x900.
- home-ja-mobile.png: actual public Japanese homepage, 390x900.
- ../localization-20261005.md: earlier 51 focused Windows and 91 Linux test results,
  deployment backup and rollback. Those tests were not repeated for this
  documentation-only follow-up.
- git diff --check: static whitespace validation for this record.

Screenshots are retained acceptance deliverables, not disposable test output.
Browser sessions were closed. No new test server or remote temporary directory
was created. Prior execution-policy cleanup limitations are unchanged.
