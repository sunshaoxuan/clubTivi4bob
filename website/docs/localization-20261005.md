# Website localization acceptance

## Scope

Rewrote product copy as direct feature descriptions. Kept the existing visual
system and real app image. Added complete English, Japanese and Traditional
Chinese alongside Simplified Chinese for product, downloads and diagnostics,
including dynamic status/error messages. The rejected /new/ preview stays removed.

Default region mapping: CN -> zh-CN; JP -> ja; TW/HK/MO -> zh-TW;
every other or unknown region -> en. Explicit selection overrides the remembered
cookie, which overrides geolocation. See README for the trusted proxy contract.

## Actual checks on 2026-10-05

- Windows focused Python tests: 51 passed (site + localization).
- Isolated CCNODE Linux full website suite: 91 passed, one upstream TestClient
  deprecation warning. Separate venv and data directory; no production log data.
- Local and live browser: 4 languages x 3 pages x widths 1440/390/320,
  36 combinations each. No horizontal overflow, missing images, console errors
  or failed real page/asset requests. Actual screenshots reviewed by the agent.
- Local browser mocked release data verified three platform choices, Setup
  preference and platform-specific versions, checksum disclosure, empty/error
  states. Mocked diagnostic requests verified whitelist filtering, success ID,
  invalid input and translated status messages in all four languages. No test
  logs were uploaded to production. Manual language selection persisted.
- Final diagnostic spacing checked at all three widths and four languages.
  Copy-to-panel gap is 33px desktop and 81px mobile, without overflow.
- Production /cdn-cgi/trace classified the current test connection as JP;
  a clean public homepage request and browser selected ja automatically.
- All 12 explicit-language origin HEAD paths returned 200 with matching
  Content-Language, as did all public GET paths. Public HTML was private,
  no-store and CF-cache-status DYNAMIC. Keyboard language switching passed.
- Direct-origin forged CF-IPCountry and X-Forwarded-For selected en.
- Actual Windows installer range request returned 206 and four bytes, without
  redirect. Production versions remain Windows 1.0.1 and macOS 1.0.2.
- /new/ returned 404. bobtv.service was active after deployment.
- Cloudflare published IPv4/IPv6 ranges matched the existing checked-in list.
- git diff --check passed; locale dictionary shapes/placeholders match.
- All 14 affected deployed runtime files matched local SHA-256 hashes.

The CN/TW/HK/MO and unknown-country mappings were verified with trusted-peer
fixtures. Only JP was observed through an actual external geographic connection.
No claim is made that independent visitors from all regions were tested.

Claude advice failed twice upstream; DeepSeek text-only advice was reviewed by
the main agent. Gemini Pro and newest Flash image calls failed with no available
accounts, including one retry each. External Gemini visual review remains
unavailable; browser screenshots and agent review were completed. Repository-wide
GitHub Actions is disabled, so hosted CI did not run and was not enabled.

## Deployment and rollback

Before deployment the production app hash matched the normalized repository
baseline. Backup: /opt/bobtv/backups/site-before-localization-20261005.tar.gz.
Installed Jinja2 in the site venv. Changed only app/page runtime files and three
assets; kept release storage, channel APIs, client code and nginx configuration.

To roll back, restore the archive into /opt/bobtv/site, remove the added
localization.py, templates and locales paths, then restart bobtv.service.
The Jinja dependency may remain installed; the restored app does not import it.
The archive includes all old HTML and affected assets. No data migration is needed.

## Cleanup

Stopped the local verification server and closed the browser. The remote isolated
test checkout, venv, data and uploaded test archive were removed. Local recursive
deletion was rejected by execution policy after workspace-boundary validation;
five ignored directories remain: website/.test-output, website/.capture,
.pytest_cache, website/__pycache__, and website/tests/__pycache__. This includes
temporary screenshots/test outputs. No alternate deletion method was attempted.
