# Compact language control, 2026-10-06 JST

## Requested change

Replace the boxed language picker and separate confirmation button with compact
navigation-sized text. Show a small down arrow on mouse hover or keyboard focus.
Selecting an option switches language immediately. Preserve native mobile picker,
keyboard interaction and the existing remembered-language and IP region rules.

Implemented in base.html, site.css and the two-line language.js change handler.
Removed obsolete confirmation-label entries from all four locale dictionaries.
The desktop font is 14px, matching navigation; mobile 12px and narrow-mobile
11px also match navigation. Width is 88/76/72px respectively. Arrow visibility
does not alter the control dimensions. No other page styling was changed.

## Actual verification

- 46 localization tests passed on Windows, including no confirmation button in
  all 12 rendered page/locale combinations.
- Local and public Chrome: four languages, three pages, widths 1440/390/320,
  36 combinations each. Matching navigation/control font sizes, no confirmation
  buttons, correct languages, no horizontal overflow or console/network errors.
- Arrow computed opacity was 0 when idle and 1 on hover; local before/after
  bounds stayed 88x44px. Automatic selection, remembered language and keyboard
  ArrowUp/Enter switching passed locally and on production.
- Actual desktop and mobile screenshots inspected by the main agent. No text
  clipping or overlap observed. Gemini Pro High and latest Flash each failed
  twice with no available accounts. No external visual approval is claimed.
- Static git diff --check passed. Broad backend tests were not repeated for this
  narrow frontend change. APIs, release storage and client code were untouched.

## Deployment

Updated /opt/bobtv/site directly under the user's standing publication approval.
Backup: /opt/bobtv/backups/site-before-language-control-20261006.tar.gz.
Changed assets/site.css, assets/language.js, templates/base.html and four locale
JSON files. Restarted bobtv to refresh loaded dictionaries; service active.
Stylesheet cache version is 12. To roll back, restore the archive into the site,
remove assets/language.js, and restart bobtv. No migration or data changes.

Local server and browser closed after acceptance. New screenshots and logs live
in the already ignored .test-output directory; earlier recursive-delete policy
restriction remains, with no bypass attempted.
