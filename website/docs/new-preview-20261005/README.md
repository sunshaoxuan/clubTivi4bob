# BoBTV isolated product preview

## Scope and acceptance

Requested on October 5, 2026: redesign the product explanation website using
the physical black/red 3D interface and tactile motion in the supplied reference.
Reference: https://x.com/reijowrites/status/1905743606054600829/video/1
The six-second clip was inspected in the browser at multiple positions.

Public preview: https://bobtv.briconbric.com/new/
Local preview: http://127.0.0.1:8924/new/
Branch: codex/bobtv-new, based on origin/main 05aa507.
The Flutter client and existing product, download, diagnostic and API sources
are unchanged except the additional local FastAPI static mount.

The page uses the repository's actual player image, a custom Three.js physical
device, extruded cursor, raycast buttons, press/rebound loops, animated signal
bars, pointer response and scroll choreography. The scene is illustrative;
channel controls do not stream programmes or mutate client/server data.
The feature tabs provide keyboard selection and the download links reuse the
existing download page. Every runtime asset is self-hosted. No third-party
reference media or artwork is copied into the product page.

Observable acceptance: real image and nonblank moving canvas, usable selection
and pause, no clipping or horizontal overflow across six viewports, readable
copy, keyboard tabs, static reduced-motion rendering, WebGL failure recovery,
zero normal-page console/network errors, unchanged existing pages and working
three-platform downloads. Subjective beauty and motion parity remain subject
to user acceptance; merging the homepage is expressly pending.

## Deployment and rollback

CCNODE preview files: /opt/bobtv/previews/20261005-red-interface/new
Active symlink: /opt/bobtv/new
Nginx include: /etc/nginx/snippets/bobtv-new.inc
Only the existing BobTV HTTPS server receives this include. The /new/ location
is served directly by Nginx; no API restart or database migration is performed.
The preview uses no-cache and noindex/nofollow headers.

Activation tool: website/deploy/activate-new-preview.py. Upload a verified new/
directory and the tool with nginx-bobtv-new.inc into a dedicated release folder
under /opt/bobtv/previews. Run the tool with that absolute release folder.
It saves the previous config and symlink, checks Nginx syntax, reloads Nginx,
and compares application files and existing page responses. Activation failures
restore the saved config and previous preview link. Independently verify the
loaded origin route and public browser after activation.

Original backup: /opt/bobtv/previews/20261005-red-interface/rollback-1791206961
To withdraw this first preview, restore its bobtv.conf backup to
/etc/nginx/conf.d/bobtv.conf, remove the newly introduced bobtv-new.inc and
/opt/bobtv/new symlink, validate nginx -t, then reload Nginx. Inspect for newer
Nginx changes before restoring so unrelated later work is preserved.
The original application directory and API process require no rollback.

Direct origin verification must bypass outbound proxy settings:

    curl --noproxy '*' --resolve bobtv.briconbric.com:443:127.0.0.1 -fsSI https://bobtv.briconbric.com/new/

The first curl without --noproxy returned an API 404 through the proxy path.
The direct-origin probe returned HTTP 200 with the intended preview headers;
the public browser independently returned HTTP 200 and loaded the 3D scene.

## Executed verification

- Windows focused pytest: test_bobtv_site.py and test_new_preview.py, 7 passed.
- The complete Windows suite cannot collect Linux-only fcntl modules. These
  unrelated modules were left unchanged.
- Complete website pytest in a separate Linux virtual environment on CCNODE:
  47 passed in 21.78 seconds. One existing Starlette/httpx deprecation warning.
  Initial temporary-directory setup was corrected before the successful run.
  No test used the production data directory or production API mutation.
- Local and public Playwright runs: 1920x1080, 1440x960, 1024x768, 768x1024,
  390x844 and 320x667 all passed. Each covered layout, first-viewport continuation,
  actual canvas variation, pause, channel selection, tabs, arrows and diagnostics.
- Canvas pixel checks isolate the 3D area so DOM overlay transitions cannot
  create a false motion result. Reduced motion produced identical still frames.
- WebGL unavailable and explicit context-loss scenarios both displayed the
  genuine image fallback and disabled unavailable scene controls. Tabs survived.
- Physical 3D raycast click was exercised separately on the public-sized desktop
  layout and updated channel state from cinema to sport.
- All six public viewports: zero console errors/warnings and zero failed HTTP
  resource responses. Browser network traffic used the preview host only.
- Windows, Apple Silicon and Intel Mac downloads each returned HTTP 206 and
  32 requested bytes with no redirect.
- Activation recorded 35 existing application files unchanged, and identical
  homepage, download, diagnostic and release-manifest responses. API not restarted.
- JavaScript syntax, Python AST, workflow YAML and project-authored git diff
  checks passed. The unmodified official vendor distributions retain upstream
  whitespace warnings; they are excluded from the authored-code whitespace check.

Screenshots desktop.png and mobile.png show the public preview. Browser tests
live in website/tests/new-preview.cjs and are also added to the website CI.
For local execution supply Playwright and sharp through NODE_PATH and run
node website/tests/new-preview.cjs. Set BOBTV_PREVIEW_URL for public verification.
CHROME_PATH can select an installed Chromium executable. CI uses isolated npm
test dependencies; the page itself does not need npm or an external CDN.

## Advisory limitations

Sub2API model discovery was performed. Claude Opus 4.8 failed with an upstream
error on both attempts. DeepSeek Flash provided a text-only lifecycle review;
the primary agent applied relevant initialization, pause and context-loss fixes
and ran verification. No external model edited files or declared test results.

Gemini 3.1 Pro High and Gemini 3.8 Flash minimal image requests each failed
with No available accounts, including one retry per model. No external Gemini
visual review is claimed. The primary agent reviewed browser screenshots and
completed the functional, network, console and responsive checks.
